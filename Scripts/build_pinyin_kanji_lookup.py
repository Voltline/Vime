#!/usr/bin/env python3
"""Build PinyinKanjiLookup.bin: find Japanese kanji words by their Mandarin reading.

Each word of the shipped Mozc lexicon (JapaneseLexicon.tsv) that contains kanji
becomes a path of (character, reading segment) edges in a trie. At runtime a
character can be matched either by one of its Mandarin pinyin syllables or by a
romaji spelling of its kana segment (検察 = 検|けん + 察|さつ, so jiancha,
jiansatsu and kencha all reach it). See Shared/Chinese/PinyinKanjiLookup.swift.

Sources (pinned; network required unless the cache already holds them):
- Mozc dictionary_oss at the revision in DictionarySource.json (BSD-3-Clause):
  part-of-speech ids, to downweight proper nouns and drop personal names.
- Unicode Unihan 17.0.0 (Unicode License v3): kMandarin, kXHC1983, kTGHZ2013
  (modern readings) and kHanyuPinyin (historical readings, ranked lower).
- OpenCC (Apache-2.0) JPShinjitaiCharacters and TSCharacters: Japanese
  shinjitai read as their traditional forms (検→檢, 経→經, 楽→樂, 軽→輕).
- KANJIDIC2 (EDRDG, CC BY-SA 4.0): on/kun readings for aligning a word's kana
  reading to its characters. It is updated daily; the manifest records the
  database version and checksum that were used. Pass a local copy to rebuild
  from the same data: --kanjidic path/to/kanjidic2.xml.gz.

Run from the repository root: python3 Scripts/build_pinyin_kanji_lookup.py
"""
import argparse
import gzip
import hashlib
import io
import json
import re
import struct
import sys
import unicodedata
import urllib.request
import zipfile
import xml.etree.ElementTree as ET
from collections import defaultdict, deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Shared" / "Resources"
OUTPUT = RESOURCES / "PinyinKanjiLookup.bin"
MANIFEST = RESOURCES / "PinyinKanjiLookupSource.json"
CACHE = Path("/private/tmp/vime-pinyin-kanji")
MOZC_CACHE = Path("/private/tmp/vime-mozc")

UNIHAN_URL = "https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip"
OPENCC_COMMIT = "025f371dc76b598d77384fbdab90c937471844d8"
OPENCC_BASE = f"https://raw.githubusercontent.com/BYVoid/OpenCC/{OPENCC_COMMIT}/data/dictionary"
OPENCC_FILES = ["JPShinjitaiCharacters.txt", "TSCharacters.txt"]
KANJIDIC_URL = "http://www.edrdg.org/kanjidic/kanjidic2.xml.gz"

# Word cost (Mozc: lower is more common) penalties by proper-noun class.
# Personal names are dropped: their readings are arbitrary and they crowded
# out ordinary words (京急 outranked 経済 for jingji in the prototype).
PROPER_PENALTY = {
    1920: 1500,  # 名詞,固有名詞,一般
    1924: 1000, 1925: 1000, 1926: 1000, 1927: 1000,  # 地域 (places)
    1928: 0,     # 地域,国 (countries: 中国, 日本)
    1929: 2500,  # 組織 (organizations: 京急)
}
PERSON_NAMES = {1921, 1922, 1923}
MAX_COST = 9000
MAX_WORD_LENGTH = 8
# Kokuji with readings in Chinese dictionaries that Chinese readers would not
# know them by; other kokuji have only an editorial kMandarin and are caught by
# the "kMandarin only" rule below.
JAPANESE_ONLY = set("畑畠辻込")

NO_SEGMENT = 0xFFFF
NOT_TERMINAL = 0xFFFF
SECONDARY = 0x8000


def fetch(url, path):
    if path.exists():
        return path.read_bytes()
    print(f"Fetching {url}", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "Vime-pinyin-kanji-builder"})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return data


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# MARK: characters and kana

def is_kanji(c):
    o = ord(c)
    return (0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF or 0x20000 <= o <= 0x3134F
            or 0xF900 <= o <= 0xFAFF)


