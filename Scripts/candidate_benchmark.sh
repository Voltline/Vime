#!/bin/bash
# Candidate quality benchmark: types each reading as romaji through the real
# engine and reports top-1/top-3, split clauses and prediction per ranking mode.
#
#   Scripts/candidate_benchmark.sh               everyday set, plus the AJIMEE-Bench
#                                                track when it has been built
#   Scripts/candidate_benchmark.sh --ajimee      build the AJIMEE-Bench track first
#   Scripts/candidate_benchmark.sh [--] [xcodebuild arguments]
#
# The report is written to Artifacts/CandidateBenchmark/report/ (ignored by
# git). VIME_SIMULATOR and VIME_DERIVED_DATA work as in test.sh;
# VIME_CANDIDATE_BENCHMARK_LIMIT caps the cases per track for a quick look.
set -euo pipefail
cd "$(dirname "$0")/.."

folder=$PWD/Artifacts/CandidateBenchmark
ajimee=$folder/ajimee.json
if [ "${1:-}" = --ajimee ]; then python3 Scripts/build_candidate_benchmark_corpus.py --output "$ajimee"; shift; fi
[ "${1:-}" = -- ] && shift

export TEST_RUNNER_VIME_CANDIDATE_BENCHMARK=1
export TEST_RUNNER_VIME_CANDIDATE_BENCHMARK_REPORT=$folder/report
export TEST_RUNNER_VIME_CANDIDATE_BENCHMARK_CORPUS=""
[ -f "$ajimee" ] && TEST_RUNNER_VIME_CANDIDATE_BENCHMARK_CORPUS=$ajimee
[ -n "${VIME_CANDIDATE_BENCHMARK_LIMIT:-}" ] && export TEST_RUNNER_VIME_CANDIDATE_BENCHMARK_LIMIT=$VIME_CANDIDATE_BENCHMARK_LIMIT
rm -f "$folder/report/candidate-benchmark.md"

status=0
Scripts/test.sh KeyboardCandidateBenchmarkTests/testCandidateQualityBenchmark -- "$@" || status=$?
if [ -f "$folder/report/candidate-benchmark.md" ]; then
    # The summary table and failure reasons; the per-case list stays in the file.
    sed -n '1,/^## 首位错误（/p' "$folder/report/candidate-benchmark.md" | sed '$d'
    echo "Report: $folder/report/candidate-benchmark.md"
fi
exit "$status"
