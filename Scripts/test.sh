#!/bin/bash
# Day-to-day test runs on one simulator, reusing one build folder.
#
#   Scripts/test.sh                          all unit tests except the slow ones
#   Scripts/test.sh --full                   all unit tests, slow ones included
#   Scripts/test.sh KeyboardFeatureTests KeyboardCoreTests/testRomajiAndVisibleKanaDeletion
#                                            only these classes or methods
#   Scripts/test.sh --failed                 only what failed in the last run
#   Scripts/test.sh --extension [names]      extension UI tests (VimeExtensionUITests)
#   Scripts/test.sh [names] -- -retry-tests-on-failure -test-iterations 2
#                                            arguments after -- go to xcodebuild as is
#
# Slow tests (corpus guards, model parity; see Tests/UIKit/Support/SlowTests.swift)
# also run whenever classes or methods are named.
#
# VIME_SIMULATOR picks the simulator by name or UDID. Otherwise, when simlease
# is installed (outside CI), the run leases a simulator no other agent holds
# and gives it back when it ends; SIMLEASE_AGENT names the holder (default
# test.sh). Without simlease: the booted one, else the first available
# iPhone. VIME_DERIVED_DATA overrides the build folder; while another run
# holds it, this one builds in the same path with -2, -3… appended, so runs
# on separate simulators never share a build or its results. For evidence
# kept with a review, use verify_review.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

scheme=Vime; target=VimeKeyboardTests
if [ "${1:-}" = --extension ]; then scheme=VimeExtensionTests; target=VimeExtensionUITests; shift; fi
full=0
if [ "${1:-}" = --full ]; then full=1; shift; fi
base=${VIME_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Vime-tests}
lease=""; lock=""
cleanup() {
    if [ -n "$lock" ]; then rm -rf "$lock"; fi
    if [ -n "$lease" ]; then simlease release "$lease" > /dev/null 2>&1 || true; fi
}
trap cleanup EXIT
# One run per build folder: a folder another live run holds is skipped for
# the next numbered one. A lock left by a run that died is taken over.
slot=1; derived=$base
mkdir -p "$(dirname "$base")"
while :; do
    if mkdir "$derived.test-lock" 2> /dev/null; then
        lock=$derived.test-lock; echo $$ > "$lock/pid"; break
    fi
    owner=$(cat "$derived.test-lock/pid" 2> /dev/null || true)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2> /dev/null; then rm -rf "$derived.test-lock"; continue; fi
    # No pid yet: the owner is still writing it, unless the lock is stale.
    if [ -z "$owner" ] && [ -z "$(find "$derived.test-lock" -maxdepth 0 -mmin -1 2> /dev/null)" ]; then
        rm -rf "$derived.test-lock"; continue
    fi
    slot=$((slot + 1)); derived=$base-$slot
done
if [ "$slot" != 1 ]; then echo "Another run holds $base; building in $derived" >&2; fi
results=$derived/Results
mkdir -p "$results" "$base/Results"
# What failed last, whichever folder the run used, for --failed.
failed_list=$base/Results/failed-$target.txt

simulator=${VIME_SIMULATOR:-}
if [ -z "$simulator" ] && [ -z "${CI:-}" ] && command -v simlease > /dev/null; then
    # Leased for as long as this script runs, so agents never share a simulator.
    lease_status=0
    simulator=$(simlease acquire --agent "${SIMLEASE_AGENT:-test.sh}" --pid $$ --ttl 4h) || lease_status=$?
    if [ "$lease_status" != 0 ] || [ -z "$simulator" ]; then
        echo "simlease could not lease a simulator (exit $lease_status); see simlease list, or set VIME_SIMULATOR" >&2
        exit 2
    fi
    lease=$simulator
fi
if [ -z "$simulator" ]; then
    simulator=$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime]
print(devices[0]["udid"] if devices else "")')
fi
if [ -z "$simulator" ]; then
    simulator=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime if d["name"].startswith("iPhone")]
