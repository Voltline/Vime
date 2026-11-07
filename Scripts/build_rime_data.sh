#!/bin/bash
# Prebuilds the Chinese input data into Shared/Resources/RimeData.bundle.
#
#   Scripts/build_rime_data.sh <rime-ice checkout>
#
# The schema lives in Dependencies/VimeRime/Schema; the dictionaries named in
# vime_pinyin.dict.yaml are copied from rime-ice. Only compiled files ship, so
# the keyboard never deploys anything itself.
set -euo pipefail
cd "$(dirname "$0")/.."
ice=$(cd "$1" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp Dependencies/VimeRime/Schema/*.yaml "$work/"
mkdir -p "$work/cn_dicts"
for dict in 8105 base others; do cp "$ice/cn_dicts/$dict.dict.yaml" "$work/cn_dicts/"; done
swift build -c release --package-path Dependencies/VimeRime --product vime-rime-build >/dev/null
"$(swift build -c release --package-path Dependencies/VimeRime --show-bin-path)/vime-rime-build" "$work" "$work/build"
out=Shared/Resources/RimeData.bundle
rm -rf "$out"; mkdir -p "$out"
cp "$work"/build/{default.yaml,vime_pinyin.schema.yaml,vime_pinyin.prism.bin,vime_pinyin.table.bin,vime_pinyin.reverse.bin} "$out/"
printf 'rime-ice %s\n' "$(git -C "$ice" log -1 --format='%H %cs')" > "$out/SOURCE.txt"
du -sh "$out"/*
