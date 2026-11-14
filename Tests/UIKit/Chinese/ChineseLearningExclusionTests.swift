import XCTest

/// The excluded-terms list in Chinese input, with placeholder terms: what it
/// matches gets no suggestions or corrections and is not learned.
@MainActor
final class ChineseLearningExclusionTests: XCTestCase {
    /// One user dictionary for the class: Rime runs once per process.
    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChineseLearningExclusionTests-\(UUID().uuidString)")
    private var batches: [KeyboardCommitBatch] = []

    private func engine() throws -> RimeEngine {
        RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled"), userDirectory: Self.user)
    }

    private func session(excluding terms: [String], active: Bool = true) throws -> ChineseInputSession {
        let list = LearningExclusionList(data: LearningExclusionList.encode(blocked: terms, allowed: []))
        XCTAssertTrue(list.isAvailable)
        let session = ChineseInputSession(engine: try engine(), exclusions: list, exclusionsApply: { active })
        session.onCommittedEdits = { [weak self] in self?.batches.append($0) }
        return session
    }

    private func settle(_ session: ChineseInputSession, until done: () -> Bool = { true }, within seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while !(session.candidatesAreCurrent && done()) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Commits `pinyin` with Space and returns the suggestions that follow.
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

    func testSuggestionsLeaveOutWhatTheListMatches() throws {
        XCTAssertTrue(suggestions(after: "dianhua", in: try session(excluding: ["号码"], active: false)).contains("号码"),
                      "the list does nothing while it does not apply")

        let session = try session(excluding: ["电话号码"])
        let shown = suggestions(after: "dianhua", in: session)
        XCTAssertEqual(batches.last?.edits, [.insert("电话")])
        XCTAssertFalse(shown.isEmpty, "other suggestions still show")
        XCTAssertFalse(shown.contains("号码"), "\(shown)")

        let blocked = try self.session(excluding: ["电话"])
        XCTAssertEqual(suggestions(after: "dianhua", in: blocked), [], "a matched word gets no suggestions at all")
        XCTAssertEqual(batches.last?.edits, [.insert("电话")], "typing it is never blocked")
    }

    func testCorrectionsLeaveOutWhatTheListMatches() throws {
        XCTAssertTrue(corrections(for: "maoai", in: try session(excluding: ["貌似"], active: false)).contains("貌似"))
        XCTAssertFalse(corrections(for: "maoai", in: try session(excluding: ["貌似"])).contains("貌似"))
    }

    func testRimeDoesNotLearnWhatTheListMatches() throws {
        let saved = RimeEngine.allowsLearning
        defer { RimeEngine.allowsLearning = saved }
        RimeEngine.allowsLearning = { $0 != "势" }
        let engine = try self.engine()
        func rank(of text: String) -> Int? {
            let index = engine.sendAndWait(.type("shi")).candidates.firstIndex { $0.text == text }
            _ = engine.sendAndWait(.clear)
            return index
        }
        func choose(_ text: String) throws {
            for _ in 0..<3 {
                let index = try XCTUnwrap(engine.sendAndWait(.type("shi")).candidates.firstIndex { $0.text == text })
                XCTAssertEqual(engine.sendAndWait(.select(index)).commit, text, "typing it is never blocked")
                _ = engine.sendAndWait(.finishLearning)
            }
        }
        _ = engine.sendAndWait(.clear)
        let blocked = try XCTUnwrap(rank(of: "势"))
        try choose("势")
        XCTAssertEqual(rank(of: "势"), blocked)

        let learned = try XCTUnwrap(rank(of: "式"))
        try choose("式")
        XCTAssertLessThan(try XCTUnwrap(rank(of: "式")), learned)
    }
}
