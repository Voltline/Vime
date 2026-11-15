"""Install the VimeML zh-v1 INT8 models for the Chinese keyboard.

Reads VimeML `tiny-zh-v1-ios-resources-v1`, verifies the tokenizer and compiled
stateless files against its manifest, and writes the flat client manifest that
`VimeLanguageModel(variant: .zhV1)` loads. The keyboard extension bundles these
files; the app target excludes them.

`--kv` adds the chunked KV-cache package of the same checkpoint (used for
generation by `VimeKVLanguageModel`) to an existing install: it copies the
compiled model and records it under "kv" in the client manifest, with the
tolerances VimeML checked it against the stateless package.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(model, expected):
    if {p.relative_to(model).as_posix() for p in model.rglob("*") if p.is_file()} != set(expected):
        raise ValueError("Unexpected compiled resource files.")
    for name, sha in expected.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or digest(model / name) != sha:
            raise ValueError(f"Compiled resource identity mismatch: {name}")


def install_kv(source, destination, supplied, alignment_path):
    client_path = destination / "VimeLMManifestZhV1.json"
    client = json.loads(client_path.read_text())
    if "kv" in client:
        raise ValueError("The KV package is already installed; remove it first to reinstall.")
    if client["tokenizer_sha256"] != supplied["tokenizer_sha256"] or \
            client["checkpoint_sha256"] != supplied["checkpoint_sha256"] or \
            client["source_manifest_sha256"] != supplied["models"]["stateless"]["source_manifest_sha256"]:
        raise ValueError("The KV package belongs to another checkpoint or stateless package.")
    if supplied.get("kv_graph") != "chunk" or supplied.get("cache_dtype") != "float32":
        raise ValueError("Unexpected KV package kind.")
    if alignment_path is None:
        raise ValueError("--kv needs --alignment (the KV vs stateless alignment report).")
    alignment = json.loads(alignment_path.read_text())
    entry = supplied["models"]["kv"]
    if (not alignment.get("passed") or alignment["summary"]["failed_checks"] != 0
            or alignment["coreml_manifest_sha256"] != entry["source_manifest_sha256"]
            or alignment["baseline_manifest_sha256"] != client["source_manifest_sha256"]
            or digest(alignment_path) != supplied["kv_vs_stateless_alignment_sha256"]):
        raise ValueError("The alignment report does not cover these packages.")
    model = source / entry["resource"]
    verify(model, entry["compiled_files_sha256"])
    target = destination / model.name
    if target.exists():
        raise ValueError(f"{target.name} already exists; remove it first to reinstall.")
    client["kv"] = {
        "resource": model.name.removesuffix(".mlmodelc"),
        "compiled_files_sha256": entry["compiled_files_sha256"],
        "source_manifest_sha256": entry["source_manifest_sha256"],
        "interface": supplied["kv_interface"],
        "cache_shape": supplied["cache_shape"],
        "cache_dtype": supplied["cache_dtype"],
        "alignment_sha256": supplied["kv_vs_stateless_alignment_sha256"],
        "alignment_tolerance": alignment["tolerances"],
        "alignment_checks": alignment["summary"]["checks"],
        "policy": "Generation only (constrained beam search); reranking keeps the stateless package.",
    }
    shutil.copytree(model, target)
    client_path.write_text(json.dumps(client, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print("Installed the zh-v1 KV package into Shared/Resources.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="VimeML tiny-zh-v1-ios-resources-v1 directory")
    parser.add_argument("--kv", action="store_true", help="add the KV-cache package to an existing install")
    parser.add_argument("--alignment", type=Path,
                        help="VimeML zh-v1-align-kvchunk-int8-b32-vs-stateless-int8/alignment.json (with --kv)")
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
    if args.kv:
        return install_kv(source, destination, supplied, args.alignment)
    entry = supplied["models"]["stateless"]
    model = source / entry["resource"]
    expected = entry["compiled_files_sha256"]
    verify(model, expected)
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