def is_hiragana(c):
    return "ぁ" <= c <= "ゖ"


def is_katakana(c):
    return "ァ" <= c <= "ヶ"


def hira(text):
    return "".join(chr(ord(c) - 0x60) if is_katakana(c) else c for c in text)


SMALL_YOON = set("ゃゅょ")
SMALL_VOWELS = set("ぁぃぅぇぉ")
MONO = {
    "あ": ["a"], "い": ["i"], "う": ["u"], "え": ["e"], "お": ["o"],
    "か": ["ka", "ca"], "き": ["ki"], "く": ["ku", "cu"], "け": ["ke"], "こ": ["ko", "co"],
    "さ": ["sa"], "し": ["shi", "si"], "す": ["su"], "せ": ["se"], "そ": ["so"],
    "た": ["ta"], "ち": ["chi", "ti"], "つ": ["tsu", "tu"], "て": ["te"], "と": ["to"],
    "な": ["na"], "に": ["ni"], "ぬ": ["nu"], "ね": ["ne"], "の": ["no"],
    "は": ["ha"], "ひ": ["hi"], "ふ": ["fu", "hu"], "へ": ["he"], "ほ": ["ho"],
    "ま": ["ma"], "み": ["mi"], "む": ["mu"], "め": ["me"], "も": ["mo"],
    "や": ["ya"], "ゆ": ["yu"], "よ": ["yo"],
    "ら": ["ra"], "り": ["ri"], "る": ["ru"], "れ": ["re"], "ろ": ["ro"],
    "わ": ["wa"], "ゐ": ["wi"], "ゑ": ["we"], "を": ["wo", "o"], "ん": ["n", "nn"],
    "が": ["ga"], "ぎ": ["gi"], "ぐ": ["gu"], "げ": ["ge"], "ご": ["go"],
    "ざ": ["za"], "じ": ["ji", "zi"], "ず": ["zu"], "ぜ": ["ze"], "ぞ": ["zo"],
    "だ": ["da"], "ぢ": ["di", "ji", "zi"], "づ": ["du", "zu"], "で": ["de"], "ど": ["do"],
    "ば": ["ba"], "び": ["bi"], "ぶ": ["bu"], "べ": ["be"], "ぼ": ["bo"],
    "ぱ": ["pa"], "ぴ": ["pi"], "ぷ": ["pu"], "ぺ": ["pe"], "ぽ": ["po"],
    "ゔ": ["vu"],
    "ぁ": ["xa", "la"], "ぃ": ["xi", "li"], "ぅ": ["xu", "lu"], "ぇ": ["xe", "le"], "ぉ": ["xo", "lo"],
    "ゃ": ["xya", "lya"], "ゅ": ["xyu", "lyu"], "ょ": ["xyo", "lyo"], "ゎ": ["xwa", "lwa"],
}
# i-row kana → onsets of their palatalized digraphs (きゃ = kya).
YOON = {
    "き": ["ky"], "し": ["sh", "sy"], "ち": ["ch", "ty", "cy"], "に": ["ny"], "ひ": ["hy"],
    "み": ["my"], "り": ["ry"], "ぎ": ["gy"], "じ": ["j", "zy", "jy"], "ぢ": ["dy", "j", "zy"],
    "び": ["by"], "ぴ": ["py"],
}
SMALL_VOWEL_LETTER = {"ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o", "ゃ": "a", "ゅ": "u", "ょ": "o"}
DIGRAPH = {
    "ふぁ": ["fa"], "ふぃ": ["fi"], "ふぇ": ["fe"], "ふぉ": ["fo"],
    "しぇ": ["she", "sye"], "じぇ": ["je", "zye"], "ちぇ": ["che", "tye"],
    "てぃ": ["thi"], "でぃ": ["dhi"], "とぅ": ["twu"], "どぅ": ["dwu"],
    "うぃ": ["wi"], "うぇ": ["we"], "うぉ": ["who"], "いぇ": ["ye"],
    "ゔぁ": ["va"], "ゔぃ": ["vi"], "ゔぇ": ["ve"], "ゔぉ": ["vo"],
}
SOKUON_CONSONANTS = "kstpc"
MAX_SPELLINGS = 24


