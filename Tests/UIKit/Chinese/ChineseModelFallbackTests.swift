import XCTest
@testable import Vime

final class ChineseModelFallbackTests: XCTestCase {
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suite = "com.Voltline.Vime.tests.fallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testLoadErrorFallbackAndManualV2Recovery() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let fallback = ChineseModelFallback(defaultsProvider: { defaults }, appVersionProvider: { "1.0(1)" })
        XCTAssertFalse(fallback.isFallenBackToV1)
        XCTAssertNil(fallback.fallbackReason)

        // Simulate v2 load / runtime error.
        XCTAssertTrue(fallback.beginV2Load())
        fallback.recordRuntimeFailure(reason: "load_error: simulated")
        XCTAssertTrue(fallback.isFallenBackToV1)
        XCTAssertEqual(fallback.fallbackReason, "load_error: simulated")
        XCTAssertFalse(fallback.beginV2Load(), "should stay on v1 after runtime failure")

        // Manual switch back to v2 clears fallback.
        fallback.resetForManualV2Selection()
        XCTAssertFalse(fallback.isFallenBackToV1)
        XCTAssertNil(fallback.fallbackReason)
        XCTAssertTrue(fallback.beginV2Load())
        fallback.finishV2LoadSuccess()
    }

    func testConsecutiveCrashLoopFallbackAndAppUpdateReset() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var appVersion = "1.0(10)"
        let fallback = ChineseModelFallback(defaultsProvider: { defaults }, appVersionProvider: { appVersion })

        // Attempt 1: starts loading v2, crashes before finishV2LoadSuccess().
        XCTAssertTrue(fallback.beginV2Load())
        XCTAssertFalse(fallback.isFallenBackToV1)

        // Attempt 2: detects 1st unfinished load, still allows one retry, crashes again.
        XCTAssertTrue(fallback.beginV2Load())
        XCTAssertFalse(fallback.isFallenBackToV1)

        // Attempt 3: detects 2nd consecutive crash -> falls back to v1.
        XCTAssertFalse(fallback.beginV2Load())
        XCTAssertTrue(fallback.isFallenBackToV1)
        XCTAssertEqual(fallback.fallbackReason, "crash_loop_2")

        // App update resets fallback so the new version retries v2.
        appVersion = "1.0(11)"
        XCTAssertFalse(fallback.isFallenBackToV1)
        XCTAssertTrue(fallback.beginV2Load())
        fallback.finishV2LoadSuccess()
        XCTAssertFalse(fallback.isFallenBackToV1)
    }

    func testRollingLatencyP95FallbackAndManualRecovery() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let fallback = ChineseModelFallback(defaultsProvider: { defaults }, appVersionProvider: { "1.0(1)" })

        // 48 fast keys + 2 slow keys -> p95 (index 47) is 10 ms <= 60 ms -> no fallback.
        for _ in 0..<48 {
            XCTAssertFalse(fallback.recordKeyLatency(milliseconds: 10.0))
        }
        for _ in 0..<2 {
            XCTAssertFalse(fallback.recordKeyLatency(milliseconds: 80.0))
        }
        XCTAssertFalse(fallback.isFallenBackToV1)

        // Push 1 more slow key (total 3 slow keys in last 50 -> 6% > 5%, p95 at index 47 is 80 ms > 60 ms).
        XCTAssertTrue(fallback.recordKeyLatency(milliseconds: 80.0))
        XCTAssertTrue(fallback.isFallenBackToV1)
        XCTAssertEqual(fallback.fallbackReason, "latency_p95_80.0ms")
        XCTAssertFalse(fallback.beginV2Load(), "this keyboard process stays on v1")

        // Slowness is never stored: the next keyboard process tries v2 again.
        XCTAssertFalse(defaults.bool(forKey: ChineseModelFallback.fallbackActiveKey))
        let nextProcess = ChineseModelFallback(defaultsProvider: { defaults }, appVersionProvider: { "1.0(1)" })
        XCTAssertFalse(nextProcess.isFallenBackToV1)
        XCTAssertTrue(nextProcess.beginV2Load())

        // Manual switch back to v2 resets fallback and window.
        fallback.resetForManualV2Selection()
        XCTAssertFalse(fallback.isFallenBackToV1)
    }

    func testStoredFallbackExpiresSoTheSameBuildRetriesV2() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let fallback = ChineseModelFallback(defaultsProvider: { defaults }, appVersionProvider: { "1.3(5)" }, now: { clock })
        XCTAssertTrue(fallback.beginV2Load())
        XCTAssertTrue(fallback.beginV2Load())
        XCTAssertFalse(fallback.beginV2Load())
        XCTAssertTrue(fallback.isFallenBackToV1)

        clock += ChineseModelFallback.retryInterval - 60
        let later = ChineseModelFallback(defaultsProvider: { defaults }, appVersionProvider: { "1.3(5)" }, now: { clock })
        XCTAssertTrue(later.isFallenBackToV1, "holds until the retry interval passes")

        clock += 60
        XCTAssertFalse(later.isFallenBackToV1)
        XCTAssertNil(later.fallbackReason)
        XCTAssertTrue(later.beginV2Load())
        later.finishV2LoadSuccess()
    }

    func testInMemoryFallbackWithoutAppGroup() {
        let fallback = ChineseModelFallback(defaultsProvider: { nil }, appVersionProvider: { "1.0(1)" })
        XCTAssertFalse(fallback.isFallenBackToV1)
        XCTAssertTrue(fallback.beginV2Load())

        fallback.recordRuntimeFailure(reason: "load_error: no_group")
        XCTAssertTrue(fallback.isFallenBackToV1)
        XCTAssertEqual(fallback.fallbackReason, "load_error: no_group")
        XCTAssertFalse(fallback.beginV2Load())

        fallback.resetForManualV2Selection()
        XCTAssertFalse(fallback.isFallenBackToV1)
        XCTAssertNil(fallback.fallbackReason)
        XCTAssertTrue(fallback.beginV2Load())
    }

    func testDefaultV2RerankingCorrectionAndV1V2SwitchingWithoutResidualState() throws {
        XCTAssertEqual(ChineseLanguageModel.defaultVersion, .v2)
        XCTAssertTrue(ChineseSentenceGeneration.isEnabled, "sentence generation is enabled by default")

        let bundle = Bundle(for: Self.self)
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        let queue = JapaneseCandidateWorker.modelQueue

        weak var firstV2: ChineseLanguageModel?
        weak var firstV1: ChineseLanguageModel?

        // 1. Default v2: reranking & sentence correction tokenScores work.
        try queue.sync {
            let v2 = try ChineseLanguageModel(bundle: bundle, version: .v2, preload: true)
            firstV2 = v2
            storage.useChinese(v2)
            XCTAssertEqual(storage.chineseModelVersion, .v2)
            let scores = try v2.scores(context: "我们明天去", candidates: ["公园散步", "公圆三步"])
            XCTAssertEqual(scores.count, 2)
            XCTAssertGreaterThan(scores[0], scores[1])
            let tokens = try v2.tokenScores(context: "", text: "今天天气很好")
            XCTAssertFalse(tokens.isEmpty)
            XCTAssertTrue(tokens.allSatisfy { $0.logProbability.isFinite })
            XCTAssertNotNil(ChineseSentenceGeneration.Storage.shared.generator(for: v2))
        }

        // 2. Switch to v1: previous v2 model is deallocated (only one model in memory at a time).
        try queue.sync {
            storage.release(.chinese)
            ChineseSentenceGeneration.Storage.shared.release()
            let v1 = try ChineseLanguageModel(bundle: bundle, version: .v1, preload: true)
            firstV1 = v1
            storage.useChinese(v1)
            XCTAssertEqual(storage.chineseModelVersion, .v1)
            let scores = try v1.scores(context: "我们明天去", candidates: ["公园散步", "公圆三步"])
            XCTAssertEqual(scores.count, 2)
            XCTAssertGreaterThan(scores[0], scores[1])
            let gen = try XCTUnwrap(ChineseSentenceGeneration.Storage.shared.generator(for: v1))
            XCTAssertEqual(gen.mode, .lm)
        }
        XCTAssertNil(firstV2, "v2 model must be released when switching to v1")

        // 3. Switch back to v2: v1 model is deallocated and v2 task mode works cleanly.
        try queue.sync {
            storage.release(.chinese)
            ChineseSentenceGeneration.Storage.shared.release()
            let v2Again = try ChineseLanguageModel(bundle: bundle, version: .v2, preload: true)
            storage.useChinese(v2Again)
            XCTAssertEqual(storage.chineseModelVersion, .v2)
            let gen = try XCTUnwrap(ChineseSentenceGeneration.Storage.shared.generator(for: v2Again))
            XCTAssertEqual(gen.mode, .task)
            storage.release(.chinese)
            ChineseSentenceGeneration.Storage.shared.release()
        }
        XCTAssertNil(firstV1, "v1 model must be released when switching back to v2")
    }
}
