#!/bin/bash
# Prebuilds the Chinese input data into Shared/Resources/RimeData.bundle.
#
#   Scripts/build_rime_data.sh [source cache dir] [--refresh-tatoeba]
#
# The schemas live in Dependencies/VimeRime/Schema, the OpenCC data for
# traditional characters in Dependencies/VimeRime/OpenCC. Scripts/build_rime_dicts.py
# generates the pinyin and English dictionaries from sources pinned to a commit
# or a SHA-256 and writes SOURCE.txt; Dependencies/VimeRime/UPSTREAM.md lists
# them with their licenses. The first run downloads about 150 MB into the cache
# (default /private/tmp/vime-rime-sources; set HTTPS_PROXY if needed), and later
# runs work offline from it. The same sources give the same dictionaries.
#
# Tatoeba keeps only its current weekly export, so the phrase counts taken from
# it are checked in as Scripts/rime_collocations.txt; --refresh-tatoeba
# downloads the current export and counts again, which changes the result.
#
# Only compiled files ship, so the keyboard never deploys anything itself.
# Check the result with
#
#   swift test --package-path Dependencies/VimeRime
set -euo pipefail
cd "$(dirname "$0")/.."
cache=${1:-/private/tmp/vime-rime-sources}
[ $# -gt 0 ] && shift
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp Dependencies/VimeRime/Schema/*.yaml "$work/"
python3 Scripts/build_rime_dicts.py "$work" --cache "$cache" ${1+"$@"}
swift build -c release --package-path Dependencies/VimeRime --product vime-rime-build >/dev/null
"$(swift build -c release --package-path Dependencies/VimeRime --show-bin-path)/vime-rime-build" "$work" "$work/build"
out=Shared/Resources/RimeData.bundle
rm -rf "$out"; mkdir -p "$out"
cp "$work"/build/{default.yaml,vime_pinyin.schema.yaml} "$out/"
cp "$work"/build/vime_pinyin.{prism,table,reverse}.bin "$work"/build/vime_english.{prism,table}.bin "$out/"
cp "$work/SOURCE.txt" "$out/"
# Simplified to traditional conversion for the traditional option, from the
# OpenCC data in Dependencies/VimeRime/OpenCC (same commit as the vendored code).
mkdir -p "$out/opencc"
cp Dependencies/VimeRime/OpenCC/s2t.json "$out/opencc/"
for dict in STPhrases STCharacters; do
  "$(swift build -c release --package-path Dependencies/VimeRime --show-bin-path)/vime-rime-build" \
    --opencc "Dependencies/VimeRime/OpenCC/$dict.txt" "$out/opencc/$dict.ocd2"
done
du -sh "$out"/*
