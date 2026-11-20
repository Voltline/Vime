"""Install VimeML's zh-v1 kvbatch-v4 (fp32kv) package for the Chinese keyboard.

Reads a directory holding the package as VimeML publishes it for clients
(VimeLMManifestZhKVBatchV4-fp32kv.json, TinyChineseKVBatchV4FP32KVINT8.mlmodelc
and VimeChineseTokenizerV1.model), checks the tokenizer and every compiled file
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
MANIFEST = "VimeLMManifestZhKVBatchV4-fp32kv.json"
MODEL = "TinyChineseKVBatchV4FP32KVINT8.mlmodelc"
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
    parser.add_argument("package", type=Path, help="directory with the kvbatch-v4 client files")
    args = parser.parse_args()
    source = args.package.resolve()
    destination = ROOT / "Shared/Resources"
    manifest = json.loads((source / MANIFEST).read_text())
    v4 = manifest["kv_batch_v4"]
    variant = v4.get("variant", {})
    if (manifest["format"] != "vime_ios_lm_zh_kv_batch_v4" or v4["resource"] != MODEL
            or variant.get("name") != "fp32kv" or variant.get("kv") != "fp32" or variant.get("compute") != "fp32"
            or set(v4["functions"]) != {"logits", "scored", "score", "prefix"}):
        raise ValueError("Unexpected zh-v1 kvbatch-v4 manifest.")
    if digest(source / TOKENIZER) != manifest["tokenizer_sha256"]:
        raise ValueError("Wrong zh-v1 tokenizer.")
    verify(source / MODEL, v4["compiled_files_sha256"])
    targets = [destination / MODEL, destination / TOKENIZER, destination / MANIFEST]
    if any(path.exists() for path in targets):
        raise ValueError("zh-v1 resources already exist; remove them first to reinstall.")
    shutil.copytree(source / MODEL, targets[0])
    shutil.copyfile(source / TOKENIZER, targets[1])
    shutil.copyfile(source / MANIFEST, targets[2])
    print("Installed the zh-v1 kvbatch-v4 package, tokenizer and manifest into Shared/Resources.")


if __name__ == "__main__":
    main()
