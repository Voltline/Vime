#!/bin/bash
# Release build installed on an iPhone, for trying changes on the device.
#
#   Scripts/install_device.sh            optimized build, as shipped
#   Scripts/install_device.sh --fast     fast build: only for looks and behavior
#   Scripts/install_device.sh [--fast] -- ARGS   arguments after -- go to xcodebuild
#
# The fast build compiles the app and the keyboard one file at a time instead
# of as a whole module. After a one-line change it rebuilds in about 15 s
# instead of about 90 s, but code that calls across files is not optimized
# as well, so the keyboard may run slower. Use it only to look at layout,
# animation, and interaction. Judge speed, memory, or anything that "feels
# slow" only on the optimized build. Packages (azooKey and others) are always
# fully optimized. Shipped builds (archive, Xcode Cloud) are never fast builds.
#
# VIME_DEVICE names the iPhone by name or UDID; without it, the one connected
# iPhone is used. Each mode keeps its own build folder, so switching modes
# does not rebuild from scratch. VIME_DERIVED_DATA overrides the folder.
# Compilation caching is shared with Scripts/test.sh (see there).
set -euo pipefail
cd "$(dirname "$0")/.."

mode=wholemodule
if [ "${1:-}" = --fast ]; then mode=singlefile; shift; fi
if [ "${1:-}" = -- ]; then shift; fi
derived=${VIME_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Vime-device-$mode}

device=${VIME_DEVICE:-}
if [ -z "$device" ]; then
    list=$(mktemp)
    trap 'rm -f "$list"' EXIT
    xcrun devicectl list devices --json-output "$list" > /dev/null
    device=$(python3 - "$list" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))['result']['devices']
# devicectl also lists booted simulators; only real iPhones can take this build.
phones = [d for d in devices
          if d['hardwareProperties'].get('deviceType') == 'iPhone'
          and d['hardwareProperties'].get('reality') == 'physical']
connected = [d for d in phones if d['connectionProperties'].get('tunnelState') == 'connected']
if len(connected) == 1:
    print(connected[0]['hardwareProperties']['udid'])
else:
    names = ', '.join(d['deviceProperties'].get('name', '?') for d in phones) or 'none'
    sys.stderr.write(f'No single connected iPhone. Paired: {names}. Set VIME_DEVICE to a name or UDID.\n')
PY
)
    [ -n "$device" ] || exit 2
fi

if [ "$mode" = singlefile ]; then
    echo "Fast build: for looks and behavior only; do not judge speed on it." >&2
fi
xcodebuild build -project Vime.xcodeproj -scheme Vime -configuration Release \
    -destination generic/platform=iOS -derivedDataPath "$derived" \
    -allowProvisioningUpdates -quiet \
    VIME_SWIFT_COMPILATION_MODE=$mode \
    COMPILATION_CACHE_ENABLE_CACHING=YES CLANG_ENABLE_COMPILE_CACHE=YES SWIFT_ENABLE_COMPILE_CACHE=YES \
    "COMPILATION_CACHE_CAS_PATH=$HOME/Library/Developer/Xcode/DerivedData/CompilationCache.noindex" \
    "$@"
xcrun devicectl device install app --device "$device" \
    "$derived/Build/Products/Release-iphoneos/Vime.app"
if [ "$mode" = singlefile ]; then
    echo "Installed a FAST build. Reinstall without --fast before measuring speed." >&2
fi
