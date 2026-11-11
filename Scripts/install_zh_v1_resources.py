"""Install the VimeML zh-v1 INT8 stateless model for the Chinese keyboard.

Reads VimeML `tiny-zh-v1-ios-resources-v1`, verifies the tokenizer and compiled
stateless files against its manifest, and writes the flat client manifest that
`VimeLanguageModel(variant: .zhV1)` loads. The keyboard extension bundles these
files; the app target excludes them.
"""
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
    parser.add_argument("package", type=Path, help="VimeML tiny-zh-v1-ios-resources-v1 directory")
    args = parser.parse_args()
    source = args.package.resolve() / "Resources"
    destination = ROOT / "Shared/Resources"
    supplied = json.loads((source / "VimeLMManifestZhV1.json").read_text())
    if (supplied["format"] != "vime_ios_lm_zh_v1" or supplied["architecture"] != "tiny_gpt_zh13"
            or supplied["vocab_size"] != 12288 or supplied["context_length"] != 128
            or supplied["compute_units"] != "CPU_ONLY" or supplied["minimum_ios"] != 18
            or supplied["special_ids"] != {"pad": 0, "unk": 1, "bos": 2, "eos": 3}):
        raise ValueError("Unexpected zh-v1 resource manifest.")
    tokenizer = source / "VimeChineseTokenizerV1.model"
    if digest(tokenizer) != supplied["tokenizer_sha256"]:
        raise ValueError("Wrong zh-v1 tokenizer.")
    entry = supplied["models"]["stateless"]
    model = source / entry["resource"]
    expected = entry["compiled_files_sha256"]
    if {p.relative_to(model).as_posix() for p in model.rglob("*") if p.is_file()} != set(expected):
        raise ValueError("Unexpected compiled resource files.")
    for name, sha in expected.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or digest(model / name) != sha:
            raise ValueError(f"Compiled resource identity mismatch: {name}")
    targets = [destination / model.name, destination / tokenizer.name, destination / "VimeLMManifestZhV1.json"]
    if any(path.exists() for path in targets):
        raise ValueError("zh-v1 resources already exist; remove them first to reinstall.")
    manifest = {key: supplied[key] for key in (
        "format", "architecture", "release_name", "model_version", "minimum_ios", "vocab_size", "context_length",
        "compute_units", "special_ids", "reserved_ids", "tokenizer_sha256", "checkpoint_sha256",
        "bundle_manifest_sha256", "kind", "quantization", "strict_fp32_logits_alignment_passed")}
    manifest.update(compiled_files_sha256=expected, source_manifest_sha256=entry["source_manifest_sha256"],
                    vimeml_resource_manifest_sha256=digest(source / "VimeLMManifestZhV1.json"),
                    interface=supplied["stateless_interface"],
                    policy="Chinese keyboard reranking model; never loaded together with a Japanese model.")
    shutil.copytree(model, targets[0])
    shutil.copyfile(tokenizer, targets[1])
    targets[2].write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print("Installed zh-v1 model/tokenizer/manifest into Shared/Resources.")


if __name__ == "__main__":
    main()
