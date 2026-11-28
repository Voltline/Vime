import XCTest

/// Corpus-wide guards and model parity checks that take ten seconds or more
/// each. Together they are about two thirds of the suite's time, so the
/// everyday `Scripts/test.sh` run leaves them out. They run when the run
/// names their class or method, with `Scripts/test.sh --full`, and in
/// `Scripts/verify_review.sh`; all of these set VIME_FULL_TESTS through
/// TEST_RUNNER_VIME_FULL_TESTS.
func skipSlowTestUnlessFullRun() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_FULL_TESTS"] == "1",
        "Slow test; runs with Scripts/test.sh --full or when named")
}
