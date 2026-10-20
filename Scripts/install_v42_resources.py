"""Install the VimeML V4.2 INT8 stateless model as an opt-in, non-default resource set.

Reads VimeML `tiny-ja-v4.2-epoch20-client-resources-v1`, verifies the tokenizer and
compiled stateless files against its manifest, and writes the flat client manifest
that `VimeLanguageModel(variant: .v42)` loads. V2.1 resources stay the default.
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
    parser.add_argument("package", type=Path, help="VimeML tiny-ja-v4.2-epoch20-client-resources-v1 directory")
    args = parser.parse_args()
    source = args.package.resolve() / "Resources"
    destination = ROOT / "Shared/Resources"
    supplied = json.loads((source / "VimeLMManifestV42.json").read_text())
    if (supplied["format"] != "vime_ios_lm_v4" or supplied["architecture"] != "tiny_gpt_v4"
            or supplied["vocab_size"] != 8192 or supplied["context_length"] != 128
            or supplied["compute_units"] != "CPU_ONLY" or supplied["minimum_ios"] != 18
            or supplied["special_ids"] != {"pad": 0, "unk": 1, "bos": 2, "eos": 3}
            or supplied["reserved_marker_ids"] != [4, 5, 6]):
        raise ValueError("Unexpected V4.2 resource manifest.")
    tokenizer = source / "VimeJapaneseTokenizerV4.model"
    if digest(tokenizer) != supplied["tokenizer_sha256"]:
        raise ValueError("Wrong V4 tokenizer.")
    entry = supplied["models"]["stateless"]
    model = source / entry["resource"]
    expected = entry["compiled_files_sha256"]
    if {p.relative_to(model).as_posix() for p in model.rglob("*") if p.is_file()} != set(expected):
        raise ValueError("Unexpected compiled resource files.")
    for name, sha in expected.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or digest(model / name) != sha:
            raise ValueError(f"Compiled resource identity mismatch: {name}")
    targets = [destination / model.name, destination / tokenizer.name, destination / "VimeLMManifestV42.json"]
    if any(path.exists() for path in targets):
        raise ValueError("V4.2 resources already exist; use a fresh checkout/version.")
    manifest = {key: supplied[key] for key in (
        "format", "architecture", "model_version", "minimum_ios", "vocab_size", "context_length",
        "compute_units", "special_ids", "forbidden_generation_ids", "reserved_marker_ids",
        "tokenizer_sha256", "checkpoint_sha256", "bundle_manifest_sha256", "kind", "quantization",
        "strict_fp32_logits_alignment_passed")}
    manifest.update(compiled_files_sha256=expected, source_manifest_sha256=entry["source_manifest_sha256"],
                    vimeml_resource_manifest_sha256=digest(source / "VimeLMManifestV42.json"),
                    interface=supplied["stateless_interface"],
                    policy="Opt-in measurement variant; V2.1 remains the default runtime model.")
    shutil.copytree(model, targets[0])
    shutil.copyfile(tokenizer, targets[1])
    targets[2].write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print("Installed opt-in V4.2 model/tokenizer/manifest.")


if __name__ == "__main__":
    main()
