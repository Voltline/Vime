import XCTest
@testable import Vime

@MainActor
final class ChinesePauseGenerationTests: XCTestCase {
    private static let userDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChinesePauseGenerationTests-\(UUID().uuidString)")

    private func makeSession(phrases: [ChineseUserPhrase] = []) throws -> ChineseInputSession {
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let dir = Self.userDir.appendingPathComponent("dict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ChinesePauseGenerationTests.\(UUID().uuidString)")!
        let store = ChineseUserDictionaryStore(directory: dir, defaults: defaults)
        if !phrases.isEmpty {
            try store.save(phrases)
        }
        let session = ChineseInputSession(
            engine: RimeEngine(data: data, userDirectory: Self.userDir),
            userDictionary: store
        )
        // Avoid Debug Simulator model latency flaking against real-time windows.
        session.rankingWindow = 5.0
        session.generationWindow = TimeInterval.infinity
        return session
    }

    private func injectV2Model() throws {
        ChineseModelFallback.shared.resetForManualV2Selection()
        let model = try ChineseLanguageModel(bundle: Bundle(for: Self.self), version: .v2, preload: true)
        JapaneseCandidateWorker.modelQueue.sync {
            JapaneseCandidateWorker.LanguageModelStorage.shared.useChinese(model)
        }
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 15,
                           file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition", file: file, line: line)
    }

    // MARK: Pure decision & eligibility rules

    func testDecideReplacesLeadWhenMarginMeetsThreshold() {
        let cand = ChineseSentenceGeneration.Candidate(
            text: "怎么搞的", generationScore: -4.0, modelScore: -6.0, score: -13.6)
        let decision = ChineseSentenceGeneration.decide(
            generated: cand, currentLead: "在美国的",
            currentScore: -10.0, generatedScore: -6.5, leadProtected: false)
        XCTAssertEqual(decision, .init(candidate: cand, leads: true))
    }

    func testDecidePlacesSecondWhenMarginBelowLeadThreshold() {
        let cand = ChineseSentenceGeneration.Candidate(
            text: "怎么搞的", generationScore: -4.0, modelScore: -8.5, score: -17.6)
        let decision = ChineseSentenceGeneration.decide(
            generated: cand, currentLead: "在美国的",
            currentScore: -10.0, generatedScore: -8.5, leadProtected: false)
        XCTAssertEqual(decision, .init(candidate: cand, leads: false))
    }

    func testDecideDropsWhenIdenticalOrWorseThanLead() {
        let same = ChineseSentenceGeneration.Candidate(
            text: "今天天气很好", generationScore: -2.0, modelScore: -5.0, score: -10.0)
        XCTAssertNil(ChineseSentenceGeneration.decide(
            generated: same, currentLead: "今天天气很好",
            currentScore: -10.0, generatedScore: -5.0, leadProtected: false))

        let worse = ChineseSentenceGeneration.Candidate(
            text: "今天天起很好", generationScore: -5.0, modelScore: -12.0, score: -24.2)
        XCTAssertNil(ChineseSentenceGeneration.decide(
            generated: worse, currentLead: "今天天气很好",
            currentScore: -8.0, generatedScore: -12.0, leadProtected: false))
    }

    func testDecideNeverReplacesProtectedLead() {
        let cand = ChineseSentenceGeneration.Candidate(
            text: "去杭州玩", generationScore: -3.0, modelScore: -5.0, score: -11.0)
        // Even with a +10.0 LM margin, a protected lead (user phrase / learned / Rime whole word) stays rank 1.
        let decision = ChineseSentenceGeneration.decide(
            generated: cand, currentLead: "去杭州湾",
            currentScore: -15.0, generatedScore: -5.0, leadProtected: true)
        XCTAssertEqual(decision, .init(candidate: cand, leads: false))
    }

