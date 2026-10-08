"""Install the reviewed VimeML V2 resource payload without touching V1 assets."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("resources", type=Path, help="VimeML client-resources-v1/Resources directory")
    args = parser.parse_args()
    source = args.resources.resolve()
    destination = ROOT / "Shared/Resources"
    expected = json.loads((destination / "VimeLMManifestV21.json").read_text())
    supplied = json.loads((source / "VimeLMManifestV21.json").read_text())
    if supplied != expected or expected["format"] != "vime_ios_lm_v2":
        raise ValueError("Resource manifest differs from the client branch.")
    tokenizer = source / "VimeJapaneseTokenizerV2.model"
    if digest(tokenizer) != expected["tokenizer_sha256"]:
        raise ValueError("Wrong V2 tokenizer.")
    model = source / "TinyJapaneseV21INT8.mlmodelc"
    files = {p.relative_to(model).as_posix() for p in model.rglob("*") if p.is_file()}
    if files != set(expected["compiled_files_sha256"]):
        raise ValueError("Unexpected compiled resource files.")
    for name, sha in expected["compiled_files_sha256"].items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or digest(model / name) != sha:
            raise ValueError(f"Compiled resource identity mismatch: {name}")
    target_model = destination / model.name
    target_tokenizer = destination / tokenizer.name
    if target_model.exists() or target_tokenizer.exists():
        raise ValueError("V2 resources already exist; use a fresh checkout/version.")
    shutil.copytree(model, target_model)
    shutil.copyfile(tokenizer, target_tokenizer)
    print("Installed matching V2 model/tokenizer. V1 resources retained.")


if __name__ == "__main__":
    main()