def moras(kana):
    result, i = [], 0
    while i < len(kana):
        if i + 1 < len(kana) and (kana[i + 1] in SMALL_YOON or kana[i + 1] in SMALL_VOWELS):
            pair = kana[i:i + 2]
            if pair in DIGRAPH or (kana[i] in YOON and kana[i + 1] in SMALL_YOON):
                result.append(pair); i += 2; continue
        result.append(kana[i]); i += 1
    return result


def mora_spellings(mora):
    if mora in DIGRAPH:
        return DIGRAPH[mora]
    if len(mora) == 2:
        return [onset + SMALL_VOWEL_LETTER[mora[1]] for onset in YOON[mora[0]]]
    return MONO.get(mora)


def romaji(kana):
    """Every way to type `kana` with romaji, as Japanese IMEs accept it.

    Hepburn, kunrei and nihon-shiki spellings; ん as n or nn; っ before a mora
    as that mora's doubled first consonant. Long vowels are typed as written
    (こう = kou). A trailing っ is handled by the caller (sokuon segments).
    """
    parts = moras(kana)
    spellings = [""]
    i = 0
    while i < len(parts):
        mora = parts[i]
        if mora == "っ" and i + 1 < len(parts):
            following = mora_spellings(parts[i + 1])
            if following is None:
                return []
            options = []
            for spelling in following:
                options.append(spelling[0] + spelling)
                if spelling.startswith("ch"):
                    options.append("t" + spelling)
            i += 2
        else:
            options = mora_spellings(mora)
            if options is None:
                return []
            i += 1
        spellings = [s + o for s in spellings for o in options][:MAX_SPELLINGS * 4]
    return spellings


VOICED = dict(zip("かきくけこさしすせそたちつてとはひふへほ", "がぎぐげござじずぜぞだぢづでどばびぶべぼ"))
SEMI_VOICED = dict(zip("はひふへほ", "ぱぴぷぺぽ"))


def rendaku_forms(reading):
    first = reading[0]
    forms = []
    if first in VOICED:
        forms.append(VOICED[first] + reading[1:])
        # ぢ/づ are read じ/ず; dictionaries spell 鼻血 as はなぢ but some
        # readings use the じ/ず spelling.
        if first == "ち": forms.append("じ" + reading[1:])
        if first == "つ": forms.append("ず" + reading[1:])
    if first in SEMI_VOICED:
        forms.append(SEMI_VOICED[first] + reading[1:])
    return forms


# MARK: sources

def load_unihan(data):
    """codepoint → (primary readings, secondary readings), toneless pinyin."""
    fields = {"kMandarin": [], "kXHC1983": [], "kTGHZ2013": [], "kHanyuPinyin": []}
    readings = defaultdict(lambda: defaultdict(list))
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        text = archive.read("Unihan_Readings.txt").decode("utf-8")
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        code, field, value = line.split("\t")
        if field not in fields:
            continue
        char = chr(int(code[2:], 16))
        if field == "kMandarin":
            values = value.split()
        else:
            values = [r for group in value.split() for r in group.split(":", 1)[1].split(",")]
        readings[char][field].extend(values)
    return readings


def toneless(syllable):
    decomposed = unicodedata.normalize("NFD", syllable.lower())
    result = []
    for c in decomposed:
        if c == "̈":
            if result and result[-1] == "u":
                result[-1] = "v"
            continue
        if unicodedata.combining(c):
            continue
        result.append(c)
    text = "".join(result)
    return text if re.fullmatch(r"[a-z]+", text) and re.search(r"[aeiouv]", text) else None


