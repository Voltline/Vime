import XCTest

@MainActor
final class VimeExtensionAuditTests: XCTestCase {
    #if DEBUG || VIME_EXTENSION_AUDIT
    func testLongAuditArgumentsAreExplicitAndBounded() {
        let configuration = VimeExtensionAudit.Configuration.from(arguments: ["Vime",
            "--v21-extension-audit-duration-seconds", "1500",
            "--v21-extension-audit-sample-ms", "1000",
            "--v21-extension-audit-write-ms=15000",
            "--v21-extension-audit-run-id", "simulator-soak-20261013"])
        XCTAssertEqual(configuration.durationSeconds, 1_500)
        XCTAssertEqual(configuration.sampleMilliseconds, 1_000)
        XCTAssertEqual(configuration.writeMilliseconds, 15_000)
        XCTAssertEqual(configuration.runID, "simulator-soak-20261013")
        XCTAssertEqual(VimeExtensionAudit.Configuration(sentinel: configuration.dictionary), configuration)

        let untrusted = VimeExtensionAudit.Configuration(sentinel: ["duration_seconds": Int.max,
            "sample_ms": -1, "write_ms": Int.max, "run_id": "../../input text"])
        XCTAssertEqual(untrusted.durationSeconds, 3_600)
        XCTAssertEqual(untrusted.sampleMilliseconds, 100)
        XCTAssertEqual(untrusted.writeMilliseconds, 60_000)
        XCTAssertNil(untrusted.runID)
        XCTAssertEqual(VimeExtensionAudit.Configuration(sentinel: ["enabled": true]),
                       VimeExtensionAudit.Configuration(), "The previous bool-only sentinel keeps short-run defaults")
    }
    #endif

    func testTimingWindowsRetainCumulativeCountsWithoutExpandingPercentileBuffers() {
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false, reset: true) }
        for _ in 0..<300 {
            KeyboardPerformance.record(.baseConversion, since: ProcessInfo.processInfo.systemUptime - 0.001)
        }
        let first = KeyboardPerformance.takeWindowReport()["baseConversion"]
        XCTAssertEqual(first?["windowCount"], 300)
        XCTAssertEqual(first?["totalCount"], 300)
        XCTAssertEqual(first?["percentileSampleCount"], 256)
        XCTAssertGreaterThanOrEqual(first?["meanMs"] ?? 0, 0.9)
        XCTAssertTrue(KeyboardPerformance.takeWindowReport().isEmpty, "A drained window must not repeat earlier events")

        for _ in 0..<20 {
            KeyboardPerformance.record(.baseConversion, since: ProcessInfo.processInfo.systemUptime - 0.002)
        }
        let second = KeyboardPerformance.takeWindowReport()["baseConversion"]
        XCTAssertEqual(second?["windowCount"], 20)
        XCTAssertEqual(second?["totalCount"], 320)
        XCTAssertEqual(second?["percentileSampleCount"], 20)
        XCTAssertGreaterThanOrEqual(second?["meanMs"] ?? 0, 1.9)
        XCTAssertEqual(KeyboardPerformance.report()["baseConversion"]?["count"], 256)
        XCTAssertEqual(KeyboardPerformance.report()["baseConversion"]?["totalCount"], 320)

        KeyboardPerformance.configure(enabled: false)
        KeyboardPerformance.record(.baseConversion, since: ProcessInfo.processInfo.systemUptime - 0.001)
        XCTAssertTrue(KeyboardPerformance.takeWindowReport().isEmpty, "Disabled measurement must add no events")
        XCTAssertEqual(KeyboardPerformance.report()["baseConversion"]?["totalCount"], 320)
    }
}
