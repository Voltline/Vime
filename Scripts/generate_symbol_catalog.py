#!/usr/bin/env python3
"""Build the bundled emoji catalog from Unicode's emoji-test.txt (UTF-8)."""
import argparse
import json
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("--output", type=Path, default=Path("Shared/Resources/EmojiCatalog.json"))
args = parser.parse_args()
groups = []
version = ""
for line in args.source.read_text(encoding="utf-8").splitlines():
    if line.startswith("# Version:"):
        version = line.split(":", 1)[1].strip()
    elif line.startswith("# group:"):
        groups.append({"name": line.split(":", 1)[1].strip(), "items": []})
    elif ";" in line and "#" in line:
        codes, tail = line.split(";", 1)
        status, comment = tail.split("#", 1)
        if status.strip() not in {"fully-qualified", "component"}:
            continue
        text = "".join(chr(int(code, 16)) for code in codes.split())
        match = re.match(r"\s*\S+\s+E[\d.]+\s+(.+)", comment)
        groups[-1]["items"].append({"text": text, "name": match.group(1) if match else text})
catalog = {"version": version, "source": f"https://www.unicode.org/Public/{version}.0/emoji/emoji-test.txt", "groups": groups}
args.output.write_text(json.dumps(catalog, ensure_ascii=True, separators=(",", ":")) + "\n", encoding="utf-8")
print(f"Emoji {version}: {sum(len(g['items']) for g in groups)} entries, {len(groups)} groups")
