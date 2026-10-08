"""Validate the complete V2.1 payload before a Release build or in its bundle."""
import argparse
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            value.update(chunk)
    return value.hexdigest()


def validate(resources):
    manifest = json.loads((resources / "VimeLMManifestV21.json").read_text())
    if (manifest["format"] != "vime_ios_lm_v2"
            or manifest["architecture"] != "tiny_gpt_v2"
            or manifest["compute_units"] != "CPU_ONLY"
            or manifest["minimum_ios"] != 18
            or manifest["vocab_size"] != 16384
            or manifest["context_length"] != 128
            or manifest["special_ids"] != {"pad": 0, "unk": 1, "bos": 2, "eos": 3}
            or not manifest["model_version"]):
        raise ValueError("V2.1 manifest identity is invalid")
    if digest(resources / "VimeJapaneseTokenizerV2.model") != manifest["tokenizer_sha256"]:
        raise ValueError("V2 tokenizer checksum mismatch")
    model = resources / "TinyJapaneseV21INT8.mlmodelc"
    expected = manifest["compiled_files_sha256"]
    actual = {p.relative_to(model).as_posix() for p in model.rglob("*") if p.is_file()}
    if not expected or actual != set(expected):
        raise ValueError("V2.1 compiled model is missing or its file set differs")
    for name, checksum in expected.items():
        relative = PurePosixPath(name)
        path = model / name
        if (relative.is_absolute() or ".." in relative.parts
                or not path.resolve().is_relative_to(model.resolve())
                or digest(path) != checksum):
            raise ValueError(f"V2.1 model checksum mismatch: {name}")
    return manifest["model_version"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path,
                        default=Path(__file__).resolve().parents[1] / "Shared/Resources")
    args = parser.parse_args()
    try:
        version = validate(args.resources)
    except (OSError, ValueError, KeyError) as error:
        print(f"error: Vime model preflight failed: {error}. "
              "Install the matching payload with Scripts/install_v21_resources.py.", file=sys.stderr)
        return 1
    print(f"Vime model preflight passed: {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