    func testWantsAcceptsOnlyPlainLowercaseWithinLengthRange() {
        XCTAssertFalse(ChineseSentenceGeneration.wants("abc"))
        XCTAssertTrue(ChineseSentenceGeneration.wants("abcd"))
        XCTAssertTrue(ChineseSentenceGeneration.wants(String(repeating: "a", count: 48)))
        XCTAssertFalse(ChineseSentenceGeneration.wants(String(repeating: "a", count: 49)))
        XCTAssertFalse(ChineseSentenceGeneration.wants("Abcd"))
        XCTAssertFalse(ChineseSentenceGeneration.wants("ni'hao"))
        XCTAssertFalse(ChineseSentenceGeneration.wants("2345"))
    }

    // MARK: End-to-end session integration

    func testPauseGenerationSurfacesAndCommitsGeneratedCandidate() throws {
        try injectV2Model()
        let session = try makeSession()
        defer { session.reset(preservingContext: false) }

        var commits: [KeyboardCommitBatch] = []
        session.onCommittedEdits = { commits.append($0) }

        // Rime produces "我们下个月底打算去杭州湾"; v2 task mode generates "我们下个月底打算去杭州玩".
        _ = session.type("womenxiageyuedidasuanquhangzhouwan")
        waitUntil { session.candidatesAreCurrent && session.hasGeneratedCandidate }

        let generatedIdx = try XCTUnwrap(
            session.candidatePresentations.firstIndex { $0.text == "我们下个月底打算去杭州玩" },
            "Expected generated sentence in \(session.candidatePresentations.map(\.text))")
        XCTAssertLessThanOrEqual(generatedIdx, 1, "Generated sentence should be at rank 1 or 2")
        XCTAssertFalse(ChineseModelFallback.shared.isFallenBackToV1,
                       "Pause generation must not trigger v2->v1 latency fallback")

        let token = try XCTUnwrap(session.candidatePresentations[generatedIdx].selectionToken)
        let edits = session.chooseCandidate(token)
        let committedText = (edits + commits.flatMap(\.edits)).compactMap { edit -> String? in
            if case .insert(let s) = edit { return s } else { return nil }
        }.joined()
        XCTAssertEqual(committedText, "我们下个月底打算去杭州玩")
        XCTAssertFalse(session.isComposing)
    }

    func testNewKeystrokeCancelsPendingGeneration() throws {
        try injectV2Model()
        let session = try makeSession()
        defer { session.reset(preservingContext: false) }

        _ = session.type("womenxiageyuedi")
        waitUntil { session.candidatesAreCurrent && session.hasPendingGeneration }
        // Typing a new key immediately cancels the pending generation request.
        _ = session.type("d")
        XCTAssertFalse(session.hasPendingGeneration, "New keystroke must immediately cancel pending generation")
        waitUntil { session.candidatesAreCurrent }
        XCTAssertEqual(session.raw, "womenxiageyuedid")
    }

    func testShuangpinAndNineKeyDoNotTriggerGeneration() throws {
        try injectV2Model()

        // 1. Shuangpin
        let spSession = try makeSession()
        defer { spSession.reset(preservingContext: false) }
        spSession.setChineseLayout(.shuangpin, shuangpin: .flypy)
        _ = spSession.type("jmtm")
        waitUntil { spSession.candidatesAreCurrent }
        XCTAssertFalse(spSession.hasPendingGeneration)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(spSession.hasGeneratedCandidate)

        // 2. Nine-key (T9)
        let t9Session = try makeSession()
        defer { t9Session.reset(preservingContext: false) }
        t9Session.setChineseLayout(.nineKey)
        _ = t9Session.type("9643")
        waitUntil { t9Session.candidatesAreCurrent }
        XCTAssertFalse(t9Session.hasPendingGeneration)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertFalse(t9Session.hasGeneratedCandidate)
    }

    func testUserPhraseLeadIsNeverDisplacedByGeneration() throws {
        try injectV2Model()
        let session = try makeSession(phrases: [ChineseUserPhrase(pinyin: "zen me gao de", text: "自定义词")])
        defer { session.reset(preservingContext: false) }

        _ = session.type("zmgd")
        waitUntil { session.candidatesAreCurrent }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(session.candidatePresentations.first?.text, "自定义词",
                       "User dictionary phrase at rank 1 must never be displaced by pause generation")
    }
}
