import XCTest
@testable import VimeKeyboard

@MainActor
final class ChinesePersonalRankingCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChinesePersonalRankingTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testMinimumSelectionsDecayAndScaleBound() {
        let cache = ChinesePersonalRankingCache(directory: tempDir)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Single observation does not cross minimumSelections (2).
        cache.record(prevText: "今天", committed: "天气", now: t0, exclusionsActive: false)
        XCTAssertEqual(cache.bonus(prevText: "今天", candidate: "天气", now: t0), 0)

        // Second observation activates positive bonus, strictly bounded below keepBonus (2.0).
        cache.record(prevText: "今天", committed: "天气", now: t0.addingTimeInterval(60), exclusionsActive: false)
        let b2 = cache.bonus(prevText: "今天", candidate: "天气", now: t0.addingTimeInterval(120))
        XCTAssertGreaterThan(b2, 0.1)
        XCTAssertLessThanOrEqual(b2, ChinesePersonalRankingCache.Policy.maximumBonus)
        XCTAssertLessThan(ChinesePersonalRankingCache.Policy.maximumBonus, ChineseCandidateRanking.keepBonus)

        // Heavy repetition still respects maximumBonus cap.
        for i in 0..<40 {
            cache.record(prevText: "今天", committed: "天气", now: t0.addingTimeInterval(Double(200 + i)), exclusionsActive: false)
        }
        let bMax = cache.bonus(prevText: "今天", candidate: "天气", now: t0.addingTimeInterval(500))
        XCTAssertLessThanOrEqual(bMax, ChinesePersonalRankingCache.Policy.maximumBonus)

        // After 120 days (4 half-lives), decayed bonus drops clearly below the uncapped plateau.
        let bDecayed = cache.bonus(prevText: "今天", candidate: "天气", now: t0.addingTimeInterval(120 * 24 * 3600))
        XCTAssertLessThan(bDecayed, bMax)
    }

    func testWholeSentenceCandidateMatchesLearnedCollocationPrefix() {
        let cache = ChinesePersonalRankingCache(directory: tempDir)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<4 {
            cache.record(prevText: "明天", committed: "上午", now: t0.addingTimeInterval(Double(i * 10)), exclusionsActive: false)
        }
        let exact = cache.bonus(prevText: "明天", candidate: "上午", now: t0.addingTimeInterval(100))
        let sentence = cache.bonus(prevText: "明天", candidate: "上午去开会", now: t0.addingTimeInterval(100))
        let unrelated = cache.bonus(prevText: "明天", candidate: "下午去开会", now: t0.addingTimeInterval(100))

        XCTAssertGreaterThan(exact, 0.2)
        XCTAssertGreaterThan(sentence, 0.1)
        XCTAssertLessThan(sentence, exact)
        XCTAssertEqual(unrelated, 0)
    }

    func testPersistsHashedContextOnlyNeverPlaintextAndSurvivesReload() throws {
        let cache = ChinesePersonalRankingCache(directory: tempDir)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        cache.record(prevText: "秘密前文上下文", committed: "回复", now: t0, exclusionsActive: false)
        cache.record(prevText: "秘密前文上下文", committed: "回复", now: t0.addingTimeInterval(5), exclusionsActive: false)
        cache.flushSynchronously()

        let fileURL = tempDir.appendingPathComponent("ChinesePersonalRanking.json")
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("秘密前文上下文"), "Context must be hashed, never stored as plaintext")

        // Reloading from disk (simulating backup/restore or process restart) preserves learned bonus.
        let reloaded = ChinesePersonalRankingCache(directory: tempDir)
        XCTAssertGreaterThan(reloaded.bonus(prevText: "秘密前文上下文", candidate: "回复", now: t0.addingTimeInterval(10)), 0.1)
    }

    func testResetAndLearningExclusionPolicy() {
        let exclusions = LearningExclusionList(data: LearningExclusionList.encode(blocked: ["敏感词"], allowed: []))
        let cache = ChinesePersonalRankingCache(directory: tempDir)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Excluded committed word or excluded context is never recorded when policy is active.
        cache.record(prevText: "测试", committed: "敏感词", now: t0, exclusionsActive: true, exclusionList: exclusions)
        cache.record(prevText: "测试", committed: "敏感词", now: t0.addingTimeInterval(1), exclusionsActive: true, exclusionList: exclusions)
        cache.record(prevText: "敏感词", committed: "内容", now: t0, exclusionsActive: true, exclusionList: exclusions)
        cache.record(prevText: "敏感词", committed: "内容", now: t0.addingTimeInterval(1), exclusionsActive: true, exclusionList: exclusions)
        XCTAssertEqual(cache.entryCount, 0)

        // Normal entry gets cleared on resetID change.
        cache.record(prevText: "好的", committed: "收到", now: t0, exclusionsActive: true, exclusionList: exclusions)
        cache.record(prevText: "好的", committed: "收到", now: t0.addingTimeInterval(2), exclusionsActive: true, exclusionList: exclusions)
        XCTAssertGreaterThan(cache.entryCount, 0)

        cache.applyResetIfNeeded(resetID: "reset-epoch-1")
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.bonus(prevText: "好的", candidate: "收到", now: t0.addingTimeInterval(5)), 0)
    }
}
