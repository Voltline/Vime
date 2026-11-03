#!/usr/bin/env python3
"""Local AJIMEE-Bench track for the candidate quality benchmark.

AJIMEE-Bench (https://github.com/azooKey/AJIMEE-Bench) is built from the
Japanese Wikipedia Typo Dataset v2 and is CC BY-SA 3.0, which cannot be
relicensed under GPL-3.0, so its data and the output stay outside version
control (Artifacts/CandidateBenchmark/ is ignored).

    python3 Scripts/build_candidate_benchmark_corpus.py              # clone, then build
    python3 Scripts/build_candidate_benchmark_corpus.py --source <AJIMEE-Bench checkout>

Never evaluate on text the model was trained on: FineWeb2-Edu Japanese,
Tatoeba, RealPersonaChat and the Multi-Relational Multi-Party Chat Corpus
(Vime/Resources/Licenses/vimeml.txt). The smart-ranking score would measure
recall of those sentences.

Only items whose reading is kana with 、 and 。 are kept: the harness types
them as romaji, where , and . produce the punctuation.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / "Artifacts/CandidateBenchmark"
REPOSITORY = "https://github.com/azooKey/AJIMEE-Bench.git"
ITEMS = "JWTD_v2/v1/evaluation_items.json"
READING = re.compile(r"^[ァ-ヺー、。]+$")


def hiragana(text: str) -> str:
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in text)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path, help="an AJIMEE-Bench checkout (else clone into Artifacts)")
    parser.add_argument("--output", type=Path, default=FOLDER / "ajimee.json")
    args = parser.parse_args()
    source = args.source
    if source is None:
        source = FOLDER / "AJIMEE-Bench"
        if not source.exists():
            subprocess.run(["git", "clone", "--depth", "1", REPOSITORY, str(source)], check=True)
    revision = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
    items = json.loads((source / ITEMS).read_text(encoding="utf-8"))
    cases = []
    for item in items:
        if not READING.match(item["input"]) or set(item["input"]) & set("ヰヱヮヵヶ"):
            continue
        cases.append({"id": "ajimee:" + item["index"],
                      "category": "contextual" if item["context_text"] else "plain",
                      "context": item["context_text"], "reading": hiragana(item["input"]),
                      "accept": item["expected_output"]})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    document = {"version": 1, "source": f"AJIMEE-Bench {ITEMS} (CC BY-SA 3.0)", "revision": revision, "cases": cases}
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(cases)} of {len(items)} items → {args.output}")


if __name__ == "__main__":
    main()
