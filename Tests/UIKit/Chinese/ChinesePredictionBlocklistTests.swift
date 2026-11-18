import XCTest

/// The prediction blocklist in Chinese input, with a
/// placeholder term: it applies whatever the region.
@MainActor
final class ChinesePredictionBlocklistTests: XCTestCase {
    /// One user dictionary for the class: Rime runs once per process.
    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChinesePredictionBlocklistTests-\(UUID().uuidString)")

    private func session(blocking terms: [String]) throws -> ChineseInputSession {
        try session(blocklist: LearningExclusionList(data: LearningExclusionList.encode(blocked: terms, allowed: [])))
    }

    private func session(blocklist: LearningExclusionList) throws -> ChineseInputSession {
        let engine = RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled"), userDirectory: Self.user)
        // The regional list stays off: the blocklist does not depend on it.
        return ChineseInputSession(engine: engine, exclusions: LearningExclusionList(data: Data()), exclusionsApply: { false },
            blocklist: blocklist)
    }

    private func settle(_ session: ChineseInputSession, until done: () -> Bool = { true }, within seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !(session.candidatesAreCurrent && done()) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private func suggestions(after pinyin: String, in session: ChineseInputSession) -> [String] {
        _ = session.type(pinyin)
        settle(session, within: 5)
        _ = session.space()
        settle(session, until: { !session.suggestionTexts.isEmpty }, within: 3)
        defer { session.reset() }
        return session.suggestionTexts
    }

    private func corrections(for typed: String, in session: ChineseInputSession) -> [String] {
        _ = session.type(typed)
        let found = { session.candidatePresentations.filter { $0.source == .typoCorrection }.map(\.text) }
        settle(session, until: { !found().isEmpty }, within: 3)
        defer { session.reset() }
        return found()
    }

    func testSuggestionsLeaveOutBlockedTermsInEveryRegion() throws {
        XCTAssertTrue(suggestions(after: "dianhua", in: try session(blocking: [])).contains("号码"))
        let shown = suggestions(after: "dianhua", in: try session(blocking: ["电话号码"]))
        XCTAssertFalse(shown.isEmpty, "ordinary suggestions still show")
        XCTAssertFalse(shown.contains("号码"), "\(shown)")
    }

    func testCorrectionsLeaveOutBlockedTerms() throws {
        XCTAssertTrue(corrections(for: "maoai", in: try session(blocking: [])).contains("貌似"))
        XCTAssertFalse(corrections(for: "maoai", in: try session(blocking: ["貌似"])).contains("貌似"))
    }

    func testTypingABlockedTermStillCommitsIt() throws {
        let session = try session(blocking: ["电话"])
        var commits: [KeyboardEdit] = []
        session.onCommittedEdits = { commits += $0.edits }
        _ = session.type("dianhua")
        settle(session, within: 5)
        XCTAssertEqual(session.candidatePresentations.first?.text, "电话")
        commits += session.space()
        settle(session, within: 3)
        XCTAssertTrue(commits.contains(.insert("电话")), "\(commits)")
        XCTAssertEqual(session.suggestionTexts, [])
    }

    /// Country names stay suggestible, and so do the everyday words after them.
    func testBundledListKeepsEverydaySuggestionsAfterCountryNames() throws {
        let bundled = PredictionBlocklist.shared
        try XCTSkipUnless(bundled.isAvailable, "PredictionBlocklist.bin is not bundled")
        for word in ["日本", "韩国", "日本人", "日本料理", "韩国旅游", "韩国料理", "韩国电影", "日本の伝統", "韓国の大学"] {
            XCTAssertFalse(bundled.matches(word), word)
        }
        let session = try session(blocklist: bundled)
        let japan = suggestions(after: "riben", in: session)
        XCTAssertTrue(japan.contains("人"), "\(japan)")
        let korea = suggestions(after: "hanguo", in: session)
        XCTAssertTrue(korea.contains("料理") && korea.contains("电影"), "\(korea)")
    }
}
