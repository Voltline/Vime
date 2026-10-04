#!/usr/bin/env python3
"""Build a compact, UTF-8 sorted lexicon from a pinned Mozc revision.

Only dictionary data is used; Vime's converter does not implement Mozc's grammar
or connection-cost model. Run from the repository root (network required).
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Shared" / "Resources"
CACHE = Path("/private/tmp/vime-mozc")


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Vime-dictionary-builder"})
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.read()


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    manifest_path = OUTPUT / "DictionarySource.json"
    if manifest_path.exists():
        revision = json.loads(manifest_path.read_text())["revision"]
    else:
        revision = json.loads(fetch("https://api.github.com/repos/google/mozc/commits/master"))["sha"]
    base = f"https://raw.githubusercontent.com/google/mozc/{revision}"

    def shard(number):
        name = f"dictionary{number:02}.txt"
        path = CACHE / f"{revision}-{name}"
        if not path.exists():
            path.write_bytes(fetch(f"{base}/src/data/dictionary_oss/{name}"))
        return path

    entries = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for path in pool.map(shard, range(10)):
            for line in path.read_text().splitlines():
                fields = line.split("\t")
                if len(fields) < 5:
                    continue
                reading, _, _, cost, surface = fields[:5]
                cost = int(cost)
                if not (1 <= len(reading) <= 16) or cost > 8500:
                    continue
                if not all("\u3041" <= c <= "\u3096" or c == "ー" for c in reading):
                    continue
                if not surface or len(surface) > 24 or any(c in surface for c in "\t\n"):
                    continue
                values = entries.setdefault(reading, {})
                values[surface] = min(cost, values.get(surface, cost))
            print(f"Read {path.name}", flush=True)

    lines = []
    count = 0
    for reading in sorted(entries, key=lambda text: text.encode("utf-8")):
        values = sorted(entries[reading].items(), key=lambda item: (item[1], item[0]))[:6]
        count += len(values)
        lines.append("\t".join([reading] + [part for surface, cost in values for part in (surface, str(cost))]))
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    (OUTPUT / "JapaneseLexicon.tsv").write_bytes(payload)
    license_text = fetch(f"{base}/LICENSE").decode() + "\n\n" + fetch(f"{base}/src/data/dictionary_oss/README.txt").decode()
    (OUTPUT / "ThirdPartyNotices.txt").write_text(license_text)
    manifest_path.write_text(json.dumps({
        "project": "google/mozc", "revision": revision,
        "source": f"https://github.com/google/mozc/tree/{revision}/src/data/dictionary_oss",
        "readings": len(entries), "entries": count, "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "filters": "hiragana readings, length <= 16, cost <= 8500, best 6 distinct surfaces per reading",
    }, indent=2) + "\n")
    print(f"Built {len(entries):,} readings / {count:,} candidates / {len(payload):,} bytes", flush=True)


if __name__ == "__main__":
    main()
