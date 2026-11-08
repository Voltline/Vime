#!/usr/bin/env python3
"""Copy librime and its dependencies into Dependencies/VimeRime.

    Scripts/vendor_rime.py <librime checkout> <boost source root>

The librime checkout needs the yaml-cpp, leveldb, marisa-trie and opencc
submodules. Only library sources are copied, so Swift Package Manager can
compile everything under the target. Boost is header-only here: the script
asks clang which Boost headers librime includes and copies just those.
Generated config headers replace the CMake steps. UPSTREAM.md records the
versions.
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Dependencies/VimeRime"
TARGET = PACKAGE / "Sources/CRime"
VENDOR = TARGET / "vendor"
LICENSES = PACKAGE / "Licenses"


def copy(src: Path, dst: Path, keep):
    for path in sorted(src.rglob("*")):
        rel = path.relative_to(src)
        if path.is_file() and keep(rel):
            out = dst / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, out)


def is_test(rel: Path) -> bool:
    name = rel.name
    return bool(re.search(r"(_test|Test|_bench|_benchmark)\.(cc|cpp|h|hpp)$", name)) or "test" in rel.parts


def patch_learning_filter(memory: Path):
    """Lets Bridge.cc veto learning a commit (vime_rime_set_learning_filter),
    by its shown text and by the words underneath it."""
    text = memory.read_text()
    hook = ("void Memory::OnCommit(Context* ctx) {\n"
            "  if (!user_dict_ || user_dict_->readonly())\n    return;\n")
    assert text.count(hook) == 1, "librime changed Memory::OnCommit; update the patch"
    text = text.replace("namespace rime {\n",
                        'extern "C" bool (*vime_rime_learning_filter)(const char*);\n\nnamespace rime {\n', 1)
    text = text.replace(hook, hook +
                        "  // Vime: skip commits the app does not want learned. A filter such as\n"
                        "  // the simplifier changes the shown text, so the words underneath are\n"
                        "  // checked too.\n"
                        "  if (vime_rime_learning_filter) {\n"
                        "    string genuine;\n"
                        "    for (const Segment& seg : ctx->composition()) {\n"
                        "      if (auto cand = seg.GetSelectedCandidate())\n"
                        "        genuine += Candidate::GetGenuineCandidate(cand)->text();\n"
                        "      else\n"
                        "        genuine += ctx->input().substr(seg.start, seg.end - seg.start);\n"
                        "    }\n"
                        "    if (!vime_rime_learning_filter(ctx->GetCommitText().c_str()) ||\n"
                        "        !vime_rime_learning_filter(genuine.c_str()))\n"
                        "      return;\n"
                        "  }\n")
    memory.write_text(text)


def patch_corrections(translator: Path):
    """Three changes to how ScriptTranslation ranks spelling corrections.

    Vime's speller algebra (Scripts/generate_pinyin_algebra.py) marks typo
    spellings as corrections. The input is spelled exactly when a path of
    full syllables spells all of it, and counts as exact when that or a
    phrase spells it.

    1. Input spelled exactly looks words up, and makes its sentence, in a
       copy of the syllable graph whose correction edges carry a penalty no
       dictionary weight can make up for. Every exact reading then comes
       before every correction, however widely a dictionary's weights
       spread, and the sentence reads as it would without the algebra
       ("woyuo" stays 我与哦, not 我有).
    2. Without a phrase that spells the whole input exactly, Rime makes a
       sentence and always lists it first. For a typo ("zaho") that sentence
       is assembled from abbreviations (在好) while the corrected word (找)
       waits behind it. The poet never weighs a single word against the
       sentence, so do it here with the poet's own per-word penalty.
       Only for input that is not exact.
    3. For exact input, show at most two corrections, each for the whole
       input (upstream caps corrections at four, and only with the
       keyboard-distance corrector on).
    """
    edits = [
        ("#include <cmath>\n", "#include <cmath>\n#include <limits>\n"),
        ("  bool enable_correction_;\n};\n",
         "  bool enable_correction_;\n"
         "  // Vime: full syllables spell the whole input; lookups then use\n"
         "  // exact_graph_ (see Evaluate).\n"
         "  bool exact_spelling_ = false;\n"
         "  SyllableGraph exact_graph_;\n"
         "  // Vime: spelled exactly, or a phrase spells the whole input.\n"
         "  bool exact_input_ = false;\n};\n"),
        ("  size_t consumed = syllabifier_->BuildSyllableGraph(*dict->prism());\n"
         "  const auto& syllable_graph = syllabifier_->syllable_graph();\n",
         "  size_t consumed = syllabifier_->BuildSyllableGraph(*dict->prism());\n"
         "  // Vime: when full syllables spell the whole input, look up a copy of\n"
         "  // the graph whose corrections rank below anything a dictionary holds.\n"
         "  // Correction edges never set a vertex type.\n"
         "  const auto& full_graph = syllabifier_->syllable_graph();\n"
         "  auto end_vertex = full_graph.vertices.find(consumed);\n"
         "  exact_spelling_ = consumed == full_graph.input_length &&\n"
         "                    end_vertex != full_graph.vertices.end() &&\n"
         "                    end_vertex->second == kNormalSpelling;\n"
         "  if (exact_spelling_) {\n"
         "    const double kExactInputCorrectionPenalty = -1000.0;\n"
         "    exact_graph_.input_length = full_graph.input_length;\n"
         "    exact_graph_.interpreted_length = full_graph.interpreted_length;\n"
         "    exact_graph_.vertices = full_graph.vertices;\n"
         "    exact_graph_.edges = full_graph.edges;\n"
         "    exact_graph_.indices.clear();\n"
         "    for (auto& start : exact_graph_.edges)\n"
         "      for (auto& end : start.second)\n"
         "        for (auto& spelling : end.second)\n"
         "          if (spelling.second.is_correction)\n"
         "            spelling.second.credibility += kExactInputCorrectionPenalty;\n"
         "    for (const auto& start : exact_graph_.edges)  // Syllabifier::Transpose\n"
         "      for (const auto& end : boost::adaptors::reverse(start.second))\n"
         "        for (const auto& spelling : end.second)\n"
         "          exact_graph_.indices[start.first][spelling.first].push_back(\n"
         "              &spelling.second);\n"
         "  }\n"
         "  const auto& syllable_graph = exact_spelling_ ? exact_graph_ : full_graph;\n"),
        ("  // make sentences when there is no exact-matching phrase candidate\n",
         "  exact_input_ =\n"
         "      exact_spelling_ || has_reliable_phrase || has_reliable_user_phrase;\n"
         "  // make sentences when there is no exact-matching phrase candidate\n"),
        ("        sentences_.clear();\n    }\n  }\n\n  return !CheckEmpty();\n}\n",
         "        sentences_.clear();\n    }\n  }\n"
         "  // Vime: a corrected word that reads better than the sentence goes first.\n"
         "  if (!sentences_.empty() && !exact_input_) {\n"
         "    const double kWordPenalty = -13.815510557964274;  // Grammar::Evaluate\n"
         "    auto corrected_weight = [&](auto& result, auto& iter) {\n"
         "      return result && iter != result->rend() && iter->first == consumed &&\n"
         "                     !iter->second.exhausted() &&\n"
         "                     syllabifier_->IsCorrection(iter->second.Peek()->code,\n"
         "                                                consumed)\n"
         "                 ? iter->second.Peek()->weight + kWordPenalty\n"
         "                 : -std::numeric_limits<double>::infinity();\n"
         "    };\n"
         "    double best = (std::max)(corrected_weight(phrase_, phrase_iter_),\n"
         "                             corrected_weight(user_phrase_, user_phrase_iter_));\n"
         "    if (best > sentences_.front()->weight())\n"
         "      sentences_.clear();\n"
         "  }\n\n  return !CheckEmpty();\n}\n"),
        ("    if (enable_correction_) {\n      // populate next candidate",
         "    if (enable_correction_ || exact_input_) {\n      // populate next candidate"),
        ("  } while (enable_correction_ &&\n",
         "  } while ((enable_correction_ || exact_input_) &&\n"),
        ("           ++correction_count_ > max_corrections_);\n",
         "           // Vime: exact input shows two, each for the whole input\n"
         "           (exact_input_ ? candidate_->end() < end_of_input_ ||\n"
         "                               ++correction_count_ > 2\n"
         "                         : ++correction_count_ > max_corrections_));\n"),
        ("  const int kMaxSyllablesForUserPhraseQuery = 5;\n"
         "  const auto& syllable_graph = syllabifier_->syllable_graph();\n",
         "  const int kMaxSyllablesForUserPhraseQuery = 5;\n"
         "  // Vime: exact input makes its sentence from the graph it looked up.\n"
         "  const auto& syllable_graph =\n"
         "      exact_spelling_ ? exact_graph_ : syllabifier_->syllable_graph();\n"),
    ]
    text = translator.read_text()
    for old, new in edits:
        assert text.count(old) == 1, f"librime changed script_translator.cc; update the patch for {old!r}"
        text = text.replace(old, new)
    translator.write_text(text)


def patch_extra_code_credibility(dictionary: Path):
    """Counts spelling penalties past a phrase's third syllable.

    Tables index a phrase by its first three syllables and match the rest
    (the extra code) against the syllable graph, ignoring the credibility of
    those edges. A correction in the fourth syllable on ("tianqizhenhai" for
    天气真好) then costs nothing, and exact input would read as a typo.
    """
    edits = [
        ("  size_t end_pos;\n};\n",
         "  size_t end_pos;\n"
         "  double credibility = 0.0;  // Vime: of the matched edges\n};\n"),
        ("    if (!match.success)\n      continue;\n"
         "    if (match.end_pos > best_match.end_pos)\n      best_match = match;\n",
         "    if (!match.success)\n      continue;\n"
         "    match.credibility += props->credibility;\n"
         "    if (match.end_pos > best_match.end_pos ||\n"
         "        (match.end_pos == best_match.end_pos &&\n"
         "         match.credibility > best_match.credibility))\n"
         "      best_match = match;\n"),
        ("              {table, a.code(), a.entry(), matching_code_size, cr, q});\n",
         "              {table, a.code(), a.entry(), matching_code_size,\n"
         "               cr + match.credibility, q});\n"),
    ]
    text = dictionary.read_text()
    for old, new in edits:
        assert text.count(old) == 1, f"librime changed dictionary.cc; update the patch for {old!r}"
        text = text.replace(old, new)
    dictionary.write_text(text)


def patch_sentence_learning(translator: Path):
    """Learns a composed sentence as a whole only while it is short.

    Rime saves every committed sentence as one user phrase, which completion
    then offers for any input sharing its first letters. A long sentence
    composed from separate words would come back as a suggestion for an
    unrelated abbreviation. Its words are still learned one by one.
    """
    old = ("  UpdateElements(commit_entry);\n"
           "  user_dict_->UpdateEntry(commit_entry, 1);\n")
    new = ("  UpdateElements(commit_entry);\n"
           "  // Vime: skip long sentences made of several words.\n"
           "  if (commit_entry.elements.size() <= 1 ||\n"
           "      utf8::unchecked::distance(commit_entry.text.c_str(),\n"
           "                                commit_entry.text.c_str() +\n"
           "                                    commit_entry.text.length()) <= 8)\n"
           "    user_dict_->UpdateEntry(commit_entry, 1);\n")
    text = translator.read_text()
    assert text.count(old) == 1, "librime changed ScriptTranslator::Memorize; update the patch"
    if "#include <utf8.h>" not in text:
        text = text.replace("#include <rime/common.h>\n", "#include <utf8.h>\n#include <rime/common.h>\n", 1)
    translator.write_text(text.replace(old, new))


def head(repo: Path) -> str:
    return subprocess.run(["git", "-C", repo, "log", "-1", "--format=%H %cs"],
                          capture_output=True, text=True, check=True).stdout.strip()


def main():
    rime, boost = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    deps = rime / "deps"
    for folder in (VENDOR, LICENSES):
        if folder.exists():
            shutil.rmtree(folder)
    LICENSES.mkdir(parents=True)

    # librime: the C API and the core, dict, gear and lever modules.
    copy(rime / "src", VENDOR / "librime/src",
         lambda r: r.suffix in {".h", ".cc"} and r.name != "rime_api_stdbool.cc")
    (VENDOR / "librime/src/rime/build_config.h").write_text(
        "#ifndef RIME_BUILD_CONFIG_H_\n#define RIME_BUILD_CONFIG_H_\n"
        "// Logging off; data directories are always set at run time.\n"
        "#endif\n")
    patch_learning_filter(VENDOR / "librime/src/rime/gear/memory.cc")
    patch_corrections(VENDOR / "librime/src/rime/gear/script_translator.cc")
    patch_sentence_learning(VENDOR / "librime/src/rime/gear/script_translator.cc")
    patch_extra_code_credibility(VENDOR / "librime/src/rime/dict/dictionary.cc")
    # utfcpp, darts-clone and X11 key symbols ship in librime's include/.
    copy(rime / "include", VENDOR / "librime/include", lambda r: r.suffix == ".h")
    shutil.copy2(rime / "LICENSE", LICENSES / "librime.txt")

    copy(deps / "yaml-cpp/include", VENDOR / "yaml-cpp/include", lambda r: r.suffix == ".h")
    copy(deps / "yaml-cpp/src", VENDOR / "yaml-cpp/src", lambda r: r.suffix in {".h", ".cpp"})
    shutil.copy2(deps / "yaml-cpp/LICENSE", LICENSES / "yaml-cpp.txt")

    lv = deps / "leveldb"
    copy(lv / "include", VENDOR / "leveldb/include", lambda r: r.suffix == ".h")
    skip = {"leveldbutil.cc", "env_windows.cc", "testutil.cc", "testutil.h", "c.cc", "histogram.cc"}
    for part in ("db", "table", "util", "port"):
        copy(lv / part, VENDOR / "leveldb" / part,
             lambda r: r.suffix in {".h", ".cc"} and not is_test(r) and r.name not in skip
             and "windows" not in r.name)
    (VENDOR / "leveldb/port/port_config.h").write_text(
        "#ifndef STORAGE_LEVELDB_PORT_PORT_CONFIG_H_\n#define STORAGE_LEVELDB_PORT_PORT_CONFIG_H_\n"
        "#define HAVE_FDATASYNC 0\n#define HAVE_FULLFSYNC 1\n#define HAVE_O_CLOEXEC 1\n"
        "#define HAVE_CRC32C 0\n#define HAVE_SNAPPY 0\n#define HAVE_ZSTD 0\n#endif\n")
    shutil.copy2(lv / "LICENSE", LICENSES / "leveldb.txt")

    mt = deps / "marisa-trie"
    copy(mt / "include", VENDOR / "marisa/include", lambda r: r.suffix == ".h")
    copy(mt / "lib", VENDOR / "marisa/lib", lambda r: r.suffix in {".h", ".cc"})
    shutil.copy2(mt / "COPYING.md", LICENSES / "marisa.txt")

    oc = deps / "opencc"
    copy(oc / "src", VENDOR / "opencc/opencc",
         lambda r: len(r.parts) == 1 and r.suffix in {".hpp", ".cpp", ".h", ".inc"}
         and not is_test(r) and r.name != "py_opencc.cpp")
    copy(oc / "deps/rapidjson-1.1.0", VENDOR / "opencc/deps/rapidjson-1.1.0", lambda r: r.suffix == ".h")
    copy(oc / "src/plugin", VENDOR / "opencc/opencc/plugin", lambda r: r.suffix == ".h")
    # One darts-clone for both: OpenCC's copy adds validate() to librime's.
    shutil.copy2(oc / "deps/darts-clone-0.32h/include/darts.h", VENDOR / "librime/include/darts.h")
    shutil.copy2(oc / "deps/darts-clone-0.32h/COPYING.md", LICENSES / "darts-clone.txt")
    shutil.copy2(oc / "LICENSE", LICENSES / "opencc.txt")

    # Boost headers that librime reaches, from clang's dependency output.
    headers = set()
    sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
                         capture_output=True, text=True, check=True).stdout.strip()
    sources = sorted((VENDOR / "librime/src").rglob("*.cc"))
    for target, sysroot in (("arm64-apple-ios18.0-simulator", sdk), ("arm64-apple-macos14", None)):
        command = ["xcrun", "clang++", "-std=c++17", "-M", "-target", target, "-I", str(boost),
                   "-I", str(VENDOR / "librime/src"), "-I", str(VENDOR / "yaml-cpp/include"),
                   "-I", str(VENDOR / "leveldb/include"), "-I", str(VENDOR / "marisa/include"),
                   "-I", str(VENDOR / "librime/include"), "-I", str(VENDOR / "opencc"),
                   "-DBOOST_DLL_USE_STD_FS", "-DRIME_EXTRA_MODULES="]
        if sysroot:
            command += ["-isysroot", sysroot]
        for source in sources:
            out = subprocess.run(command + [str(source)], capture_output=True, text=True)
            if out.returncode:
                sys.exit(f"clang -M failed for {source}:\n{out.stderr}")
            for token in out.stdout.replace("\\\n", " ").split():
                path = Path(token)
                if path.is_absolute() and boost in path.parents:
                    headers.add(path.relative_to(boost))
    for rel in headers:
        out = VENDOR / "boost" / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(boost / rel, out)
    shutil.copy2(boost / "LICENSE_1_0.txt", LICENSES / "boost.txt")

    version = (boost / "boost/version.hpp").read_text()
    boost_version = re.search(r'BOOST_LIB_VERSION "([^"]+)"', version).group(1)
    # Sections after the generated table (e.g. "## Dictionary data") are kept.
    upstream = PACKAGE / "UPSTREAM.md"
    kept = ""
    if upstream.exists():
        old = upstream.read_text()
        start = old.find("\n## ")
        kept = old[start:] if start >= 0 else ""
    upstream.write_text(
        "# Upstream sources\n\n"
        "Copied by `Scripts/vendor_rime.py`; do not edit files under `Sources/CRime/vendor`.\n"
        "Four changes to upstream code are applied by the script: a learning filter\n"
        "hook in `librime/src/rime/gear/memory.cc`; in\n"
        "`librime/src/rime/gear/script_translator.cc`, how spelling corrections rank\n"
        "(`patch_corrections`) and which committed sentences are learned whole\n"
        "(`patch_sentence_learning`); and in `librime/src/rime/dict/dictionary.cc`,\n"
        "spelling penalties past a phrase's third syllable\n"
        "(`patch_extra_code_credibility`).\n\n"
        "| Project | Commit | License |\n| --- | --- | --- |\n"
        f"| [librime](https://github.com/rime/librime) | `{head(rime)}` | BSD-3-Clause |\n"
        f"| [yaml-cpp](https://github.com/jbeder/yaml-cpp) | `{head(deps / 'yaml-cpp')}` | MIT |\n"
        f"| [leveldb](https://github.com/google/leveldb) | `{head(deps / 'leveldb')}` | BSD-3-Clause |\n"
        f"| [marisa-trie](https://github.com/s-yata/marisa-trie) | `{head(deps / 'marisa-trie')}` | BSD-2-Clause or LGPL-2.1+ |\n"
        f"| [OpenCC](https://github.com/BYVoid/OpenCC) | `{head(oc)}` | Apache-2.0 |\n"
        f"| [Boost](https://www.boost.org) headers ({len(headers)} files) | {boost_version.replace('_', '.')} | BSL-1.0 |\n" + kept)
    count = sum(1 for _ in VENDOR.rglob("*") if _.suffix in {".cc", ".cpp"})
    print(f"{VENDOR.relative_to(ROOT)}: {count} sources, {len(headers)} Boost headers")


if __name__ == "__main__":
    main()
