"""Install the optional KV model; reuse the already verified V2 tokenizer."""
import argparse
import json
import shutil
from pathlib import Path
from validate_model_resources import validate_kv


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("resources", type=Path)
    args = p.parse_args()
    target = Path(__file__).resolve().parents[1] / "Shared/Resources"
    expected = json.loads((target / "VimeLMManifestV21KV.json").read_text())
    if json.loads((args.resources / "VimeLMManifestV21KV.json").read_text()) != expected:
        raise ValueError("KV resource manifest differs from client branch")
    validate_kv(args.resources, tokenizer_resources=target)
    destination = target / "TinyJapaneseV21KVINT8.mlmodelc"
    if destination.exists():
        raise ValueError("KV resources already exist; use a fresh checkout/version")
    shutil.copytree(args.resources / destination.name, destination)
    print("Installed matching optional KV model. Baseline and tokenizer retained.")


if __name__ == "__main__": main()