print(devices[-1]["udid"] if devices else "")')
fi
[ -n "$simulator" ] || { echo "No iPhone simulator found; set VIME_SIMULATOR" >&2; exit 2; }
if [[ $simulator =~ ^[0-9A-F-]{36}$ ]]; then destination="platform=iOS Simulator,id=$simulator"
else destination="platform=iOS Simulator,name=$simulator"; fi

selectors=()
if [ "${1:-}" = --failed ]; then
    [ -s "$failed_list" ] || { echo "No failures recorded for $target" >&2; exit 0; }
    while read -r test; do selectors+=("-only-testing:$test"); done < "$failed_list"
    shift
fi
while [ $# -gt 0 ]; do
    if [ "$1" = -- ]; then shift; selectors+=("$@"); break; fi
    selectors+=("-only-testing:$target/$1"); shift
done

[ ${#selectors[@]} -gt 0 ] && full=1
if [ "$full" = 1 ]; then export TEST_RUNNER_VIME_FULL_TESTS=1; fi

bundle=$results/$target.xcresult
rm -rf "$bundle"
# Compilation caching, shared by every checkout and worktree on this Mac: a
# fresh build folder reuses the C++ objects (librime and its dependencies)
# instead of compiling them again. Settings in the project do not reach
# SwiftPM packages, so they are passed here.
cache=(COMPILATION_CACHE_ENABLE_CACHING=YES CLANG_ENABLE_COMPILE_CACHE=YES SWIFT_ENABLE_COMPILE_CACHE=YES
    "COMPILATION_CACHE_CAS_PATH=$HOME/Library/Developer/Xcode/DerivedData/CompilationCache.noindex")
run_tests() {
    xcodebuild test -project Vime.xcodeproj -scheme "$scheme" -destination "$destination" \
        -derivedDataPath "$derived" -parallel-testing-enabled NO -collect-test-diagnostics never \
        -resultBundlePath "$bundle" "${cache[@]}" ${selectors[@]+"${selectors[@]}"}
}
status=0
if [ -n "${CI:-}" ]; then
    # CI also prints progress, so a run that times out shows where it stopped.
    set +e +o pipefail
    run_tests 2>&1 | tee "$results/$target.log" | grep --line-buffered -E \
        "^Test Case .*(passed|failed)|Testing started|error:|\*\* .* \*\*"
    status=${PIPESTATUS[0]}
    set -e -o pipefail
else
    run_tests > "$results/$target.log" 2>&1 || status=$?
fi

# Summarize from the result bundle; the log keeps the full output.
if [ -d "$bundle" ]; then
    xcrun xcresulttool get test-results tests --path "$bundle" --format json | python3 -c '
import json, sys
target, failed_path = sys.argv[1:]
counts, failed = {}, []
def visit(node, bundle=None):
    if node.get("nodeType") == "Unit test bundle" or node.get("nodeType") == "UI test bundle":
        bundle = node["name"]
    if node.get("nodeType") == "Test Case":
        counts[node["result"]] = counts.get(node["result"], 0) + 1
        if node["result"] == "Failed":
            name = node["nodeIdentifier"].removesuffix("()")
            failed.append(f"{bundle or target}/{name}")
    for child in node.get("children", []):
        visit(child, bundle)
for node in json.load(sys.stdin)["testNodes"]:
    visit(node)
open(failed_path, "w").write("".join(name + "\n" for name in failed))
print(", ".join(f"{count} {result.lower()}" for result, count in sorted(counts.items())) or "no tests ran")
for name in failed:
    print("  failed:", name)
' "$target" "$failed_list"
fi
# KeyboardBudgetTests prints one line per latency or memory budget.
grep -h "^VIME_BUDGET " "$results/$target.log" | sed 's/^VIME_BUDGET /  budget: /' || true
if [ "$status" != 0 ]; then
    grep -E "error:|\*\* (TEST|BUILD) .*FAILED" "$results/$target.log" | head -20 >&2
    echo "Log: $results/$target.log" >&2
fi
exit "$status"
