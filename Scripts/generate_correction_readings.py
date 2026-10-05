#!/usr/bin/env python3
"""Make a compact query-priority index from the pinned azooKey loudstxt3 data.

The index contains hashes and lexical scores, no selected example spellings.
It is only a pruning hint; every displayed suggestion still needs converter
reading/consumption and lattice evidence. Binary schema follows DictionaryBuilder
at d59a28e4c7ca049aef04f29a91eae9677a7753f2.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct


def reading_hash(text):
    value = 14695981039346656037
    for byte in text.encode("utf-8"):
        value = ((value ^ byte) * 1099511628211) & 0xffffffffffffffff
    return value


def generate(directory, output):
    values = {}
    checksum = hashlib.sha256()
    entry_count = 0
    for file in sorted((directory / "louds").glob("*.loudstxt3")):
        binary = file.read_bytes()
        checksum.update(file.name.encode())
        checksum.update(binary)
        slots = struct.unpack_from("<H", binary)[0]
        offsets = list(struct.unpack_from(f"<{slots}I", binary, 2)) + [len(binary)]
        for start, end in zip(offsets, offsets[1:]):
            count = struct.unpack_from("<H", binary, start)[0]
            if not count:
                continue
            text_offset = start + 2 + count * 10
            reading = binary[text_offset:end].split(b"\t", 1)[0].decode("utf-8")
            if not 2 <= len(reading) <= 20 or not all(0x30a1 <= ord(c) <= 0x30fc for c in reading):
                continue
            entries = [struct.unpack_from("<HHHf", binary, start + 2 + i * 10) for i in range(count)]
            entry = max(entries, key=lambda value: value[3])
            score = entry[3]
            if not math.isfinite(score) or score < -17:
                continue
            key = reading_hash(reading)
            if key not in values or score > values[key][3]:
                values[key] = entry
            entry_count += count
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as destination:
        destination.write(b"VCR2" + struct.pack("<I", len(values)))
        for key, (lcid, rcid, mid, score) in sorted(values.items()):
            destination.write(struct.pack("<QfHHHH", key, score, lcid, rcid, mid, 0))
    print(json.dumps({"readings": len(values), "dictionaryEntries": entry_count,
        "bytes": output.stat().st_size, "sourceSHA256": checksum.hexdigest()}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dictionary", type=Path)
    parser.add_argument("--output", type=Path, default=Path("Shared/Resources/CorrectionReadings.bin"))
    args = parser.parse_args()
    generate(args.dictionary, args.output)
