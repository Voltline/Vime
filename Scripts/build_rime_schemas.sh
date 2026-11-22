#!/bin/bash
# Rebuilds the schemas in Shared/Resources/RimeData.bundle on its compiled
# dictionaries, without downloading the dictionary sources:
#
#   Scripts/build_rime_schemas.sh [schema ...]
#
# Copies only the schemas named (default: vime_t9) and default.yaml, so the
# others keep their files. For a change to the spelling rules only. A change to the words needs Scripts/build_rime_data.sh, which
# also builds everything this does.
set -euo pipefail
cd "$(dirname "$0")/.."
out=Shared/Resources/RimeData.bundle
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp Dependencies/VimeRime/Schema/*.yaml "$work/"
python3 Scripts/generate_pinyin_algebra.py --variants "$work"
python3 - "$work" <<'PY'
import pathlib, sys
work = pathlib.Path(sys.argv[1])
names = sorted(p.name.removesuffix(".schema.yaml") for p in work.glob("vime_pinyin_fuzzy*.schema.yaml"))
names += ["vime_t9", "vime_shuangpin_flypy", "vime_shuangpin_ziranma"]
default = work / "default.yaml"
anchor = "  - schema: vime_pinyin\n"
default.write_text(default.read_text().replace(anchor, anchor + "".join(f"  - schema: {n}\n" for n in names), 1))
PY
# Rime takes the compiled dictionaries from build/ when it has no source for them.
mkdir -p "$work/build"
cp "$out"/vime_pinyin.{table,reverse}.bin "$out"/vime_english.{prism,table}.bin "$work/build/"
swift build -c release --package-path Dependencies/VimeRime --product vime-rime-build >/dev/null
# The English dictionary has no source here, so Rime reports a failure after
# building the pinyin schemas; the check below is what counts.
"$(swift build -c release --package-path Dependencies/VimeRime --show-bin-path)/vime-rime-build" "$work" "$work/staging" || true
for name in ${@:-vime_t9}; do
  test -s "$work/staging/$name.prism.bin" || { echo "error: $name.prism.bin was not built" >&2; exit 1; }
  cp "$work/staging/$name.schema.yaml" "$work/staging/$name.prism.bin" "$out/"
done
cp "$work/staging/default.yaml" "$out/"
for name in ${@:-vime_t9}; do du -sh "$out/$name.prism.bin"; done
