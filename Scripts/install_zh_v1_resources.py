"""Install VimeML's zh-v1 kvbatch-v3 package for the Chinese keyboard.

Reads a directory holding the package as VimeML publishes it for clients
(VimeLMManifestZhV1KVBatchV3.json, TinyChineseV1KVBatchV3INT8.mlmodelc and
VimeChineseTokenizerV1.model), checks the tokenizer and every compiled file
against the manifest, and copies them into Shared/Resources, where
`ChineseLanguageModel` loads them. The keyboard extension bundles these
files; the app target excludes them.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = "VimeLMManifestZhV1KVBatchV3.json"
MODEL = "TinyChineseV1KVBatchV3INT8.mlmodelc"
TOKENIZER = "VimeChineseTokenizerV1.model"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(model, expected):
    if {p.relative_to(model).as_posix() for p in model.rglob("*") if p.is_file()} != set(expected):
        raise ValueError("Unexpected compiled resource files.")
    for name, sha in expected.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or digest(model / name) != sha:
            raise ValueError(f"Compiled resource identity mismatch: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="directory with the kvbatch-v3 client files")
    args = parser.parse_args()
    source = args.package.resolve()
    destination = ROOT / "Shared/Resources"
    manifest = json.loads((source / MANIFEST).read_text())
    v3 = manifest["kv_batch_v3"]
    if (manifest["format"] != "vime_ios_lm_zh_v1_kv_batch_v3" or v3["resource"] != MODEL
            or set(v3["functions"]) != {"logits", "scored", "score"} or v3["compute_units"] != "CPU_ONLY"):
        raise ValueError("Unexpected zh-v1 kvbatch-v3 manifest.")
    if digest(source / TOKENIZER) != manifest["tokenizer_sha256"]:
        raise ValueError("Wrong zh-v1 tokenizer.")
    verify(source / MODEL, v3["compiled_files_sha256"])
    targets = [destination / MODEL, destination / TOKENIZER, destination / MANIFEST]
    if any(path.exists() for path in targets):
        raise ValueError("zh-v1 resources already exist; remove them first to reinstall.")
    shutil.copytree(source / MODEL, targets[0])
    shutil.copyfile(source / TOKENIZER, targets[1])
    shutil.copyfile(source / MANIFEST, targets[2])
    print("Installed the zh-v1 kvbatch-v3 package, tokenizer and manifest into Shared/Resources.")


if __name__ == "__main__":
    main()
