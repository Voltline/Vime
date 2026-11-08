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
      cc_cedict.txt, derived from CC-CEDICT (CC BY-SA 4.0), adds readings the
      MIT list lacks.
  Tencent AI Lab Embedding Corpus for Chinese Words and Phrases v0.2.0 (CC BY
      3.0): its 12 million words and phrases in order of frequency on the web,
      the main vocabulary and frequency source (its top 400,000 words of two
      to six characters). Tencent no longer hosts it;
      the vocabulary file is taken from a mirror pinned by SHA-256.
  rime/rime-essay-simp (LGPL-3.0): word counts of Rime's default vocabulary.
  现代汉语常用词表 (2008) as a word list with readings and frequency ranks
      (gist indiejoseph/eae09c673460aa0b56db; no license stated): readings,
      and frequencies from a balanced corpus.
  rspeer/wordfreq (data CC BY-SA 4.0): English word frequencies.
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
    "essay": ("rime/rime-essay-simp", "dc06d4c96ae72ad46b29e3aa824a5d1e8f721fd0", "2022-01-14", "LGPL-3.0"),
    "wordfreq": ("rspeer/wordfreq", "912caf64b657478d1dff1138efdc078947d54bb1", "2025-01-04", "data CC BY-SA 4.0"),
    "wordlist": ("en-wl/wordlist", "1e5b7d3a72f47a71da5d28686c1dd4b397178485", "2026-06-24", "MIT-like"),
}
FILES = {
    "tghz": ("pinyin-data", "kTGHZ2013.txt"),
    "mandarin": ("pinyin-data", "kMandarin_8105.txt"),
    "phrases": ("phrase-pinyin-data", "pinyin.txt"),
    "cedict": ("phrase-pinyin-data", "cc_cedict.txt"),
    "essay": ("essay", "essay-zh-hans.txt"),
    "wordfreq_en": ("wordfreq", "wordfreq/data/large_en.msgpack.gz"),
    "scowl": ("wordlist", "data/scowl-pre.txt"),
}
# Tatoeba replaces its export every week and keeps no old ones, so the counts
# taken from it are kept in COLLOCATIONS, which records the export it counted.
# --refresh-tatoeba downloads the current export and counts again.
TATOEBA = ("https://downloads.tatoeba.org/exports/per_language/cmn/cmn_sentences.tsv.bz2", "CC BY 2.0 FR")
COLLOCATIONS = Path(__file__).resolve().parent / "rime_collocations.txt"
# Spam from Tencent's web text (porn and gambling site names and the like),
# reviewed by hand; these words drop to the lowest word frequency. The
# reviewed list itself (DOWNWEIGHTS, one word per line, a tab and the
# category) stays out of the repository; only salted hashes of its words are
# committed (DOWNWEIGHT_HASHES), which is all the build needs to match them.
# After editing the list, run --hash-downweights.
DOWNWEIGHTS = Path(__file__).resolve().parent / "rime_downweights.txt"
DOWNWEIGHT_HASHES = Path(__file__).resolve().parent / "rime_downweights.sha256"
DOWNWEIGHT_SALT = "vime-rime-downweight:"
TENCENT = ("https://huggingface.co/conanyu/tencent-ailab-embedding-zh-d200-v0.2.0-optim/resolve/"
           "26b432a69cca98e291a76b6e8e8890f3527b67b5/tencent-ailab-embedding-zh-d200-v0.2.0-key.txt",
           "v0.2.0 vocabulary", "9f4de2a6fcdd79692f172b6cf65078ced619919fd60e80c031f61bf13ac5e58a", "CC BY 3.0")
CHANGYONG = ("https://gist.githubusercontent.com/indiejoseph/eae09c673460aa0b56db/raw/"
             "b3a10af0119b28514cfc694485a317b272f3ab1a/%E7%8E%B0%E4%BB%A3%E6%B1%89%E8%AF%AD%E5%B8%B8%E7%94%A8%E8%AF%8D%E8%A1%A8.txt",
             "gist revision ac66c1900b048e3c72a4388b2304893ca3b9a571",
             "8e16b3e1c40593bfa81e18f285ecc830a349629877d45bdd033c2dd5b77783cb", "no license stated")
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
# The frequency of the most common character (的): its weight stays below the
# 1e8 that learned words reach.
TOP_FREQUENCY = 2.8e6
# Each source's share in the logarithm of a frequency several give. Tencent's
# web text is closest to what people type; essay is curated; the 2008 list
# comes from a balanced but more formal corpus.
SOURCE_SHARES = {"tencent": 0.5, "essay": 0.35, "changyong": 0.15}
# Tencent words beyond this rank (among Chinese entries) are left out unless
# another source lists them, as are longer ones.
TENCENT_LIMIT = 400_000
TENCENT_LENGTH = 6
MAX_WORD_LENGTH = 10
# A word no phrase list reads takes its characters' readings only where one
# reading has this share of the character's use.
DOMINANT_READING = 0.9
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


