#!/usr/bin/env python3
"""Checks Scripts/rime_words.txt before it goes into the Chinese dictionary.

    python3 Scripts/validate_rime_words.py [--cache DIR]

Every entry is checked for:

  format       the word, one tab and its toneless pinyin, each syllable
               lowercase and separated by one space, under a "## " section
  characters   two to MAX_WORD_LENGTH Chinese characters
  syllables    one known syllable per character
  readings     each syllable is a reading of its character in Unihan, or
               the phrase lists give the word that reading, so a typo such
               as "ba er" for 巴巴 is caught
  phrases      a word the phrase lists know is listed with at least one of
               their readings, so a polyphonic character (银行 yin hang) is
               not misread; a second reading they lack can go on its own line
  duplicates   no entry is listed twice, and no word is in two sections, so
               each word belongs to one domain
  parts        a warning, not a problem, when a word inside a new word reads
               differently in the phrase lists (银行卡号 yin xing ka hao)
  order        each section is sorted, so changes show up as small diffs
  downweights  no listed word is one build_rime_dicts.py drops to the lowest
               frequency

The character and phrase readings come from the pinned sources
build_rime_dicts.py uses, downloaded once into the cache (about 10 MB).
Problems are printed as "rime_words.txt:<line>: <message>", and as error
annotations on GitHub Actions; the exit status is 1 when there are any.
Warnings are printed the same way and do not fail the check.
"""
import argparse
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_rime_dicts as dicts  # noqa: E402

SECTION = re.compile(r"^## \S")
SPELLING = re.compile(r"^[a-z]+( [a-z]+)*$")
HAN = re.compile(r"^[一-鿿㐀-䶿]+$")


def character_readings(cache):
    """Character -> toneless readings, from the 通用规范汉字表 readings and
    every Unihan reading pinyin-data lists, plus the colloquial extras."""
    readings = defaultdict(set)
    repo, commit = dicts.SOURCES["pinyin-data"][:2]
    for data in (dicts.source("tghz", cache), dicts.fetch(f"{dicts.GITHUB}/{repo}/{commit}/pinyin.txt", cache)):
        for line in dicts.lines(data):
            code, values = line.split(":", 1)
            char = chr(int(code.strip()[2:], 16))
            readings[char].update(s for s in map(dicts.syllable, values.split(",")) if s)
    for char, (spelled, _) in dicts.EXTRA_READINGS.items():
        readings[char].add(spelled)
    return readings


def phrase_readings(cache):
    """Word -> toneless readings from the phrase lists."""
    phrases = defaultdict(set)
    for key in ("phrases", "cedict"):
        for line in dicts.lines(dicts.source(key, cache)):
            if ":" not in line:
                continue
            word, values = line.split(":", 1)
            spelled = [dicts.syllable(v) for v in values.split()]
            if len(spelled) == len(word.strip()) and all(spelled):
                phrases[word.strip()].add(" ".join(spelled))
    return phrases


def parse(path):
    """(line number, section, word, reading) per entry, and format problems."""
    entries, problems, section = [], [], None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.startswith("##"):
            if not SECTION.match(line):
                problems.append((number, f"section heading {line!r} needs '## ' and a name"))
            section = line[3:].strip()
            continue
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2 or not SPELLING.match(parts[1]) or parts[0] != parts[0].strip():
            problems.append((number, f"{line!r} needs the word, one tab and lowercase pinyin with single spaces"))
            continue
        if section is None:
            problems.append((number, f"{parts[0]} comes before the first '## ' section"))
            continue
        entries.append((number, section, parts[0], parts[1]))
    return entries, problems


def check(entries, readings, phrases, downweighted):
    problems, warnings = [], []
    valid = {s for values in readings.values() for s in values}
    seen, sections = {}, {}
    listed = defaultdict(set)
    for _, _, word, spelled in entries:
        listed[word].add(spelled)
    previous = {}
    for number, section, word, spelled in entries:
        syllables = spelled.split(" ")
        if not HAN.match(word) or not 2 <= len(word) <= dicts.MAX_WORD_LENGTH:
            problems.append((number, f"{word} needs 2 to {dicts.MAX_WORD_LENGTH} Chinese characters"))
            continue
        if len(syllables) != len(word):
            problems.append((number, f"{word} has {len(word)} characters but {len(syllables)} syllables"))
            continue
        unknown = [s for s in syllables if s not in valid]
        if unknown:
            problems.append((number, f"{word} {spelled}: {' '.join(unknown)} is not a pinyin syllable"))
            continue
        # A reading the phrase lists give the whole word stands, such as a
        # common reading the character tables leave out.
        misread = [f"{c} {s} (reads {'/'.join(sorted(readings[c])) or 'nothing'})"
                   for c, s in zip(word, syllables) if s not in readings[c] and spelled not in phrases[word]]
        if misread:
            problems.append((number, f"{word} {spelled}: " + ", ".join(misread)))
        elif word in phrases and not listed[word] & phrases[word]:
            problems.append((number, f"{word} {spelled}: the phrase lists read it {' / '.join(sorted(phrases[word]))}; "
                                     "list one of those too if both readings are used"))
        elif word not in phrases:
            # Words inside it the phrase lists know; a mismatch is only a
            # warning, since a set phrase such as 清平乐 (yue) can differ.
            for start in range(len(word) - 1):
                for end in range(start + 2, len(word) + 1):
                    part, read = word[start:end], " ".join(syllables[start:end])
                    if part != word and part in phrases and read not in phrases[part]:
                        warnings.append((number, f"{word} {spelled}: {part} reads "
                                                 f"{' / '.join(sorted(phrases[part]))} in the phrase lists, not {read}"))
        if (word, spelled) in seen:
            problems.append((number, f"{word} {spelled} is already on line {seen[word, spelled]}"))
        seen.setdefault((word, spelled), number)
        first = sections.setdefault(word, (section, number))
        if first[0] != section:
            problems.append((number, f"{word} is also in section {first[0]!r} (line {first[1]}); keep it in one"))
        key = (word, spelled)
        if section in previous and key < previous[section]:
            problems.append((number, f"{word} is out of order in its section; keep each section sorted"))
        previous[section] = max(key, previous.get(section, key))
        if dicts.downweight_hash(word) in downweighted:
            problems.append((number, f"{word} is on the downweight list; drop one of the two"))
    return problems, warnings


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--cache", type=Path, default=Path("/private/tmp/vime-rime-sources"))
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)

    path = dicts.WORDS
    entries, problems = parse(path)
    found, warnings = check(entries, character_readings(args.cache), phrase_readings(args.cache),
                            dicts.downweight_hashes())
    problems += found
    annotate = os.environ.get("GITHUB_ACTIONS") == "true"
    shown = path.relative_to(Path(__file__).resolve().parent.parent)
    for level, listed in (("error", problems), ("warning", warnings)):
        for number, message in sorted(listed):
            print(f"::{level} file={shown},line={number}::{message}" if annotate
                  else f"{path.name}:{number}: {level}: {message}")
    words = {word for _, _, word, _ in entries}
    print(f"{len(entries)} entries, {len(words)} words: {len(problems)} problems, {len(warnings)} warnings",
          file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
