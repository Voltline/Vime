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
    """Lets Bridge.cc veto learning a commit (vime_rime_set_learning_filter)."""
    text = memory.read_text()
    hook = ("void Memory::OnCommit(Context* ctx) {\n"
            "  if (!user_dict_ || user_dict_->readonly())\n    return;\n")
    assert text.count(hook) == 1, "librime changed Memory::OnCommit; update the patch"
    text = text.replace("namespace rime {\n",
                        'extern "C" bool (*vime_rime_learning_filter)(const char*);\n\nnamespace rime {\n', 1)
    text = text.replace(hook, hook +
                        "  // Vime: skip commits the app does not want learned.\n"
                        "  if (vime_rime_learning_filter &&\n"
                        "      !vime_rime_learning_filter(ctx->GetCommitText().c_str()))\n"
                        "    return;\n")
    memory.write_text(text)


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
    (PACKAGE / "UPSTREAM.md").write_text(
        "# Upstream sources\n\n"
        "Copied by `Scripts/vendor_rime.py`; do not edit files under `Sources/CRime/vendor`.\n"
        "The one change to upstream code is a learning filter hook in\n"
        "`librime/src/rime/gear/memory.cc`, applied by the script.\n\n"
        "| Project | Commit | License |\n| --- | --- | --- |\n"
        f"| [librime](https://github.com/rime/librime) | `{head(rime)}` | BSD-3-Clause |\n"
        f"| [yaml-cpp](https://github.com/jbeder/yaml-cpp) | `{head(deps / 'yaml-cpp')}` | MIT |\n"
        f"| [leveldb](https://github.com/google/leveldb) | `{head(deps / 'leveldb')}` | BSD-3-Clause |\n"
        f"| [marisa-trie](https://github.com/s-yata/marisa-trie) | `{head(deps / 'marisa-trie')}` | BSD-2-Clause or LGPL-2.1+ |\n"
        f"| [OpenCC](https://github.com/BYVoid/OpenCC) | `{head(oc)}` | Apache-2.0 |\n"
        f"| [Boost](https://www.boost.org) headers ({len(headers)} files) | {boost_version.replace('_', '.')} | BSL-1.0 |\n")
    count = sum(1 for _ in VENDOR.rglob("*") if _.suffix in {".cc", ".cpp"})
    print(f"{VENDOR.relative_to(ROOT)}: {count} sources, {len(headers)} Boost headers")


if __name__ == "__main__":
    main()
