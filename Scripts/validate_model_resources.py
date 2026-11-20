"""Validate the runtime Japanese V4.2 payload and the Chinese zh-v1 model before a Release build."""
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


def validate_v42(resources):
    """Runtime Japanese V4.2 model payload."""
    manifest = json.loads((resources / "VimeLMManifestV42.json").read_text())
    if (manifest["format"] != "vime_ios_lm_v4"
            or manifest["architecture"] != "tiny_gpt_v4"
            or manifest["compute_units"] != "CPU_ONLY"
            or manifest["minimum_ios"] != 18
            or manifest["vocab_size"] != 8192
            or manifest["context_length"] != 128
            or manifest["special_ids"] != {"pad": 0, "unk": 1, "bos": 2, "eos": 3}
            or manifest["reserved_marker_ids"] != [4, 5, 6]
            or not manifest["model_version"]):
        raise ValueError("V4.2 manifest identity is invalid")
    if digest(resources / "VimeJapaneseTokenizerV4.model") != manifest["tokenizer_sha256"]:
        raise ValueError("V4 tokenizer checksum mismatch")
    model = resources / "TinyJapaneseV42INT8.mlmodelc"
    expected = manifest["compiled_files_sha256"]
    actual = {p.relative_to(model).as_posix() for p in model.rglob("*") if p.is_file()}
    if not expected or actual != set(expected):
        raise ValueError("V4.2 compiled model is missing or its file set differs")
    for name, checksum in expected.items():
        relative = PurePosixPath(name)
        path = model / name
        if (relative.is_absolute() or ".." in relative.parts
                or not path.resolve().is_relative_to(model.resolve())
                or digest(path) != checksum):
            raise ValueError(f"V4.2 model checksum mismatch: {name}")
    return manifest["model_version"]


def validate_zh_kvbatch4(resources, manifest_name, resource_name, label):
    manifest = json.loads((resources / manifest_name).read_text())
    v4 = manifest["kv_batch_v4"]
    variant = v4.get("variant", {})
    functions = v4.get("functions", {})
    if (manifest["format"] != "vime_ios_lm_zh_kv_batch_v4"
            or v4["resource"] != resource_name
            or variant.get("name") != "fp32kv"
            or variant.get("kv") != "fp32" or variant.get("compute") != "fp32"
            or set(functions) != {"logits", "scored", "score", "prefix"}
            or any(functions[fn].get("batch_range") != [1, 16] for fn in ("logits", "scored", "score"))
            or functions["prefix"].get("batch_range") != [1, 1]
            or not {"atol", "rtol"} <= set(v4["alignment_tolerance"])):
        raise ValueError(f"{label} kvbatch-v4 manifest identity is invalid")
    if digest(resources / "VimeChineseTokenizerV1.model") != manifest["tokenizer_sha256"]:
        raise ValueError(f"{label} tokenizer checksum mismatch")
    validate_compiled(resources / resource_name, v4["compiled_files_sha256"], f"{label} kvbatch-v4")


def validate_zh_v1(resources):
    """The Chinese keyboard's models: zh-v2-20m (default) and zh-v1 (fallback),
    both as kvbatch-v4 fp32kv packages (logits, scored, score and prefix in one
    package, up to 16 rows, a shared prefix built without the output head) and
    their shared tokenizer. Keyboard extension only."""
    validate_zh_kvbatch4(resources, "VimeLMManifestZhKVBatchV4-fp32kv.json",
                         "TinyChineseKVBatchV4FP32KVINT8.mlmodelc", "zh-v1")
    validate_zh_kvbatch4(resources, "VimeLMManifestZhV2KVBatchV4-fp32kv.json",
                         "TinyChineseV2KVBatchV4FP32KVINT8.mlmodelc", "zh-v2-20m")
    retired = [name for name in ("VimeLMManifestZhV1.json", "VimeLMManifestZhV1KVBatchV3.json",
                                 "TinyChineseV1INT8.mlmodelc", "TinyChineseV1KVChunkINT8.mlmodelc",
                                 "TinyChineseV1KVBatchV2INT8.mlmodelc", "TinyChineseV1KVBatchV3INT8.mlmodelc",
                                 "TinyChineseV1KVSequenceINT8.mlmodelc") if (resources / name).exists()]
    if retired:
        raise ValueError(f"retired zh-v1 packages are still bundled: {', '.join(retired)}")
    return "vimeml-zh-v2-20m + vimeml-tiny-zh-v1 kvbatch-v4-fp32kv"


def validate_compiled(model, expected, label):
    actual = {p.relative_to(model).as_posix() for p in model.rglob("*") if p.is_file()}
    if not expected or actual != set(expected):
        raise ValueError(f"{label} compiled model is missing or its file set differs")
    for name, checksum in expected.items():
        relative = PurePosixPath(name)
        path = model / name
        if (relative.is_absolute() or ".." in relative.parts
                or not path.resolve().is_relative_to(model.resolve())
                or digest(path) != checksum):
            raise ValueError(f"{label} model checksum mismatch: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path,
                        default=Path(__file__).resolve().parents[1] / "Shared/Resources")
    args = parser.parse_args()
    try:
        runtime = validate_v42(args.resources)
        retired_ja = [name for name in ("VimeLMManifestV21.json", "VimeJapaneseTokenizerV2.model",
                                        "TinyJapaneseV21INT8.mlmodelc") if (args.resources / name).exists()]
        if retired_ja:
            raise ValueError(f"retired Japanese V2.1 files are still bundled: {', '.join(retired_ja)}")
        chinese = validate_zh_v1(args.resources)
    except (OSError, ValueError, KeyError) as error:
        print(f"error: Vime model preflight failed: {error}. Install the matching payload with "
              "Scripts/install_v42_resources.py or Scripts/install_zh_v1_resources.py.", file=sys.stderr)
        return 1
    print(f"Vime model preflight passed: runtime {runtime}; Chinese {chinese}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