def pinyin_spellings(syllable):
    """Accepted spellings: v (and u after j/q/x/y) for ü; lue/nue for lüe/nüe."""
    spellings = {syllable}
    if syllable[0] in "jqxy":
        spellings.add(syllable.replace("v", "u"))
        if "u" in syllable and not syllable.startswith(("yo", "you")):
            spellings.add(syllable.replace("u", "v", 1))
    if syllable in ("lve", "nve"):
        spellings.add(syllable.replace("v", "u"))
    return sorted(spellings)


def load_opencc(texts):
    def table(text):
        mapping = {}
        for line in text.splitlines():
            if not line or line.startswith("#"):
                continue
            key, values = line.split("\t")
            mapping[key] = values.split()
        return mapping
    return table(texts["JPShinjitaiCharacters.txt"]), table(texts["TSCharacters.txt"])


def load_kanjidic(data):
    root = ET.fromstring(gzip.decompress(data))
    header = root.find("header")
    version = header.findtext("database_version")
    created = header.findtext("date_of_creation")
    readings = defaultdict(set)
    for character in root.iter("character"):
        literal = character.findtext("literal")
        for reading in character.iter("reading"):
            kind, value = reading.get("r_type"), reading.text or ""
            if kind == "ja_on":
                readings[literal].add(hira(value.replace("-", "")))
            elif kind == "ja_kun":
                value = value.replace("-", "")
                stem, _, okurigana = value.partition(".")
                readings[literal].add(stem)
                if okurigana:
                    readings[literal].add(stem + okurigana)
                    # 連用形: 取る → 取り(消し), 書く → 書き(初め).
                    last = okurigana[-1]
                    i_row = dict(zip("うくぐすつぬぶむる", "いきぎしちにびみり"))
                    if last in i_row:
                        readings[literal].add(stem + okurigana[:-1] + i_row[last])
                    if okurigana.endswith("る") and len(okurigana) >= 2:
                        readings[literal].add(stem + okurigana[:-1])  # 一段: 食べる → 食べ
    return {k: {r for r in v if r and all(is_hiragana(c) for c in r)} for k, v in readings.items()}, version, created


def load_mozc(revision):
    base = f"https://raw.githubusercontent.com/google/mozc/{revision}/src/data/dictionary_oss"
    entries = defaultdict(list)
    hashes = {}
    for number in range(10):
        name = f"dictionary{number:02}.txt"
        data = fetch(f"{base}/{name}", MOZC_CACHE / f"{revision}-{name}")
        hashes[name] = sha256(data)
        for line in data.decode("utf-8").splitlines():
            fields = line.split("\t")
            if len(fields) < 5:
                continue
            reading, lid, _, cost, surface = fields[:5]
            entries[(reading, surface)].append((int(lid), int(cost)))
    data = fetch(f"{base}/id.def", MOZC_CACHE / f"{revision}-id.def")
    hashes["id.def"] = sha256(data)
    fragments, numbers = set(), set()
    for line in data.decode("utf-8").splitlines():
        number, _, pos = line.partition(" ")
        if is_fragment(pos):
            fragments.add(int(number))
        if pos.startswith("名詞,数"):
            numbers.add(int(number))
    return entries, hashes, fragments, numbers


def is_fragment(pos):
    """Parts of speech that are not a word someone would look up.

    Number kanji (澗, cost 0), suffixes and prefixes, particles, and inflected
    verb/adjective stems (揃っ, 乗り as 連用形) have very low Mozc costs and would
    outrank real words (乗り over 勝利 for shengri). Dictionary forms stay.
    """
    fields = pos.split(",")
    if pos.startswith(("名詞,数", "名詞,接尾", "接頭詞", "助詞", "助動詞", "記号", "フィラー", "感動詞")):
        return True
    return fields[0] in ("動詞", "形容詞") and len(fields) > 5 and fields[5] != "基本形"


# MARK: word list

def effective_cost(pos_entries, fallback, fragments):
    costs = []
    for lid, cost in pos_entries:
        if lid in PERSON_NAMES or lid in fragments:
            continue
        costs.append(cost + PROPER_PENALTY.get(lid, 0))
    if pos_entries and not costs:
        return None, False
    proper = bool(pos_entries) and all(lid in PROPER_PENALTY or lid in PERSON_NAMES for lid, _ in pos_entries)
    return (min(costs) if costs else fallback), proper


