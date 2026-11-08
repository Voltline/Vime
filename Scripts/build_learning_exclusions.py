#!/usr/bin/env python3
"""Build Shared/Resources/LearningExclusions.bin from a local word list.

The word list itself is never committed. The output keeps only keyed 64-bit
SipHash-2-4 values of each normalized term, so the bundle cannot be turned
back into the list; a term can only be confirmed by guessing it.

    Scripts/build_learning_exclusions.py <terms.txt> [--allowed PATH] [--output PATH]

The output is git-ignored too. Seal it for Xcode Cloud with
    swift Scripts/seal_resource.swift seal Shared/Resources/LearningExclusions.bin \
        ci_scripts/LearningExclusions.sealed

Format (little endian):
    "VLX1", u32 blocked count, u32 allowed count,
    u64 blocked length mask, u64 allowed length mask,
    sorted u64 blocked hashes, sorted u64 allowed hashes.
A length mask sets bit n when some entry has n Unicode scalars.

Allowed entries are everyday words, read from allowed.txt beside the term list
unless --allowed names another file; it stays local like the list. A short
match (3 scalars or fewer) that cuts through one of them is ignored, so a
common word does not make the text around it look like a match.
"""
import argparse
import struct
import unicodedata
from pathlib import Path

# Must match LearningExclusionList.key in Swift.
K0 = 0xDD14D237F99FC171
K1 = 0xC869294860871512
MASK = (1 << 64) - 1



def rotl(x, b):
    return ((x << b) | (x >> (64 - b))) & MASK


def siphash24(data: bytes, k0: int = K0, k1: int = K1) -> int:
    v0 = k0 ^ 0x736F6D6570736575
    v1 = k1 ^ 0x646F72616E646F6D
    v2 = k0 ^ 0x6C7967656E657261
    v3 = k1 ^ 0x7465646279746573

    def rounds(n):
        nonlocal v0, v1, v2, v3
        for _ in range(n):
            v0 = (v0 + v1) & MASK; v1 = rotl(v1, 13); v1 ^= v0; v0 = rotl(v0, 32)
            v2 = (v2 + v3) & MASK; v3 = rotl(v3, 16); v3 ^= v2
            v0 = (v0 + v3) & MASK; v3 = rotl(v3, 21); v3 ^= v0
            v2 = (v2 + v1) & MASK; v1 = rotl(v1, 17); v1 ^= v2; v2 = rotl(v2, 32)

    end = len(data) - len(data) % 8
    for i in range(0, end, 8):
        m = int.from_bytes(data[i:i + 8], "little")
        v3 ^= m; rounds(2); v0 ^= m
    last = (len(data) & 0xFF) << 56
    for i, byte in enumerate(data[end:]):
        last |= byte << (8 * i)
    v3 ^= last; rounds(2); v0 ^= last
    v2 ^= 0xFF; rounds(4)
    return v0 ^ v1 ^ v2 ^ v3


def normalized(text: str) -> str:
    """NFKC, then ASCII letters lowercased: the same steps as the Swift side."""
    text = unicodedata.normalize("NFKC", text)
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in text)


def table(words):
    hashes, mask = set(), 0
    for word in words:
        word = normalized(word.strip())
        if not word:
            continue
        if len(word) > 63:
            raise SystemExit(f"entry longer than 63 scalars: {len(word)}")
        hashes.add(siphash24(word.encode("utf-8")))
        mask |= 1 << len(word)
    return sorted(hashes), mask


def self_test():
    key = bytes(range(16))
    k0, k1 = struct.unpack("<QQ", key)
    assert siphash24(b"", k0, k1) == 0x726FDB47DD0E0E31
    assert siphash24(bytes(range(15)), k0, k1) == 0xA129CA6149BE45E5
    assert normalized("ＡＢｃ") == "abc"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("terms", type=Path)
    parser.add_argument("--allowed", type=Path, help="everyday words, one or more per line (default: allowed.txt beside terms)")
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parent.parent / "Shared/Resources/LearningExclusions.bin")
    args = parser.parse_args()
    self_test()
    blocked, blocked_mask = table(args.terms.read_text(encoding="utf-8").splitlines())
    allowed_path = args.allowed or args.terms.with_name("allowed.txt")
    lines = allowed_path.read_text(encoding="utf-8").splitlines()
    allowed, allowed_mask = table(" ".join(l for l in lines if not l.startswith("#")).split())
    blob = b"VLX1" + struct.pack("<IIQQ", len(blocked), len(allowed), blocked_mask, allowed_mask)
    blob += b"".join(struct.pack("<Q", h) for h in blocked + allowed)
    args.output.write_bytes(blob)
    print(f"{args.output}: {len(blocked)} blocked, {len(allowed)} allowed, {len(blob)} bytes")


if __name__ == "__main__":
    main()
