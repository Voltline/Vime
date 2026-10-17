#!/bin/bash
# Reproducible local verification. No commit, push, install-payload or upload.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-all}
case "$mode" in focused|full|extension|all) ;; *) echo "Usage: $0 [focused|full|extension|all]" >&2; exit 2 ;; esac
: "${VIME_TEST_DESTINATION:?Set an explicit xcodebuild destination (prefer simulator UDID)}"
: "${VIME_PACKAGE_CACHE:?Set the directory containing the resolved SwiftPM checkouts}"
output=${VIME_REVIEW_OUTPUT:-$(mktemp -d /private/tmp/VimeReview.XXXXXX)}
mkdir -p "$output"
# Never overwrite evidence from a previous run.
if [[ -e "$output/manifest-before.json" ]]; then echo "Output already contains a run: $output" >&2; exit 2; fi
output=$(cd "$output" && pwd)
derived=${VIME_DERIVED_DATA:-$output/DerivedData}
optimization=${VIME_SWIFT_OPTIMIZATION:--Onone}
case "$optimization" in -Onone|-O) ;; *) echo "VIME_SWIFT_OPTIMIZATION must be -Onone or -O" >&2; exit 2 ;; esac
manifest() {
  python3 - "$1" <<'PY'
import hashlib, json, pathlib, subprocess, sys
paths = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z']).decode().split('\0')
prefixes = ('Shared/', 'Keyboard/', 'Vime/', 'Tests/', 'Scripts/', 'Configuration/', 'Dependencies/')
files = {}
for name in sorted(set(paths)):
    p = pathlib.Path(name)
    project = name == 'Vime.xcodeproj/project.pbxproj' or name.startswith('Vime.xcodeproj/xcshareddata/')
    if p.is_file() and (project or name.startswith(prefixes)):
        files[name] = hashlib.sha256(p.read_bytes()).hexdigest()
head = subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip()
pathlib.Path(sys.argv[1]).write_text(json.dumps({'head': head, 'files': files}, indent=2, sort_keys=True) + '\n')
PY
}
manifest "$output/manifest-before.json"
finish() {
  local status=$?
  trap - EXIT
  set +e
  manifest "$output/manifest-after.json"
  if [[ $? != 0 ]] || ! cmp -s "$output/manifest-before.json" "$output/manifest-after.json"; then
    echo "Source changed or final manifest failed; evidence does not validate the current tree" >&2
    status=1
  fi
  git diff --check || status=1
  printf 'Review finished with exit %s; evidence: %s\n' "$status" "$output"
  exit "$status"
}
# Preserve the failed run's ending snapshot too; never erase a nonzero result.
trap finish EXIT
git status --short > "$output/git-status-before.txt"
xcodebuild -version > "$output/xcode-version.txt"
python3 Scripts/validate_model_resources.py > "$output/model-preflight.txt"
run_tests() {
  local label=$1 scheme=$2
  shift 2
  local cmd=(xcodebuild test -project Vime.xcodeproj -scheme "$scheme"
    -destination "$VIME_TEST_DESTINATION" -derivedDataPath "$derived"
    -clonedSourcePackagesDirPath "$VIME_PACKAGE_CACHE" -disableAutomaticPackageResolution
    -parallel-testing-enabled NO -collect-test-diagnostics never
    -resultBundlePath "$output/$label.xcresult" "SWIFT_OPTIMIZATION_LEVEL=$optimization" "$@")
  printf '%q ' "${cmd[@]}" > "$output/$label-command.txt"
  printf '\n' >> "$output/$label-command.txt"
  local status=0
  "${cmd[@]}" > "$output/$label.log" 2>&1 || status=$?
  echo "$status" > "$output/$label-exit-code.txt"
  if [[ -d "$output/$label.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$output/$label.xcresult" --format json > "$output/$label-summary.json"
    xcrun xcresulttool get test-results tests --path "$output/$label.xcresult" --format json > "$output/$label-tests.json"
  fi
  echo "$label: exit $status; evidence $output"
  if [[ "$status" != 0 ]]; then return "$status"; fi
  python3 - "$output/$label-summary.json" "$output/$label-tests.json" "$label" "$@" <<'PY'
import json, pathlib, re, sys
result = json.load(open(sys.argv[1]))
assert result['passedTests'] > 0, 'No passing executed tests'
assert result['failedTests'] == 0 and result['expectedFailures'] == 0, result
assert result['result'] == 'Passed', result
leaves = []
def visit(node):
    if isinstance(node, dict):
        if node.get('nodeType') == 'Test Case': leaves.append(node)
        for value in node.values(): visit(value)
    elif isinstance(node, list):
        for value in node: visit(value)
visit(json.load(open(sys.argv[2])))
optional = {'VimeLanguageModelBenchmarkTests/testDeviceLatencyAndMemory()',
            'KeyboardExtensionSoakTests/testContinuousInstalledExtensionSoak()',
            'VimeLanguageModelBenchmarkTests/testOtherComputeUnit()',
            'VimeLanguageModelMemoryTests/testEmojiScrollPreparationPerformance()',
            'VimeLanguageModelMemoryTests/testEmojiBrowsingMemoryStaysBounded()',
            'VimeLanguageModelMemoryTests/testStepAttributionProfile()',
            'VimeLanguageModelMemoryTests/testProcessMemoryProfile()'}
unexpected_skips = [n['nodeIdentifier'] for n in leaves if n['result'] == 'Skipped' and n['nodeIdentifier'] not in optional]
assert not unexpected_skips, ('Mandatory tests skipped', unexpected_skips)
if sys.argv[3] in {'full', 'focused', 'extension'}:
    expected = set()
    selectors = {arg.split(':', 1)[1].split('/', 1)[1] for arg in sys.argv[4:] if arg.startswith('-only-testing:')}
    folder = 'Tests/ExtensionUI' if sys.argv[3] == 'extension' else 'Tests/UIKit'
    for path in pathlib.Path(folder).rglob('*.swift'):
        source = path.read_text()
        case = re.search(r'class\s+(\w+)\s*:\s*XCTestCase', source)
        if case:
            for method in re.findall(r'func\s+(test\w+)\s*\(', source):
                identifier = case[1] + '/' + method
                if not selectors or case[1] in selectors or identifier in selectors:
                    expected.add(identifier + '()')
    seen = {n['nodeIdentifier'] for n in leaves}
    assert expected == seen, ('Test discovery mismatch', sorted(expected - seen), sorted(seen - expected))
print('passed:', result['passedTests'], 'skipped:', result['skippedTests'], '(skips are NOT validation)')
PY
}
case "$mode" in
  focused) run_tests focused Vime \
    -only-testing:VimeKeyboardTests/VimeAuditRegressionTests \
    -only-testing:VimeKeyboardTests/KeyboardReviewBoundaryTests \
    -only-testing:VimeKeyboardTests/CandidatePreferenceTransactionTests \
    -only-testing:VimeKeyboardTests/KeyboardCorrectionTests \
    -only-testing:VimeKeyboardTests/KeyboardIntegrationTests \
    -only-testing:VimeKeyboardTests/VimeLanguageModelTests ;;
  full|all) run_tests full Vime ;;
esac
if [[ "$mode" == extension || "$mode" == all ]]; then run_tests extension VimeExtensionTests; fi
