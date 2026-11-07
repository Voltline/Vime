#!/usr/bin/env python3
"""Generates the Rime dictionaries for Vime's Chinese input.

    python3 Scripts/build_rime_dicts.py <output dir> [--cache DIR]

Writes three files into <output dir>:

  vime_pinyin.dict.yaml   simplified Chinese words and characters with full
                          pinyin and weights
  vime_english.dict.yaml  English words for mixed Chinese–English input
  SOURCE.txt              the pinned sources below

Scripts/build_rime_data.sh calls this and compiles the result. Every source is
fetched at a pinned revision (network required) and cached; only the generated
dictionaries are compiled into the app.

Sources and licenses:

  mozillazg/pinyin-data (MIT): the 8105 characters of 通用规范汉字表 with their
      readings (kTGHZ2013, from Unihan) and the most common reading of each
      (kMandarin_8105).
  Unihan kHanyuPinlu (Unicode License V3): reading counts, which split a
      polyphonic character's weight between its readings.
  mozillazg/phrase-pinyin-data (MIT): phrase readings (pinyin.txt), so a
      polyphonic character inside a word gets the word's reading. Its
      cc_cedict.txt, derived from CC-CEDICT (CC BY-SA 4.0), adds readings and
      words the MIT list lacks.
  fxsjy/jieba dict.txt (MIT): words with corpus counts.
  rspeer/wordfreq (data CC BY-SA 4.0): Chinese and English word frequencies.
  en-wl/wordlist, the English Speller Database formerly SCOWL (MIT-like): the
      English vocabulary up to size 70 and its capitalization.
  Tatoeba Mandarin sentences (CC BY 2.0 FR): short runs of words common in
      conversation, such as 好的, which no word list has.

The generated dictionaries contain CC BY-SA 4.0 data (CC-CEDICT, wordfreq) and
are distributed under CC BY-SA 4.0; see Shared/Resources/ThirdPartyNotices.txt.

Weights. Rime ranks the candidates of one reading by weight and builds a
sentence by maximizing the sum of log(weight) - log(1e8) - 13.8 over its
words. The weight of a word with frequency f (per 1e8 words) is
f^A * exp(B), chosen so that this sum is A times a unigram model's log
probability with a small bonus for fewer words (PHRASE_BONUS). A common pair
of characters then beats a rare word with the same reading, and the most
common character still stays below the weight 1e8 that learned words reach.
"""
import argparse
import bz2
import gzip
import hashlib
import io
import math
import re
import sys
import unicodedata
import urllib.request
import zipfile
from collections import defaultdict
from datetime import date
from pathlib import Path

GITHUB = "https://raw.githubusercontent.com"
SOURCES = {
    "pinyin-data": ("mozillazg/pinyin-data", "fe29ad32bdf352b31a02b9936e537f575432e9a6", "2026-11-01", "MIT"),
    "phrase-pinyin-data": ("mozillazg/phrase-pinyin-data", "4afa3226ce53c9138b939e83c3bb294dbe0da511", "2026-11-01",
                           "MIT; cc_cedict.txt CC BY-SA 4.0"),
    "jieba": ("fxsjy/jieba", "67fa2e36e72f69d9134b8a1037b83fbb070b9775", "2020-02-15", "MIT"),
    "wordfreq": ("rspeer/wordfreq", "912caf64b657478d1dff1138efdc078947d54bb1", "2025-01-04", "data CC BY-SA 4.0"),
    "wordlist": ("en-wl/wordlist", "1e5b7d3a72f47a71da5d28686c1dd4b397178485", "2026-06-24", "MIT-like"),
}
FILES = {
    "tghz": ("pinyin-data", "kTGHZ2013.txt"),
    "mandarin": ("pinyin-data", "kMandarin_8105.txt"),
    "phrases": ("phrase-pinyin-data", "pinyin.txt"),
    "cedict": ("phrase-pinyin-data", "cc_cedict.txt"),
    "jieba": ("jieba", "jieba/dict.txt"),
    "wordfreq_zh": ("wordfreq", "wordfreq/data/large_zh.msgpack.gz"),
    "wordfreq_en": ("wordfreq", "wordfreq/data/large_en.msgpack.gz"),
    "scowl": ("wordlist", "data/scowl-pre.txt"),
}
# Tatoeba replaces its export every week and keeps no old ones, so the counts
# taken from it are kept in COLLOCATIONS, which records the export it counted.
# --refresh-tatoeba downloads the current export and counts again.
TATOEBA = ("https://downloads.tatoeba.org/exports/per_language/cmn/cmn_sentences.tsv.bz2", "CC BY 2.0 FR")
COLLOCATIONS = Path(__file__).resolve().parent / "rime_collocations.txt"
UNIHAN = ("https://www.unicode.org/Public/18.0.0/ucd/Unihan.zip", "Unicode 18.0.0",
          "4c93ea9c1f636451729a840978f1667a53886af37ba854fdcce109721c63d43e", "Unicode License V3")