NUMERALS = set("〇零一二三四五六七八九十百千万億兆京垓秭穣溝澗正載極壱弐参拾廿卅数幾")


def load_words(mozc, fragments, numbers):
    words = []
    for line in (RESOURCES / "JapaneseLexicon.tsv").read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        reading = fields[0]
        for surface, cost in zip(fields[1::2], fields[2::2]):
            if not (1 <= len(surface) <= MAX_WORD_LENGTH) or not any(is_kanji(c) for c in surface):
                continue
            if not all(is_kanji(c) or is_hiragana(c) or is_katakana(c) or c in "々ヶ" for c in surface):
                continue
            # A counted word (三ヶ月, 一日, 二人) is 名詞,数 in Mozc but is a real
            # word; only bare numerals (澗, 三百) stay dropped.
            dropped = fragments - numbers if any(is_kanji(c) and c not in NUMERALS for c in surface) else fragments
            value, proper = effective_cost(mozc.get((reading, surface), []), int(cost), dropped)
            if value is None or value > MAX_COST:
                continue
            words.append((surface, reading, value, proper))
    return words


# MARK: alignment

def align(surface, reading, inventory):
    """Split `reading` into one segment per character of `surface`.

    Returns [(segment, citation)] or None. A kanji's segment is one of its
    readings, possibly with rendaku (voiced first mora, not on the first
    character) or sokuon (final つ/ち/く/き → っ before another character).
    `citation` is the dictionary form the user may type instead (がく for がっ,
    たな for だな). Kana must match themselves; 々 repeats the previous kanji.
    The alignment with the fewest such changes wins.
    """
    n, total = len(surface), len(reading)
    best = {}

    def options(i):
        c = surface[i]
        if c == "ヶ":
            return [(r, None, 0) for r in ("か", "が", "こ")]
        if is_hiragana(c) or is_katakana(c):
            return [(hira(c), None, 0)]
        source = surface[i - 1] if c == "々" and i > 0 else c
        result = []
        for r in sorted(inventory.get(source, ())):
            result.append((r, None, 0))
            if i > 0:
                result += [(form, r, 1) for form in rendaku_forms(r)]
            if i < n - 1 and len(r) >= 2 and r[-1] in "つちくき":
                result.append((r[:-1] + "っ", r, 1))
                if i > 0:
                    result += [(form[:-1] + "っ", r, 2) for form in rendaku_forms(r)]
        return result

    def search(i, pos):
        if i == n:
            return (0, []) if pos == total else None
        key = (i, pos)
        if key in best:
            return best[key]
        result = None
        for segment, citation, changes in options(i):
            if not reading.startswith(segment, pos):
                continue
            rest = search(i + 1, pos + len(segment))
            if rest is None:
                continue
            candidate = (changes + rest[0], [(segment, citation)] + rest[1])
            if result is None or candidate[0] < result[0]:
                result = candidate
        best[key] = result
        return result

    found = search(0, 0)
    return found[1] if found else None


# MARK: build

class Builder:
    def __init__(self):
        self.spellings, self.spelling_ids = [], {}
        self.chars, self.char_ids = [], {}
        self.segments, self.segment_ids = [], {}
        self.id_list = []

    def spelling(self, text):
        if text not in self.spelling_ids:
            self.spelling_ids[text] = len(self.spellings)
            self.spellings.append(text)
        return self.spelling_ids[text]

    def id_range(self, ids):
        start = len(self.id_list)
        self.id_list.extend(ids)
        assert len(ids) < 256 and start < (1 << 24)
        return start | (len(ids) << 24)

    def char(self, c, source, pinyin):
        """`source` supplies the pinyin: 々 is read as the kanji before it."""
        if (c, source) not in self.char_ids:
            ids = []
            for syllable, secondary in pinyin.get(source, []):
                for spelling in pinyin_spellings(syllable):
                    value = self.spelling(spelling) | (SECONDARY if secondary else 0)
                    if value & ~SECONDARY not in [v & ~SECONDARY for v in ids]:
                        ids.append(value)
            self.char_ids[(c, source)] = len(self.chars)
            self.chars.append((ord(c), ids))
        return self.char_ids[(c, source)]

    def segment(self, kana, citation):
        key = (kana, citation)
        if key not in self.segment_ids:
            spellings = []
            if kana.endswith("っ"):
                spellings = [s + c for s in romaji(kana[:-1]) for c in SOKUON_CONSONANTS]
            else:
                spellings = romaji(kana)
            if citation:
                spellings += romaji(citation)
            ids = []
            for s in dict.fromkeys(spellings):
                if len(ids) == MAX_SPELLINGS:
                    break
                ids.append(self.spelling(s))
            self.segment_ids[key] = len(self.segments)
            self.segments.append((kana, ids))
        return self.segment_ids[key]


