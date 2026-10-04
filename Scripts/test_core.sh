#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Core tests now exercise the real SwiftPM conversion engine in the simulator.
xcodebuild test -project Vime.xcodeproj -scheme Vime \
  -destination 'platform=iOS Simulator,name=Vime Keyboard QA' \
  -parallel-testing-enabled NO -only-testing:VimeKeyboardTests/KeyboardCoreTests "$@"