# Weight model (see the module docstring).
PHRASE_BONUS = 2.0
A = 2.5
B = 32.236 - A * (math.log(1e8) + PHRASE_BONUS)
# Share of a character's occurrences inside words counted toward its own weight,
# so a bound character such as 们 still ranks for its syllable.
IN_WORD_SHARE = 0.02
# Frequencies (per 1e8 words) for entries no corpus counts.
FLOOR_WORD = 0.3
FLOOR_CHAR = 0.05
# wordfreq's share in a frequency both lists have: it counts subtitles and
# social media, so it is closer to what people type than jieba's news corpus.
WORDFREQ_SHARE = 0.7
# A word only wordfreq has is often a tokenizer fragment such as 号的, so it
# needs a reading from the phrase lists, and it counts at half.
MAX_WORD_LENGTH = 10
# Tatoeba runs of words: at most this many characters, seen this often, with
# this share of their frequency in the sentences.
COLLOCATION_LENGTH = 4
COLLOCATION_MIN_COUNT = 2
COLLOCATION_SHARE = 0.3
# Colloquial readings the character table leaves out.
EXTRA_READINGS = {"这": ("zhei", 0.05), "那": ("nei", 0.03), "哪": ("nei", 0.03)}

ENGLISH_SIZE = 70
ENGLISH_LIMIT = 60000
# Short words that rank above Chinese abbreviations; other two-letter words
# would bury abbreviations such as "my" for 没有.
ENGLISH_SHORT_TOP = {"ok", "hi", "wifi"}
# Capitalization the word list lacks or does not prefer, and brand names.
ENGLISH_CASING = [
    "OK", "iPhone", "iPad", "iPod", "iOS", "iPadOS", "macOS", "watchOS", "tvOS", "visionOS", "iCloud", "iMessage",
    "iTunes", "AirPods", "AirDrop", "MacBook", "iMac", "FaceTime", "CarPlay", "Siri", "Xcode", "GitHub", "GitLab",
    "YouTube", "Google", "Gmail", "Facebook", "Instagram", "WhatsApp", "WeChat", "TikTok", "LinkedIn", "PayPal",
    "Netflix", "Spotify", "Twitter", "Reddit", "Wikipedia", "Microsoft", "Windows", "Android", "Bluetooth",
    "Wi-Fi", "USB", "PDF", "PPT", "Excel", "PowerPoint", "JavaScript", "TypeScript", "Python", "Java", "Swift",
    "Kotlin", "Linux", "Ubuntu", "ChatGPT", "OpenAI", "Tesla", "Nike", "Adidas", "Starbucks", "McDonald's", "KFC",
    "Uber", "Airbnb", "Amazon", "Apple", "Samsung", "Huawei", "Xiaomi", "Sony", "Nintendo", "PlayStation", "Xbox",
    "Steam", "Zoom", "Slack", "Discord", "Telegram", "Photoshop", "Chrome", "Safari", "Firefox", "HTML", "CSS",
    "API", "AI", "App", "DIY", "VIP", "CEO", "PS", "TV", "PC", "ID", "DJ", "UI", "UX", "FAQ", "GPS", "SUV",
]