def load_essay(cache):
    """Word -> frequency from essay's counts, scaled so the most common entry
    has TOP_FREQUENCY."""
    counts = {}
    for line in lines(source("essay", cache)):
        parts = line.split("\t")
        if len(parts) == 2 and parts[1].isdigit():
            counts[parts[0]] = counts.get(parts[0], 0) + int(parts[1])
    top = max(counts.values())
    return {word: count * TOP_FREQUENCY / top for word, count in counts.items()}


def load_tencent(cache, charset):
    """Chinese words in Tencent's frequency order."""
    words, seen = [], set()
    for raw in fetch(TENCENT[0], cache, TENCENT[2]).split(b"\n"):
        word = raw.decode("gb18030", "replace").strip()
        if word and word not in seen and all(c in charset for c in word):
            seen.add(word)
            words.append(word)
    return words


def numbered_syllable(text):
    """Pinyin with a tone number (lv4, nue4, Zhong1) -> Rime spelling."""
    text = re.sub(r"[0-9]", "", text.strip().lower()).replace("u:", "v")
    return re.sub(r"^([nl])ue$", r"\1ve", text) or None


def load_changyong(cache, charset, valid):
    """Word -> (readings, frequency rank) from 现代汉语常用词表."""
    table = {}
    for line in fetch(CHANGYONG[0], cache, CHANGYONG[2]).decode("utf-8").splitlines():
        parts = line.strip().split("\t")
        if len(parts) != 3 or not parts[2].isdigit() or any(c not in charset for c in parts[0]):
            continue
        word, spelled = parts[0], [numbered_syllable(v) for v in parts[1].split("'")]
        readings, rank = table.get(word, ([], int(parts[2])))
        if len(spelled) == len(word) and all(v in valid for v in spelled):
            reading = " ".join(spelled)
            if reading not in readings:
                readings.append(reading)
        table[word] = (readings, min(rank, int(parts[2])))
    return table


