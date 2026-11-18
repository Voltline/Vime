"""Validate the runtime V4.2 payload, its V2.1 fallback and the Chinese zh-v1 model before a Release build."""
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


def validate_v42(resources):
    """Runtime default V4.2 set; the keyboard falls back to V2.1 only at runtime."""
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


def validate_zh_v1(resources):
    """Chinese keyboard models (reranking, and generation with KV); bundled in the keyboard extension only."""
    manifest = json.loads((resources / "VimeLMManifestZhV1.json").read_text())
    if (manifest["format"] != "vime_ios_lm_zh_v1"
            or manifest["architecture"] != "tiny_gpt_zh13"
            or manifest["compute_units"] != "CPU_ONLY"
            or manifest["minimum_ios"] != 18
            or manifest["vocab_size"] != 12288
            or manifest["context_length"] != 128
            or manifest["special_ids"] != {"pad": 0, "unk": 1, "bos": 2, "eos": 3}
            or not manifest["model_version"]):
        raise ValueError("zh-v1 manifest identity is invalid")
    if digest(resources / "VimeChineseTokenizerV1.model") != manifest["tokenizer_sha256"]:
        raise ValueError("zh-v1 tokenizer checksum mismatch")
    validate_compiled(resources / "TinyChineseV1INT8.mlmodelc", manifest["compiled_files_sha256"], "zh-v1")
    # The KV-cache package of the same checkpoint, for generation only.
    kv = manifest.get("kv")
    if kv is not None:
        if (kv["resource"] != "TinyChineseV1KVChunkINT8" or kv["cache_dtype"] != "float32"
                or kv["cache_shape"] != [9, 1, 6, 128, 64]
                or set(kv["alignment_tolerance"]) != {"atol", "rtol"}):
            raise ValueError("zh-v1 KV manifest identity is invalid")
        validate_compiled(resources / "TinyChineseV1KVChunkINT8.mlmodelc", kv["compiled_files_sha256"], "zh-v1 KV")
    elif (resources / "TinyChineseV1KVChunkINT8.mlmodelc").exists():
        raise ValueError("zh-v1 KV model is bundled without its manifest entry")
    # The fallbacks kvbatch-v2 and kv_sequence stay until v3 is measured on
    # devices. The batched KV package of the same checkpoint (kvbatch-v2): up to 16
    # rows, the prompt in one call, scores for a given id list only.
    v2_manifest = resources / "VimeLMManifestZhV1KVBatchV2.json"
    v2_model = resources / "TinyChineseV1KVBatchV2INT8.mlmodelc"
    v2 = json.loads(v2_manifest.read_text())["kv_batch_v2"] if v2_manifest.exists() else None
    if v2 is not None:
        outer = json.loads(v2_manifest.read_text())
        if (outer["format"] != "vime_ios_lm_zh_v1_kv_batch_v2"
                or outer["tokenizer_sha256"] != manifest["tokenizer_sha256"]
                or v2["resource"] != "TinyChineseV1KVBatchV2INT8.mlmodelc" or v2["head"] != "scored"
                or v2["cache_dtype"] != "float32" or v2["cache_shape"] != [9, "B", 6, "S", 64]
                or v2["batch_range"] != [1, 16] or v2["compute_units"] != "CPU_ONLY"
                or set(v2["alignment_tolerance"]) != {"atol", "rtol"}):
            raise ValueError("zh-v1 KV batch (kvbatch-v2) manifest identity is invalid")
        validate_compiled(v2_model, v2["compiled_files_sha256"], "zh-v1 KV batch (kvbatch-v2)")
    elif v2_model.exists():
        raise ValueError("zh-v1 KV batch (kvbatch-v2) model is bundled without its manifest")
    # The sequence-scoring KV package of the same checkpoint, for sentence
    # correction: per-token log probabilities of candidate continuations.
    seq_manifest = resources / "VimeLMManifestZhV1KVSequence.json"
    seq_model = resources / "TinyChineseV1KVSequenceINT8.mlmodelc"
    seq = json.loads(seq_manifest.read_text())["kv_sequence"] if seq_manifest.exists() else None
    if seq is not None:
        outer = json.loads(seq_manifest.read_text())
        if (outer["format"] != "vime_ios_lm_zh_v1_kv_sequence"
                or outer["tokenizer_sha256"] != manifest["tokenizer_sha256"]
                or seq["resource"] != "TinyChineseV1KVSequenceINT8.mlmodelc" or seq["head"] != "sequence"
                or seq["cache_dtype"] != "float32" or seq["cache_shape"] != [9, "B", 6, "S", 64]
                or seq["batch_range"] != [1, 16] or seq["compute_units"] != "CPU_ONLY"
                or set(seq["alignment_tolerance"]) != {"atol", "rtol"}):
            raise ValueError("zh-v1 KV sequence manifest identity is invalid")
        validate_compiled(seq_model, seq["compiled_files_sha256"], "zh-v1 KV sequence")
    elif seq_model.exists():
        raise ValueError("zh-v1 KV sequence model is bundled without its manifest")
    # The batched KV package of the same checkpoint (kvbatch-v3, merged):
    # the functions logits, scored and score in one package, up to 16 rows,
    # a prefix shared by every row; sentence correction and generation.
    v3_manifest = resources / "VimeLMManifestZhV1KVBatchV3.json"
    v3_model = resources / "TinyChineseV1KVBatchV3INT8.mlmodelc"
    v3 = json.loads(v3_manifest.read_text())["kv_batch_v3"] if v3_manifest.exists() else None
    if v3 is not None:
        outer = json.loads(v3_manifest.read_text())
        if (outer["format"] != "vime_ios_lm_zh_v1_kv_batch_v3"
                or outer["tokenizer_sha256"] != manifest["tokenizer_sha256"]
                or v3["resource"] != "TinyChineseV1KVBatchV3INT8.mlmodelc"
                or set(v3["functions"]) != {"logits", "scored", "score"}
                or v3["batch_range"] != [1, 16] or v3["compute_units"] != "CPU_ONLY"
                or not {"atol", "rtol"} <= set(v3["alignment_tolerance"])):
            raise ValueError("zh-v1 KV batch (kvbatch-v3) manifest identity is invalid")
        validate_compiled(v3_model, v3["compiled_files_sha256"], "zh-v1 KV batch (kvbatch-v3)")
    elif v3_model.exists():
        raise ValueError("zh-v1 KV batch (kvbatch-v3) model is bundled without its manifest")
    return (manifest["model_version"] + (" + KV" if kv is not None else "")
            + (" + KV batch (kvbatch-v2)" if v2 is not None else "")
            + (" + KV sequence" if seq is not None else "")
            + (" + KV batch (kvbatch-v3)" if v3 is not None else ""))


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
        fallback = validate(args.resources)
        chinese = validate_zh_v1(args.resources)
    except (OSError, ValueError, KeyError) as error:
        print(f"error: Vime model preflight failed: {error}. Install the matching payload with "
              "Scripts/install_v42_resources.py, Scripts/install_v21_resources.py or Scripts/install_zh_v1_resources.py.", file=sys.stderr)
        return 1
    print(f"Vime model preflight passed: runtime {runtime}; fallback {fallback}; Chinese {chinese}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