def build_pinyin(unihan, shinjitai, traditional_to_simplified):
    """Japanese character → [(toneless syllable, secondary)].

    Shinjitai read as their traditional (and simplified) forms only: Unihan's
    own reading of 軽 is zhì, a different character. A character whose only
    reading is the editorial kMandarin (most kokuji: 込 yū, 峠 qiǎ) has none.
    """
    def readings(c):
        fields = unihan.get(c, {})
        primary = [s for f in ("kMandarin", "kXHC1983", "kTGHZ2013") for s in fields.get(f, [])]
        if not (fields.get("kXHC1983") or fields.get("kTGHZ2013") or fields.get("kHanyuPinyin")):
            return [], []
        return primary, fields.get("kHanyuPinyin", [])

    table = {}
    for c in set(unihan) | set(shinjitai):
        if c in JAPANESE_ONLY:
            continue
        forms = shinjitai.get(c, [c])
        forms = list(dict.fromkeys(forms + [s for f in forms for s in traditional_to_simplified.get(f, [])]))
        primary, secondary = [], []
        for form in forms:
            p, s = readings(form)
            primary += p; secondary += s
        result, seen = [], set()
        for syllable, is_secondary in [(s, False) for s in primary] + [(s, True) for s in secondary]:
            value = toneless(syllable)
            if value and value not in seen:
                seen.add(value); result.append((value, is_secondary))
        if result:
            table[c] = result
    # ヶ (三ヶ月) stands for 個/个, read gè.
    table["ヶ"] = [("ge", False)]
    return table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kanjidic", type=Path, help="a local kanjidic2.xml.gz to rebuild from")
    arguments = parser.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)

    revision = json.loads((RESOURCES / "DictionarySource.json").read_text())["revision"]
    unihan_data = fetch(UNIHAN_URL, CACHE / "Unihan-17.0.0.zip")
    opencc = {name: fetch(f"{OPENCC_BASE}/{name}", CACHE / f"opencc-{OPENCC_COMMIT[:12]}-{name}") for name in OPENCC_FILES}
    kanjidic_data = arguments.kanjidic.read_bytes() if arguments.kanjidic else fetch(KANJIDIC_URL, CACHE / "kanjidic2.xml.gz")
    mozc, mozc_hashes, fragments, numbers = load_mozc(revision)

    unihan = load_unihan(unihan_data)
    shinjitai, ts = load_opencc({k: v.decode("utf-8") for k, v in opencc.items()})
    pinyin = build_pinyin(unihan, shinjitai, ts)
    inventory, kanjidic_version, kanjidic_created = load_kanjidic(kanjidic_data)
    words = load_words(mozc, fragments, numbers)
    # Single-kanji dictionary entries extend the reading inventory (e.g. names
    # of counters and readings KANJIDIC2 lists only with okurigana).
    for surface, reading, cost, _ in words:
        if len(surface) == 1 and is_kanji(surface) and cost <= 7000:
            inventory.setdefault(surface, set()).add(reading)

    builder = Builder()
    trie = {}           # node: {"children": {(char, seg): node}, "cost": int|None, "flags": int, "reading": str|None}
    def new_node():
        return {"children": {}, "cost": None, "flags": 0, "reading": None}
    root = new_node()
    stats = defaultdict(int)
    for surface, reading, cost, proper in sorted(words, key=lambda w: w[2]):
        segments = align(surface, reading, inventory)
        sources = [surface[i - 1] if c == "々" and i > 0 else c for i, c in enumerate(surface)]
        has_pinyin = all(s in pinyin for c, s in zip(surface, sources) if is_kanji(c) or c == "々")
        if segments is None and not has_pinyin:
            stats["dropped: unaligned with a character that has no pinyin"] += 1
            continue
        stats["aligned" if segments else "unaligned (pinyin only)"] += 1
        node = root
        for index, c in enumerate(surface):
            char_id = builder.char(c, sources[index], pinyin)
            if segments:
                segment_id = builder.segment(*segments[index])
            elif c != "ヶ" and (is_hiragana(c) or is_katakana(c)):
                segment_id = builder.segment(hira(c), None)
            else:
                segment_id = NO_SEGMENT
            node = node["children"].setdefault((char_id, segment_id), new_node())
        if node["cost"] is None or cost < node["cost"]:
            node["cost"] = cost
            node["flags"] = (1 if proper else 0)
            node["reading"] = None if segments else reading
        stats["words"] += 1
    assert len(builder.chars) < NO_SEGMENT and len(builder.segments) < NO_SEGMENT
    assert len(builder.spellings) < SECONDARY

    # Breadth-first numbering: node k (k > 0) is the target of edge k - 1, and
    # each node's edges are contiguous, so an edge needs no child pointer.
    order = [root]
    edges = []
    edge_start = []
    queue = deque([root])
    while queue:
        node = queue.popleft()
        edge_start.append(len(edges))
        for key in sorted(node["children"]):
            child = node["children"][key]
            edges.append(key)
            order.append(child)
            queue.append(child)
    edge_start.append(len(edges))
    node_count = len(order)

    text = bytearray()
    def put_text(value):
        encoded = value.encode("utf-8")
        offset = len(text)
        text.extend(encoded)
        assert len(encoded) < 256 and offset < (1 << 24)
        return offset | (len(encoded) << 24)

    spelling_blob = bytearray()
    spelling_table = []
    for s in builder.spellings:
        spelling_table.append(len(spelling_blob) | (len(s) << 24))
        spelling_blob.extend(s.encode("ascii"))

    char_table = b"".join(struct.pack("<II", cp, builder.id_range(ids)) for cp, ids in builder.chars)
    segment_table = b"".join(struct.pack("<II", put_text(kana), builder.id_range(ids)) for kana, ids in builder.segments)
    unaligned = []
    for index, node in enumerate(order):
        if node["reading"] is not None and node["cost"] is not None:
            unaligned.append(struct.pack("<II", index, put_text(node["reading"])))

    # Root edges by the first two letters of any of their spellings; a
    # one-letter spelling (a, e, o) uses the second index 26. A query reads
    # bucket (input[0], input[1]) and (input[0], 26), so it never scans the
    # thousands of root edges that merely share the first letter.
    buckets = [[] for _ in range(26 * 27)]
    for index in range(edge_start[0], edge_start[1]):
        char_id, segment_id = edges[index]
        keys = set()
        spellings = [builder.spellings[value & ~SECONDARY] for value in builder.chars[char_id][1]]
        if segment_id != NO_SEGMENT:
            spellings += [builder.spellings[value] for value in builder.segments[segment_id][1]]
        for spelling in spellings:
            keys.add((ord(spelling[0]) - 97) * 27 + (ord(spelling[1]) - 97 if len(spelling) > 1 else 26))
        for key in sorted(keys):
            buckets[key].append(index)
    bucket_offsets, bucket_edges = [], []
    for bucket in buckets:
        bucket_offsets.append(len(bucket_edges))
        bucket_edges.extend(bucket)
    bucket_offsets.append(len(bucket_edges))

    sections = [
        struct.pack(f"<{len(spelling_table)}I", *spelling_table),
        bytes(spelling_blob),
        char_table,
        segment_table,
        struct.pack(f"<{len(builder.id_list)}H", *builder.id_list),
        struct.pack(f"<{len(edge_start)}I", *edge_start),
        struct.pack(f"<{node_count}H", *[min(n["cost"], 0xFFFE) if n["cost"] is not None else NOT_TERMINAL for n in order]),
        bytes(n["flags"] for n in order),
        struct.pack(f"<{len(edges)}I", *[c | (s << 16) for c, s in edges]),
        struct.pack(f"<{len(bucket_offsets)}I", *bucket_offsets),
        struct.pack(f"<{len(bucket_edges)}I", *bucket_edges),
        b"".join(unaligned),
        bytes(text),
    ]
    header_size = 12 + 8 * len(sections)
    payload = bytearray(b"VPK1" + struct.pack("<II", 2, len(sections)) + bytes(8 * len(sections)))
    for index, section in enumerate(sections):
        while len(payload) % 4:
            payload.append(0)
        struct.pack_into("<II", payload, 12 + 8 * index, len(payload), len(section))
        payload.extend(section)
    assert header_size <= len(payload)
    OUTPUT.write_bytes(payload)

    manifest = {
        "schema": 2,
        "output": OUTPUT.name,
        "bytes": len(payload),
        "sha256": sha256(payload),
        "counts": {
            "words": stats["words"], "aligned": stats["aligned"], "pinyinOnly": stats["unaligned (pinyin only)"],
            "dropped": stats["dropped: unaligned with a character that has no pinyin"],
            "characters": len(builder.chars), "segments": len(builder.segments),
            "spellings": len(builder.spellings), "nodes": node_count,
        },
        "sources": {
            "lexicon": {"file": "JapaneseLexicon.tsv", "sha256": sha256((RESOURCES / "JapaneseLexicon.tsv").read_bytes())},
            "mozc": {"repository": "https://github.com/google/mozc/tree/" + revision + "/src/data/dictionary_oss", "revision": revision, "license": "BSD-3-Clause (Mozc); dictionary data under the NAIST IPAdic and ICOT terms in the Mozc LICENSE", "files": mozc_hashes,
                     "use": "part-of-speech ids: proper nouns downweighted, names and fragments dropped"},
            "unihan": {"url": UNIHAN_URL, "version": "17.0.0", "license": "Unicode-3.0", "sha256": sha256(unihan_data),
                       "fields": ["kMandarin", "kXHC1983", "kTGHZ2013", "kHanyuPinyin (secondary)"]},
            "opencc": {"repository": "https://github.com/BYVoid/OpenCC", "commit": OPENCC_COMMIT, "license": "Apache-2.0",
                       "files": {name: sha256(data) for name, data in opencc.items()}},
            "kanjidic2": {"url": KANJIDIC_URL, "license": "CC-BY-SA-4.0",
                          "copyright": "Electronic Dictionary Research and Development Group",
                          "databaseVersion": kanjidic_version, "dateOfCreation": kanjidic_created,
                          "sha256": sha256(kanjidic_data), "use": "on/kun readings for aligning word readings"},
        },
        "policy": {
            "maximumCost": MAX_COST, "maximumWordLength": MAX_WORD_LENGTH,
            "properNounPenalty": {str(k): v for k, v in PROPER_PENALTY.items()}, "personalNames": "dropped",
            "fragments": "dropped: bare numerals (counted words such as 三ヶ月 kept), affixes, particles, inflected verb/adjective stems",
            "japaneseOnlyCharacters": "".join(sorted(JAPANESE_ONLY)) + " and characters with only kMandarin",
        },
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    for key, value in sorted(stats.items()):
        print(f"{key}: {value:,}")
    print(f"characters {len(builder.chars):,}, segments {len(builder.segments):,}, spellings {len(builder.spellings):,}, "
          f"nodes {node_count:,}, root edges {edge_start[1]:,}; {len(payload):,} bytes", flush=True)


if __name__ == "__main__":
    sys.exit(main())
