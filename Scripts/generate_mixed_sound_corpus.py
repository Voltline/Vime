#!/usr/bin/env python3
"""Reproducible test fixtures, independent of the Swift correction generator.

Every positive input changes exactly two distinct kana positions. Labels describe
an intended reading, not a guarantee that an ambiguous input should be corrected.
No production code or dictionary results are used to create/select these cases.
"""
import itertools
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GROUPS = [
    ("voicing", "かが"), ("voicing", "きぎ"), ("voicing", "くぐ"),
    ("voicing", "けげ"), ("voicing", "こご"), ("voicing", "さざ"),
    ("voicing", "しじ"), ("voicing", "すず"), ("voicing", "せぜ"),
    ("voicing", "そぞ"), ("voicing", "ただ"), ("affricate", "ちぢじ"),
    ("affricate", "つづず"), ("voicing", "てで"), ("voicing", "とど"),
    ("hbp", "はばぱ"), ("hbp", "ひびぴ"), ("hbp", "ふぶぷ"),
    ("hbp", "へべぺ"), ("hbp", "ほぼぽ"),
    ("smallKana", "やゃ"), ("smallKana", "ゆゅ"),
    ("smallKana", "よょ"), ("gemination", "つっ"),
]
READINGS = [
    "かぞく", "たなばた", "たてもの", "ともだち", "じどうしゃ", "でんしゃ",
    "べんきょう", "がっこう", "しずか", "かがみ", "たばこ", "ぱそこん",
    "はなび", "ひこうき", "ふくろ", "ほしぞら", "へいたい", "やきゅう",
    "ゆうやけ", "りょこう", "ざっし", "てつづき", "ぶんがく", "せいじ",
]

def substitutions(char):
    choices = {}
    for family, group in GROUPS:
        if char in group:
            for other in group:
                if other != char:
                    choices.setdefault(other, family)
    return sorted(choices.items())

cases = []
for reading in READINGS:
    positions = [i for i, char in enumerate(reading) if substitutions(char)]
    seen = set()
    for i, j in itertools.combinations(positions, 2):
        for (a, family_a), (b, family_b) in itertools.product(substitutions(reading[i]), substitutions(reading[j])):
            chars = list(reading)
            chars[i], chars[j] = a, b
            typed = "".join(chars)
            if typed in seen:
                continue
            seen.add(typed)
            cases.append({"id": f"{reading}:{i}:{a}:{j}:{b}", "input": typed,
                          "expectedReading": reading, "positions": [i, j],
                          "families": [family_a, family_b]})
normal = list(dict.fromkeys(READINGS + [
    "ががく", "かかく", "かがく", "ただしい", "ちかい", "じかい",
    "ちぢむ", "つづく", "すずしい", "きれい", "にほんご",
]))
archive = {"version": 1, "seedReadings": READINGS, "cases": cases, "normalReadings": normal}
path = ROOT / "Tests/UIKit/Resources/MixedSoundCorpus.json"
path.write_text(json.dumps(archive, ensure_ascii=False, indent=2) + "\n")
print(f"{len(cases)} two-error cases, {len(READINGS)} seed readings, {len(normal)} normal controls")