def rank_scale(ranked, reference):
    """Maps a frequency rank to the frequency of the word with that rank in
    `reference` (word -> frequency), so ranked lists share essay's scale.
    Ranks past the reference follow Zipf's law from its last word."""
    values = sorted(reference.values(), reverse=True)
    last = len(values)
    return {word: values[rank] if rank < last else values[-1] * last / (rank + 1)
            for rank, word in enumerate(ranked)}


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
    essay = load_essay(cache)
    tencent_order = load_tencent(cache, charset)
    changyong = load_changyong(cache, charset, valid)
    # Characters and words each follow their own order in the ranked lists.
    sources = {"essay": essay}
    for name, ranked in (("tencent", tencent_order),
                         ("changyong", sorted(changyong, key=lambda w: changyong[w][1]))):
        scaled = {}
        for single in (True, False):
            subset = [w for w in ranked if (len(w) == 1) == single]
            reference = {w: f for w, f in essay.items() if (len(w) == 1) == single}
            scaled.update(rank_scale(subset, reference))
        sources[name] = scaled
    tencent_rank = {}
    for word in tencent_order:
        if len(word) > 1:
            tencent_rank[word] = len(tencent_rank)

    def frequency(word):
        found = {name: table[word] for name, table in sources.items() if word in table}
        if not found:
            return None
        total = sum(SOURCE_SHARES[name] for name in found)
        return math.exp(sum(SOURCE_SHARES[name] * math.log(f) for name, f in found.items()) / total)

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
    dominant = {char: reading for char in readings for reading, value in share(char).items()
                if len(readings[char]) == 1 or value >= DOMINANT_READING}

    def known_readings(word):
        return phrases.get(word) or (changyong[word][0] if word in changyong else None) or cedict.get(word)

    def inferred_reading(word):
        """Readings of the longest listed words inside `word`, and of
        characters with one dominant reading in between; None when a
        character's reading stays open."""
        parts, start = [], 0
        while start < len(word):
            for end in range(min(len(word), start + MAX_WORD_LENGTH), start + 1, -1):
                found = known_readings(word[start:end])
                if found:
                    parts.append(found[0])
                    start = end
                    break
            else:
                if word[start] not in dominant:
                    return None
                parts.append(dominant[word[start]])
                start += 1
        return " ".join(parts)

    # Words: every word a frequency source lists, with readings from the
    # phrase lists, else inferred from its parts.
    downweighted = downweight_hashes()
    words = {}
    candidates = {w for w in essay if len(w) > 1} | {w for w in changyong if len(w) > 1}
    # Two-character words only Tencent has are mostly names, typos and
    # fragments (泥嚎, 我门); a phrase list must know them too.
    candidates |= {w for w, rank in tencent_rank.items() if rank < TENCENT_LIMIT and len(w) <= TENCENT_LENGTH
                   and (len(w) > 2 or w in phrases or w in cedict)}
    for word in candidates:
        if len(word) > MAX_WORD_LENGTH:
            continue
        spellings = known_readings(word)
        if not spellings:
            reading = inferred_reading(word)
            if not reading:
                continue
            spellings = [reading]
        f = frequency(word)
        words[word] = (spellings, FLOOR_WORD if downweight_hash(word) in downweighted else f)

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
            # Parts the vocabulary no longer lists are read like any word.
            parts = [words[w][0][0] if w in words else best[w] if len(w) == 1 else inferred_reading(w)
                     for w in gram]
            if all(parts):
                words[text] = ([" ".join(parts)], f)
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


def downweight_hash(word):
    """The first 64 bits of the salted SHA-256 of the word, in hex."""
    return hashlib.sha256((DOWNWEIGHT_SALT + word).encode("utf-8")).hexdigest()[:16]


def downweight_hashes():
    return {line for line in DOWNWEIGHT_HASHES.read_text(encoding="utf-8").splitlines()
            if line and not line.startswith("#")}


def hash_downweights():
    """Writes DOWNWEIGHT_HASHES from the reviewed list, sorted so the file
    keeps neither the list's order nor its categories."""
    words = {line.split("\t")[0] for line in DOWNWEIGHTS.read_text(encoding="utf-8").splitlines()
             if line and not line.startswith("#")}
    hashes = sorted({downweight_hash(word) for word in words})
    assert len(hashes) == len(words), "hash collision"
    DOWNWEIGHT_HASHES.write_text(
        "# Salted SHA-256 (first 64 bits) of the words build_rime_dicts.py drops to\n"
        "# the lowest frequency: web spam from the Tencent vocabulary, reviewed by\n"
        "# hand. Generated by build_rime_dicts.py --hash-downweights.\n"
        + "".join(h + "\n" for h in hashes), encoding="utf-8")
    print(f"{len(hashes)} downweighted words hashed", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--hash-downweights", action="store_true",
                        help=f"write {DOWNWEIGHT_HASHES.name} from the reviewed {DOWNWEIGHTS.name}, then stop")
    parser.add_argument("--cache", type=Path, default=Path("/private/tmp/vime-rime-sources"))
    parser.add_argument("--refresh-tatoeba", action="store_true",
                        help=f"count the current Tatoeba export again into {COLLOCATIONS.name}")
    args = parser.parse_args()
    if args.hash_downweights:
        hash_downweights()
        return
    if args.output is None:
        parser.error("output is required")
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
        out.write(f"Tencent AI Lab Embedding Corpus {TENCENT[1]} {TENCENT[0]} sha256 {TENCENT[2]} ({TENCENT[3]})\n")
        out.write(f"现代汉语常用词表 {CHANGYONG[1]} {CHANGYONG[0]} sha256 {CHANGYONG[2]} ({CHANGYONG[3]})\n")
        out.write(f"Tatoeba {collocation_source()} via Scripts/{COLLOCATIONS.name} ({TATOEBA[1]})\n")
    print(f"{len(chinese)} Chinese entries, {len(english)} English words", file=sys.stderr)


if __name__ == "__main__":
    main()