VARIANT_INFO = re.compile(r"^(\+|([ABZCD_][.=?v~V\-@x]?(\{\d+\})?\s*)+)$")


def cached(url, cache):
    return cache / re.sub(r"[^A-Za-z0-9._-]", "_", url.split("://", 1)[1])


def fetch(url, cache, sha256=None):
    target = cached(url, cache)
    if not target.exists():
        print(f"fetching {url}", file=sys.stderr)
        request = urllib.request.Request(url, headers={"User-Agent": "Vime-rime-builder"})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
        cache.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    data = target.read_bytes()
    if sha256 and hashlib.sha256(data).hexdigest() != sha256:
        print(f"warning: {url} differs from the pinned file (sha256 {sha256}); "
              f"the dictionaries will differ from the shipped ones", file=sys.stderr)
    return data


def source(key, cache):
    name, path = FILES[key]
    repo, commit = SOURCES[name][:2]
    return fetch(f"{GITHUB}/{repo}/{commit}/{path}", cache)


def lines(data):
    for line in data.decode("utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            yield line


def unpack_msgpack(data):
    """Decodes the msgpack subset wordfreq uses (maps, arrays, strings, ints)."""
    position = 0

    def take(n):
        nonlocal position
        chunk = data[position:position + n]
        position += n
        return chunk

    def number(n):
        return int.from_bytes(take(n), "big")

    def value():
        kind = take(1)[0]
        if kind <= 0x7F:
            return kind
        if 0x80 <= kind <= 0x8F:
            return {value(): value() for _ in range(kind & 0x0F)}
        if 0x90 <= kind <= 0x9F:
            return [value() for _ in range(kind & 0x0F)]
        if 0xA0 <= kind <= 0xBF:
            return take(kind & 0x1F).decode("utf-8")
        sizes = {0xCC: 1, 0xCD: 2, 0xCE: 4, 0xCF: 8}
        if kind in sizes:
            return number(sizes[kind])
        strings = {0xD9: 1, 0xDA: 2, 0xDB: 4}
        if kind in strings:
            return take(number(strings[kind])).decode("utf-8")
        arrays = {0xDC: 2, 0xDD: 4}
        if kind in arrays:
            return [value() for _ in range(number(arrays[kind]))]
        maps = {0xDE: 2, 0xDF: 4}
        if kind in maps:
            return {value(): value() for _ in range(number(maps[kind]))}
        if kind == 0xC0:
            return None
        if kind in (0xC2, 0xC3):
            return kind == 0xC3
        raise ValueError(f"unsupported msgpack type {kind:#x}")

    return value()


def wordfreq_table(data):
    """Word -> frequency per 1e8 words from a wordfreq cBpack file."""
    bins = unpack_msgpack(gzip.decompress(data))
    assert bins[0].get("format") == "cB", bins[0]
    return {word: 10 ** (-index / 100) * 1e8 for index, words in enumerate(bins) if index for word in words}


def syllable(text):
    """Toned pinyin -> Rime spelling (no tone, ü as v), or None."""
    result = []
    for ch in unicodedata.normalize("NFD", text.strip().lower()):
        if ch == "̈":
            if result and result[-1] == "u":
                result[-1] = "v"
        elif not unicodedata.combining(ch):
            result.append(ch)
    text = "".join(result)
    return text if text.isascii() and text.isalpha() else None


def load_characters(cache):
    readings = {}
    for line in lines(source("tghz", cache)):
        code, values = line.split(":", 1)
        char = chr(int(code[2:], 16))
        spelled = [syllable(v) for v in values.split(",")]
        readings[char] = list(dict.fromkeys(s for s in spelled if s))
    primary = {}
    for line in lines(source("mandarin", cache)):
        code, value = line.split(":", 1)
        spelled = syllable(value.split(",")[0])
        if spelled:
            primary[chr(int(code[2:], 16))] = spelled
    pinlu = defaultdict(dict)
    archive = zipfile.ZipFile(io.BytesIO(fetch(UNIHAN[0], cache, UNIHAN[2])))
    for line in archive.read("Unihan_Readings.txt").decode("utf-8").splitlines():
        if "\tkHanyuPinlu\t" not in line:
            continue
        code, _, values = line.split("\t")
        for match in re.finditer(r"(\S+)\((\d+)\)", values):
            spelled = syllable(match.group(1))
            if spelled:
                counts = pinlu[chr(int(code[2:], 16))]
                counts[spelled] = counts.get(spelled, 0) + int(match.group(2))
    return readings, primary, pinlu


def load_phrases(key, cache, charset, valid):
    phrases = defaultdict(list)
    for line in lines(source(key, cache)):
        if ":" not in line:
            continue
        word, values = line.split(":", 1)
        word = word.strip()
        spelled = [syllable(v) for v in values.split()]
        if (len(word) < 2 or len(word) != len(spelled) or any(c not in charset for c in word)
                or any(s not in valid for s in spelled)):
            continue
        reading = " ".join(spelled)
        if reading not in phrases[word]:
            phrases[word].append(reading)
    return phrases


def load_jieba(cache):
    counts = {}
    for line in lines(source("jieba", cache)):
        parts = line.split()
        if len(parts) >= 2:
            counts[parts[0]] = counts.get(parts[0], 0) + int(parts[1])
    total = sum(counts.values())
    return {word: count * 1e8 / total for word, count in counts.items()}


def weight(frequency):
    return math.exp(A * math.log(frequency) + B)


def build_chinese(cache, refresh_tatoeba=False):
    readings, primary, pinlu = load_characters(cache)
    charset = set(readings)
    for char, (spelled, _) in EXTRA_READINGS.items():
        readings[char].append(spelled)
    valid = {s for values in readings.values() for s in values} - {"m", "n", "ng", "hm", "hng"}
    for char in list(readings):
        readings[char] = [s for s in readings[char] if s in valid]
        if not readings[char]:
            del readings[char]  # only m, n or ng
    phrases = load_phrases("phrases", cache, charset, valid)
    cedict = load_phrases("cedict", cache, charset, valid)
    jieba = load_jieba(cache)
    wordfreq = wordfreq_table(source("wordfreq_zh", cache))

    def frequency(word, known=True):
        j, w = jieba.get(word), wordfreq.get(word)
        if j and w:
            return math.exp((1 - WORDFREQ_SHARE) * math.log(j) + WORDFREQ_SHARE * math.log(w))
        if j:
            return j
        if w and known:
            return w / 2
        return None

    def share(char):
        """Reading -> share of the character's standalone use."""
        values = readings[char]
        counts = pinlu.get(char)
        if counts and any(counts.get(s) for s in values):
            total = sum(counts.get(s, 0) for s in values) + len(values)
            return {s: (counts.get(s, 0) + 1) / total for s in values}
        main = primary.get(char, values[0])
        main = main if main in values else values[0]
        rest = (1 - 0.85) / max(1, len(values) - 1)
        return {s: 0.85 if s == main else rest for s in values}

    best = {char: max(share(char).items(), key=lambda item: item[1])[0] for char in readings if readings[char]}

    # Words with their readings: phrase data first, then CC-CEDICT, then the
    # characters' most common readings.
    words = {}
    candidates = set(phrases) | set(cedict)
    candidates |= {w for w in jieba if 2 <= len(w) <= MAX_WORD_LENGTH and all(c in charset for c in w)}
    candidates |= {w for w in wordfreq if 2 <= len(w) <= MAX_WORD_LENGTH and all(c in charset for c in w)}
    for word in candidates:
        if len(word) > MAX_WORD_LENGTH:
            continue
        known = phrases.get(word) or cedict.get(word)
        f = frequency(word, bool(known))
        if f is None and not known:
            continue
        if known:
            spellings = known
        elif all(c in best for c in word):
            spellings = [" ".join(best[c] for c in word)]
        else:
            continue
        words[word] = (spellings, f if f is not None else FLOOR_WORD)

    # Characters: standalone frequency plus a share of their use in words,
    # split between readings.
    in_word = defaultdict(lambda: defaultdict(float))
    for word, (spellings, f) in words.items():
        for spelled in spellings:
            for char, s in zip(word, spelled.split()):
                in_word[char][s] += f / len(spellings)
    entries = {}
    for char, values in readings.items():
        standalone = frequency(char) or FLOOR_CHAR
        shares = share(char)
        for s in values:
            f = standalone * shares[s] + IN_WORD_SHARE * in_word[char].get(s, 0.0)
            if char in EXTRA_READINGS and EXTRA_READINGS[char][0] == s:
                f = standalone * EXTRA_READINGS[char][1]
            entries[char, s] = max(f, FLOOR_CHAR)

    # Collocations from Tatoeba; one that is a listed word keeps its reading.
    unigram = {word: f for word, (_, f) in words.items()}
    unigram.update({char: frequency(char) or FLOOR_CHAR for char in readings})
    counted = {word for word, (_, f) in words.items() if f > FLOOR_WORD}
    if refresh_tatoeba:
        count_collocations(cache, charset, unigram, counted)
    for gram, f in collocations().items():
        text = "".join(gram)
        if text in words:
            words[text] = (words[text][0], max(f, words[text][1]))
        else:
            words[text] = ([" ".join(words[w][0][0] if len(w) > 1 else best[w] for w in gram)], f)
    for word, (spellings, f) in words.items():
        for spelled in spellings:
            entries[word, spelled] = f / len(spellings)
    entries = [(text, code, f) for (text, code), f in entries.items()]
    entries.sort(key=lambda e: (-e[2], e[1], e[0]))
    return entries, valid


def segment(text, unigram):
    """The most likely words of `text` under the unigram model."""
    best = [(0.0, 0)] + [None] * len(text)
    for end in range(1, len(text) + 1):
        for start in range(max(0, end - MAX_WORD_LENGTH), end):
            word = text[start:end]
            if best[start] is None or (word not in unigram and end - start > 1):
                continue
            cost = best[start][0] + PHRASE_BONUS - math.log(unigram.get(word, FLOOR_CHAR) / 1e8)
            if best[end] is None or cost < best[end][0]:
                best[end] = (cost, start)
    words, end = [], len(text)
    while end:
        start = best[end][1]
        words.append(text[start:end])
        end = start
    return words[::-1]


def count_collocations(cache, charset, unigram, counted):
    """Counts short runs of words in Tatoeba's conversational sentences, such as
    好的 or 走吧, which no word list has but people type as a unit, and writes
    them to COLLOCATIONS. Without them a unigram model prefers a rare word with
    the same reading (号的)."""
    counts = defaultdict(int)
    total = 0
    raw = fetch(TATOEBA[0], cache)
    data = bz2.decompress(raw).decode("utf-8")
    for line in data.splitlines():
        text = line.split("\t")[-1]
        if any(("\u3400" <= c <= "\u9fff") and c not in charset for c in text):
            continue  # most likely Traditional Chinese
        for run in re.findall("[" + "".join(sorted(charset)) + "]+", text):
            words = segment(run, unigram)
            total += len(words)
            for n in (2, 3):
                for i in range(len(words) - n + 1):
                    gram = tuple(words[i:i + n])
                    if len("".join(gram)) <= COLLOCATION_LENGTH and "".join(gram) not in counted:
                        counts[gram] += 1
    kept = sorted((gram for gram, count in counts.items() if count >= COLLOCATION_MIN_COUNT),
                  key=lambda gram: (-counts[gram], gram))
    with COLLOCATIONS.open("w", encoding="utf-8") as out:
        out.write("# Short runs of words counted in the Tatoeba Mandarin sentences (CC BY 2.0 FR,\n"
                  "# https://tatoeba.org) by Scripts/build_rime_dicts.py --refresh-tatoeba; no sentence\n"
                  "# is included. Each line holds the words of a run and how often it occurs.\n")
        downloaded = date.fromtimestamp(cached(TATOEBA[0], cache).stat().st_mtime).isoformat()
        out.write(f"# source: {TATOEBA[0]} export {downloaded} "
                  f"sha256 {hashlib.sha256(raw).hexdigest()}\n")
        out.write(f"# words: {total}\n")
        for gram in kept:
            out.write(f"{' '.join(gram)}\t{counts[gram]}\n")


def collocation_source():
    """The `source:` line of COLLOCATIONS: URL, export date and SHA-256."""
    for line in COLLOCATIONS.read_text(encoding="utf-8").splitlines():
        if line.startswith("# source: "):
            return line[len("# source: "):]
    raise SystemExit(f"{COLLOCATIONS} has no source line")


def collocations():
    """Run of words -> frequency per 1e8 words, from COLLOCATIONS."""
    total, counts = None, {}
    for line in COLLOCATIONS.read_text(encoding="utf-8").splitlines():
        if line.startswith("# words: "):
            total = int(line[len("# words: "):])
        elif line and not line.startswith("#"):
            gram, count = line.split("\t")
            counts[tuple(gram.split(" "))] = int(count)
    return {gram: count / total * 1e8 * COLLOCATION_SHARE for gram, count in counts.items()}


def full_pinyin(code, valid):
    """True when `code` splits into whole pinyin syllables."""
    spellings = valid | {re.sub(r"^([jqxy])u", r"\1v", s) for s in valid} | {re.sub(r"^([nl])ve$", r"\1ue", s) for s in valid}
    reachable = [True] + [False] * len(code)
    for end in range(1, len(code) + 1):
        reachable[end] = any(reachable[start] and code[start:end] in spellings for start in range(max(0, end - 6), end))
    return reachable[-1]


def load_scowl(cache):
    """Code (lowercase letters) -> spellings in the word list up to ENGLISH_SIZE."""
    forms = defaultdict(set)
    for line in source("scowl", cache).decode("utf-8").splitlines():
        line = line.split(" #", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(": ")
        info = parts[0].split()
        if not info or not info[0].isdigit() or int(info[0]) > ENGLISH_SIZE or "AU" in info:
            continue
        rest = parts[1:]
        if rest and "<" not in rest[0] and VARIANT_INFO.match(rest[0]):
            if set(re.findall(r"[ABZCD_]", rest[0])) == {"D"}:
                continue
            rest = rest[1:]
        if not rest:
            continue
        lemma = rest[0].split(" <", 1)[0].split(" {", 1)[0].split(" (", 1)[0]
        texts = [lemma] + ([t for t in re.split(r"[,|()]", rest[1])] if len(rest) > 1 else [])
        for text in texts:
            text = text.strip().split(": ")[-1].strip().strip("-@!*~†").strip()
            if not re.fullmatch(r"[A-Za-z][A-Za-z'\-]*[A-Za-z]", text):
                continue
            code = re.sub(r"[^a-z]", "", text.lower())
            if code:
                forms[code].add(text)
    return forms


def preferred_form(code, spellings):
    """The plain lowercase word when the list has it, else its most common shape."""
    plain = [s for s in spellings if re.sub(r"[^a-z]", "", s) == code and s == s.lower() and s.isalpha()]
    if plain:
        return plain[0]
    lower = [s for s in spellings if s == s.lower()]
    if lower:
        return min(lower, key=len)
    return sorted(spellings, key=lambda s: (sum(c.isupper() for c in s), len(s), s))[0]


def build_english(cache, valid):
    frequencies = wordfreq_table(source("wordfreq_en", cache))
    forms = load_scowl(cache)
    casing = {re.sub(r"[^a-z]", "", word.lower()): word for word in ENGLISH_CASING}
    by_code = defaultdict(float)
    for word, f in frequencies.items():
        code = re.sub(r"[^a-z]", "", word)
        if code and re.fullmatch(r"[a-z][a-z'\-]*", word):
            by_code[code] += f
    words = []
    for code, f in by_code.items():
        if len(code) < 2 or not (code in forms or code in casing):
            continue
        words.append((code, casing.get(code) or preferred_form(code, forms[code]), f))
    for code, word in casing.items():
        if code not in by_code:
            words.append((code, word, 1.0))
    words.sort(key=lambda w: -w[2])
    words = words[:ENGLISH_LIMIT]
    top = math.log(words[0][2])
    bottom = math.log(min(w[2] for w in words))
    entries = []
    for code, word, f in words:
        rank = (math.log(f) - bottom) / (top - bottom)
        # Quality as Rime compares it across translators: a Chinese sentence
        # is 0 and a Chinese word with the full reading is about 1. A word
        # that is also whole pinyin, or a short one that may be an
        # abbreviation, ranks below Chinese; any other ranks above sentences.
        if full_pinyin(code, valid) or (len(code) < 3 and code not in ENGLISH_SHORT_TOP):
            quality = -0.6 + 0.4 * rank
        else:
            quality = 0.3 + 0.6 * rank
        # With initial_quality -1, a weight of (quality + 1) * 1e8 gives this quality.
        entries.append((word, code, (quality + 1) * 1e8))
    entries.sort(key=lambda e: (-e[2], e[1]))
    return entries


def write_dict(path, name, header, entries):
    with path.open("w", encoding="utf-8") as out:
        out.write(header)
        out.write(f"---\nname: {name}\nversion: \"1\"\nsort: by_weight\n...\n")
        for text, code, w in entries:
            out.write(f"{text}\t{code}\t{w:.6g}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("output", type=Path)
    parser.add_argument("--cache", type=Path, default=Path("/private/tmp/vime-rime-sources"))
    parser.add_argument("--refresh-tatoeba", action="store_true",
                        help=f"count the current Tatoeba export again into {COLLOCATIONS.name}")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    chinese, valid = build_chinese(args.cache, args.refresh_tatoeba)
    english = build_english(args.cache, valid)
    for entry in chinese:
        chinese_weight = weight(entry[2])
        assert chinese_weight < 1e8, entry
    write_dict(args.output / "vime_pinyin.dict.yaml", "vime_pinyin",
               "# Generated by Scripts/build_rime_dicts.py; sources in SOURCE.txt.\n",
               [(text, code, weight(f)) for text, code, f in chinese])
    write_dict(args.output / "vime_english.dict.yaml", "vime_english",
               "# Generated by Scripts/build_rime_dicts.py; sources in SOURCE.txt.\n", english)
    with (args.output / "SOURCE.txt").open("w") as out:
        for name, (repo, commit, date, license_name) in SOURCES.items():
            out.write(f"{repo} {commit} {date} ({license_name})\n")
        out.write(f"Unihan {UNIHAN[1]} {UNIHAN[0]} sha256 {UNIHAN[2]} ({UNIHAN[3]})\n")
        out.write(f"Tatoeba {collocation_source()} via Scripts/{COLLOCATIONS.name} ({TATOEBA[1]})\n")
    print(f"{len(chinese)} Chinese entries, {len(english)} English words", file=sys.stderr)


if __name__ == "__main__":
    main()
