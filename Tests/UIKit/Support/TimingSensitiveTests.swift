import XCTest

/// Tests that depend on wall-clock time run only locally: a latency or memory
/// budget, or a result that must arrive within a deadline such as the 60 ms
/// correction search. A shared CI runner can be several times slower than a
/// local simulator, so there these tests fail without a regression. The CI job
/// sets VIME_CI through TEST_RUNNER_VIME_CI.
func skipTimingSensitiveTestOnCI() throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["VIME_CI"] == "1",
        "Depends on wall-clock time; Scripts/test.sh runs it locally")
}
