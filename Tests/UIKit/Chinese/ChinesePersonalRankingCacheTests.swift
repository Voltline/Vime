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

    func testNegativeFeedbackThresholdSelfHealingDecayAndPrivacy() throws {
        let cache = ChinesePersonalRankingCache(directory: tempDir)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Single skip (1.0) on a 3-syllable phrase stays below negativeMinimumEvidence (1.4): no premature penalty.
        cache.recordNegative(prevText: "", input: "meiyouren", rejected: "没有人",
                             weight: ChinesePersonalRankingCache.Policy.skipWeight, now: t0, exclusionsActive: false)
        XCTAssertEqual(cache.penalty(prevText: "", input: "meiyouren", candidate: "没有人", now: t0), 0)

        // Second skip activates bounded penalty for 3+ syllable phrase even with empty leftContext.
        cache.recordNegative(prevText: "", input: "meiyouren", rejected: "没有人",
                             weight: ChinesePersonalRankingCache.Policy.skipWeight, now: t0.addingTimeInterval(10), exclusionsActive: false)
        let p2 = cache.penalty(prevText: "", input: "meiyouren", candidate: "没有人", now: t0.addingTimeInterval(20))
        XCTAssertGreaterThan(p2, 0.5)
        XCTAssertLessThanOrEqual(p2, ChinesePersonalRankingCache.Policy.maximumPenalty)
        XCTAssertEqual(cache.adjustment(prevText: "", input: "meiyouren", candidate: "没有人", now: t0.addingTimeInterval(20)), -p2, accuracy: 1e-9)

        // Persists hashed input key only (never plaintext pinyin) and survives reload.
        cache.flushSynchronously()
        let raw = try String(contentsOf: tempDir.appendingPathComponent("ChinesePersonalRanking.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("meiyouren"), "Pinyin input must be hashed, never stored as plaintext")
        let reloaded = ChinesePersonalRankingCache(directory: tempDir)
        XCTAssertEqual(reloaded.penalty(prevText: "", input: "meiyouren", candidate: "没有人", now: t0.addingTimeInterval(20)), p2, accuracy: 1e-9)

        // Decays away after several negative half-lives (60 days).
        XCTAssertEqual(reloaded.penalty(prevText: "", input: "meiyouren", candidate: "没有人", now: t0.addingTimeInterval(60 * 24 * 3600)), 0)

        // Two independent undo events in a context activate penalty, and positive commit redeems it immediately.
        cache.recordNegative(prevText: "我去", input: "shanghai", rejected: "伤害",
                             weight: ChinesePersonalRankingCache.Policy.undoWeight, now: t0.addingTimeInterval(30), exclusionsActive: false)
        XCTAssertEqual(cache.penalty(prevText: "我去", input: "shanghai", candidate: "伤害", now: t0.addingTimeInterval(32)), 0,
                       "A single undo event must stay below threshold")
        cache.recordNegative(prevText: "我去", input: "shanghai", rejected: "伤害",
                             weight: ChinesePersonalRankingCache.Policy.undoWeight, now: t0.addingTimeInterval(34), exclusionsActive: false)
        XCTAssertGreaterThan(cache.penalty(prevText: "我去", input: "shanghai", candidate: "伤害", now: t0.addingTimeInterval(35)), 0.5)
        cache.record(prevText: "我去", committed: "伤害", input: "shanghai", now: t0.addingTimeInterval(40), exclusionsActive: false)
        XCTAssertEqual(cache.penalty(prevText: "我去", input: "shanghai", candidate: "伤害", now: t0.addingTimeInterval(45)), 0)

        // Reset clears penalties as well.
        cache.recordNegative(prevText: "", input: "ceshici", rejected: "测试词",
                             weight: ChinesePersonalRankingCache.Policy.undoWeight, now: t0.addingTimeInterval(50), exclusionsActive: false)
        cache.recordNegative(prevText: "", input: "ceshici", rejected: "测试词",
                             weight: ChinesePersonalRankingCache.Policy.undoWeight, now: t0.addingTimeInterval(52), exclusionsActive: false)
        XCTAssertGreaterThan(cache.penaltyEntryCount, 0)
        cache.applyResetIfNeeded(resetID: "reset-epoch-neg")
        XCTAssertEqual(cache.penaltyEntryCount, 0)
    }

    func testShortPinyinAcrossDifferentContextsDoesNotPenalizeHighFrequencyChar() {
        let cache = ChinesePersonalRankingCache(directory: tempDir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // User occasionally picks "事" instead of "是" for single-syllable `shi` across varied contexts.
        let contexts = ["", "这件", "我的", "那个", "今天", "还有"]
        for (idx, ctx) in contexts.enumerated() {
            cache.recordNegative(
                prevText: ctx,
                input: "shi",
                rejected: "是",
                weight: ChinesePersonalRankingCache.Policy.skipWeight,
                now: now.addingTimeInterval(Double(idx) * 10),
                exclusionsActive: false
            )
        }

        // No global penalty in empty context or in a fresh unseen context.
        XCTAssertEqual(cache.penalty(prevText: "", input: "shi", candidate: "是", now: now.addingTimeInterval(100)), 0)
        XCTAssertEqual(cache.penalty(prevText: "这里", input: "shi", candidate: "是", now: now.addingTimeInterval(100)), 0)
        // Even in each seen context, a single skip never crosses the activation threshold.
        for ctx in contexts {
            XCTAssertEqual(cache.penalty(prevText: ctx, input: "shi", candidate: "是", now: now.addingTimeInterval(100)), 0)
        }

        // High-frequency "是" stays rank 0 in candidate ranking.
        let candidates = [
            RimeCandidate(text: "是", comment: nil, coversInput: true, sentence: false),
            RimeCandidate(text: "事", comment: nil, coversInput: true, sentence: false),
        ]
        let slots = ChineseCandidateRanking.slots(candidates) { _ in true }
        let personal = ChineseCandidateRanking.personal(candidates, slots: slots, before: "这里", input: "shi", cache: cache)
        XCTAssertTrue(personal.isEmpty)
        let ordered = ChineseCandidateRanking.order(
            count: candidates.count, sentences: 0..<0, slots: slots, scores: [-4.0, -4.5], personal: personal)
        XCTAssertEqual(ordered, [0, 1])
    }

    func testNegativeFeedbackDemotesRejectedLeadInCandidateRanking() {
        let cache = ChinesePersonalRankingCache(directory: tempDir)
        let now = Date()
        let candidates = [
            RimeCandidate(text: "方案一", comment: nil, coversInput: true, sentence: true),
            RimeCandidate(text: "方案二", comment: nil, coversInput: true, sentence: true),
        ]
        let slots = ChineseCandidateRanking.slots(candidates) { _ in true }

        // Without negative feedback, rank 0 wins a close score tie (-10.0 vs -10.3).
        let baseOrder = ChineseCandidateRanking.order(
            count: candidates.count, sentences: 0..<2, slots: slots, scores: [-10.0, -10.3], personal: [:])
        XCTAssertEqual(baseOrder, [0, 1])

        // After 2 independent negative events on 3-syllable rank 0, negative adjustment demotes rank 0 below rank 1.
        cache.recordNegative(prevText: "", input: "fanganyi", rejected: "方案一",
                             weight: ChinesePersonalRankingCache.Policy.undoWeight, now: now, exclusionsActive: false)
        cache.recordNegative(prevText: "", input: "fanganyi", rejected: "方案一",
                             weight: ChinesePersonalRankingCache.Policy.undoWeight, now: now.addingTimeInterval(5), exclusionsActive: false)
        let personal = ChineseCandidateRanking.personal(candidates, slots: slots, before: "", input: "fanganyi", cache: cache)
        XCTAssertLessThan(personal[0] ?? 0, -0.5)
        let demotedOrder = ChineseCandidateRanking.order(
            count: candidates.count, sentences: 0..<2, slots: slots, scores: [-10.0, -10.3], personal: personal)
        XCTAssertEqual(demotedOrder, [1, 0])
    }

    func testNegativeFeedbackOverridesLearnedUserPhraseWithModelScoresOnly() {
        let cache = ChinesePersonalRankingCache(directory: tempDir)
        let now = Date()
        let candidates = [
            RimeCandidate(text: "伤害", comment: nil, coversInput: true, userPhrase: true, sentence: false),
            RimeCandidate(text: "上海", comment: nil, coversInput: true, userPhrase: false, sentence: false),
        ]

        // Before negative feedback, learned userPhrase stays protected and out of reorderable slots.
        let beforeSlots = ChineseCandidateRanking.slots(
            candidates,
            penalized: { cache.penalty(prevText: "我去", input: "shanghai", candidate: $0) > 0 }
        ) { _ in true }
        XCTAssertFalse(beforeSlots.canReorder)

        // After 2 independent events in context "我去", it enters reorderable slots and drops below "上海"
        // via the LM personal adjustment channel. Without LM scores, Rime order [0, 1] stays untouched.
        cache.recordNegative(prevText: "我去", input: "shanghai", rejected: "伤害",
                             weight: ChinesePersonalRankingCache.Policy.skipWeight, now: now, exclusionsActive: false)
        cache.recordNegative(prevText: "我去", input: "shanghai", rejected: "伤害",
                             weight: ChinesePersonalRankingCache.Policy.undoWeight, now: now.addingTimeInterval(5), exclusionsActive: false)
        let afterSlots = ChineseCandidateRanking.slots(
            candidates,
            penalized: { cache.penalty(prevText: "我去", input: "shanghai", candidate: $0) > 0 }
        ) { _ in true }
        XCTAssertTrue(afterSlots.canReorder)
        let personal = ChineseCandidateRanking.personal(candidates, slots: afterSlots, before: "我去", input: "shanghai", cache: cache)
        XCTAssertLessThan(personal[0] ?? 0, -1.0)
        let reordered = ChineseCandidateRanking.order(
            count: candidates.count, sentences: 0..<0, slots: afterSlots, scores: [-8.0, -8.0], personal: personal)
        XCTAssertEqual(reordered, [1, 0])
        XCTAssertEqual(ChineseCandidateRanking.order(count: candidates.count, sentences: 0..<0), [0, 1])
    }

    func testPositiveAndNegativeEvidenceCoexistInAdjustment() {
        let cache = ChinesePersonalRankingCache(directory: tempDir)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        cache.record(prevText: "我去", committed: "伤害", input: "shanghai", now: now, exclusionsActive: false)
        cache.record(prevText: "我去", committed: "伤害", input: "shanghai", now: now.addingTimeInterval(5), exclusionsActive: false)
        let bonusBefore = cache.bonus(prevText: "我去", candidate: "伤害", now: now.addingTimeInterval(10))
        XCTAssertGreaterThan(bonusBefore, 0)

        cache.recordNegative(prevText: "我去", input: "shanghai", rejected: "伤害",
                             weight: ChinesePersonalRankingCache.Policy.skipWeight, now: now.addingTimeInterval(12), exclusionsActive: false)
        cache.recordNegative(prevText: "我去", input: "shanghai", rejected: "伤害",
                             weight: ChinesePersonalRankingCache.Policy.undoWeight, now: now.addingTimeInterval(15), exclusionsActive: false)

        let bonusAfter = cache.bonus(prevText: "我去", candidate: "伤害", now: now.addingTimeInterval(20))
        let penaltyAfter = cache.penalty(prevText: "我去", input: "shanghai", candidate: "伤害", now: now.addingTimeInterval(20))
        let adj = cache.adjustment(prevText: "我去", input: "shanghai", candidate: "伤害", now: now.addingTimeInterval(20))
        XCTAssertGreaterThan(bonusAfter, 0, "Positive bonus must not be deleted by negative feedback")
        XCTAssertGreaterThan(penaltyAfter, 0)
        XCTAssertEqual(adj, bonusAfter - penaltyAfter, accuracy: 1e-9)
    }

    func testSessionPartialDeleteAndEarlierTypoEditDoNotPenalize() throws {
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let userDir = tempDir.appendingPathComponent("rime-partial-delete", isDirectory: true)
        ChinesePersonalRankingCache.shared.clear()
        defer { ChinesePersonalRankingCache.shared.clear() }

        var hostText = "我去"
        let session = ChineseInputSession(
            engine: RimeEngine(data: data, userDirectory: userDir),
            exclusions: LearningExclusionList(data: Data()),
            exclusionsApply: { false }
        )
        session.setChineseLanguageModel(false)
        session.leftContextProvider = { hostText }
        session.onCommittedEdits = { batch in
            for edit in batch.edits {
                if case .insert(let text) = edit { hostText += text }
            }
        }

        func waitUntilCurrent() {
            let deadline = Date().addingTimeInterval(10)
            while !session.candidatesAreCurrent && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(session.candidatesAreCurrent)
        }

        // Scenario A: Commit 2-char "上海", delete only 1 char ("海"), then resume typing -> NO penalty.
        for _ in 0..<2 {
            hostText = "我去"
            _ = session.type("shanghai")
            waitUntilCurrent()
            let token = try XCTUnwrap(session.candidatePresentations.first { $0.text == "上海" }?.selectionToken)
            _ = session.chooseCandidate(token)
            waitUntilCurrent()
            session.reset()
            _ = session.backspace()
            hostText.removeLast()
            _ = session.type("h")
            waitUntilCurrent()
            session.reset()
        }
        XCTAssertEqual(ChinesePersonalRankingCache.shared.penalty(prevText: "我去", input: "shanghai", candidate: "上海"), 0)

        // Scenario B: Commit 2-char "上海", delete 3 chars to fix an earlier typo ("去上海") -> NO penalty.
        for _ in 0..<2 {
            hostText = "我去"
            _ = session.type("shanghai")
            waitUntilCurrent()
            let token = try XCTUnwrap(session.candidatePresentations.first { $0.text == "上海" }?.selectionToken)
            _ = session.chooseCandidate(token)
            waitUntilCurrent()
            session.reset()
            for _ in 0..<3 {
                _ = session.backspace()
                hostText.removeLast()
            }
            _ = session.type("q")
            waitUntilCurrent()
            session.reset()
        }
        XCTAssertEqual(ChinesePersonalRankingCache.shared.penalty(prevText: "我去", input: "shanghai", candidate: "上海"), 0)
    }

    func testSessionExactUndoRequiresTwoEventsAndSurvivesHostReset() throws {
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let userDir = tempDir.appendingPathComponent("rime-undo", isDirectory: true)
        ChinesePersonalRankingCache.shared.clear()
        defer { ChinesePersonalRankingCache.shared.clear() }

        var hostText = "我去"
        let currentDoc = "doc-1"
        let session = ChineseInputSession(
            engine: RimeEngine(data: data, userDirectory: userDir),
            exclusions: LearningExclusionList(data: Data()),
            exclusionsApply: { false }
        )
        session.setChineseLanguageModel(false)
        session.leftContextProvider = { hostText }
        session.learningContextProvider = {
            KeyboardLearningContext(document: currentDoc, before: hostText, after: nil, hasSelection: false)
        }
        session.onCommittedEdits = { batch in
            for edit in batch.edits {
                if case .insert(let text) = edit { hostText += text }
            }
        }

        func waitUntilCurrent() {
            let deadline = Date().addingTimeInterval(10)
            while !session.candidatesAreCurrent && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(session.candidatesAreCurrent)
        }

        func commitAndExactUndoHarm() throws {
            hostText = "我去"
            _ = session.type("shanghai")
            waitUntilCurrent()
            let harmToken = try XCTUnwrap(session.candidatePresentations.first { $0.text == "伤害" }?.selectionToken)
            _ = session.chooseCandidate(harmToken)
            waitUntilCurrent()
            XCTAssertEqual(hostText, "我去伤害")
            session.reset()
            _ = session.backspace()
            hostText.removeLast()
            session.reset()
            _ = session.backspace()
            hostText.removeLast()
            // Resuming typing commits the exact-length undo event.
            _ = session.type("s")
            waitUntilCurrent()
            session.reset()
        }

        // First exact undo alone (1.0 < 1.4) stays below threshold.
        try commitAndExactUndoHarm()
        XCTAssertEqual(ChinesePersonalRankingCache.shared.penalty(prevText: "我去", input: "shanghai", candidate: "伤害"), 0)

        // Second independent exact undo activates penalty (2.0 >= 1.4).
        try commitAndExactUndoHarm()
        XCTAssertGreaterThan(ChinesePersonalRankingCache.shared.penalty(prevText: "我去", input: "shanghai", candidate: "伤害"), 1.0)
        // Does not bleed into unrelated context.
        XCTAssertEqual(ChinesePersonalRankingCache.shared.penalty(prevText: "不能", input: "shanghai", candidate: "伤害"), 0)
    }

    func testShuangpinNegativeFeedbackUsesCanonicalPinyinKey() throws {
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let userDir = tempDir.appendingPathComponent("rime-shuangpin-neg", isDirectory: true)
        ChinesePersonalRankingCache.shared.clear()
        defer { ChinesePersonalRankingCache.shared.clear() }

        var hostText = "我去"
        let session = ChineseInputSession(
            engine: RimeEngine(data: data, userDirectory: userDir),
            exclusions: LearningExclusionList(data: Data()),
            exclusionsApply: { false }
        )
        session.setChineseLanguageModel(false)
        session.setChineseLayout(.shuangpin, shuangpin: .flypy)
        session.leftContextProvider = { hostText }
        session.onCommittedEdits = { batch in
            for edit in batch.edits {
                if case .insert(let text) = edit { hostText += text }
            }
        }

        func waitUntilCurrent() {
            let deadline = Date().addingTimeInterval(10)
            while !session.candidatesAreCurrent && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(session.candidatesAreCurrent)
        }

        // In Xiaohe shuangpin (flypy), "uhhd" spells "shanghai" (u=sh, h=ang, h=h, d=ai).
        for _ in 0..<2 {
            hostText = "我去"
            _ = session.type("uhhd")
            waitUntilCurrent()
            let harmToken = try XCTUnwrap(session.candidatePresentations.first { $0.text == "伤害" }?.selectionToken)
            _ = session.chooseCandidate(harmToken)
            waitUntilCurrent()
            XCTAssertEqual(hostText, "我去伤害")
            session.reset()
            _ = session.backspace()
            hostText.removeLast()
            _ = session.backspace()
            hostText.removeLast()
            _ = session.type("u")
            waitUntilCurrent()
            session.reset()
        }

        // Stored under the canonical pinyin key "shanghai", matching full-pinyin lookup & sentence generation.
        XCTAssertGreaterThan(
            ChinesePersonalRankingCache.shared.penalty(prevText: "我去", input: "shanghai", candidate: "伤害"),
            1.0
        )
    }
}
