import UIKit
import XCTest

@MainActor
final class ChineseInputSessionTests: XCTestCase {
    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChineseInputSessionTests-\(UUID().uuidString)")
    private var batches: [KeyboardCommitBatch] = []

    private func session() throws -> ChineseInputSession {
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user))
        session.onCommittedEdits = { [weak self] in self?.batches.append($0) }
        return session
    }

    /// Lets queued results reach the main thread.
    private func waitUntilCurrent(_ session: ChineseInputSession, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while !session.candidatesAreCurrent && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        // A delivery already scheduled for the last result may still be pending.
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(session.candidatesAreCurrent, "Rime did not answer", file: file, line: line)
    }

    private func token(_ text: String, in session: ChineseInputSession) throws -> CandidateSelectionToken {
        try XCTUnwrap(session.candidatePresentations.first { $0.text == text }?.selectionToken,
                      "\(session.candidatePresentations.map(\.text))")
    }

    func testLettersEchoAtOnceAndChoosingCommitsOnce() throws {
        let session = try session()
        XCTAssertEqual(session.type("ni"), [])
        XCTAssertEqual(session.markedText?.text, "ni", "letters show before Rime answers")
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(session.type("hao"), [])
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "nihao")
        XCTAssertEqual(session.candidatePresentations.first?.text, "你好")
        XCTAssertEqual(session.chooseCandidate(try token("你好", in: session)), [], "the commit arrives as a batch")
        waitUntilCurrent(session)
        XCTAssertEqual(batches.map(\.edits), [[.insert("你好")]])
        XCTAssertEqual(batches.first?.hostEpoch, session.hostEpoch)
        XCTAssertFalse(session.isComposing)
        XCTAssertNil(session.markedText)
        XCTAssertTrue(session.candidatePresentations.isEmpty)
    }

    func testRapidKeysKeepTheirOrder() throws {
        let session = try session()
        for letter in "women" { _ = session.type(String(letter)) }
        _ = session.backspace()
        _ = session.type("n")
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "women")
        XCTAssertEqual(session.candidatePresentations.first?.text, "我们")
        session.reset()
    }

    func testOldCandidatesCannotBeChosenWhileKeysRun() throws {
        let session = try session()
        _ = session.type("ni")
        waitUntilCurrent(session)
        let old = try XCTUnwrap(session.candidatePresentations.first?.selectionToken)
        _ = session.type("hao")
        XCTAssertFalse(session.candidatesAreCurrent)
        XCTAssertEqual(session.chooseCandidate(old), [])
        waitUntilCurrent(session)
        XCTAssertEqual(session.chooseCandidate(old), [], "a new list has a new generation")
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(session.raw, "nihao")
        session.reset()
    }

    func testPunctuationCommitsTheCompositionFirst() throws {
        let session = try session()
        _ = session.type("nihao")
        // No wait: the literal must still land after the pending letters.
        XCTAssertEqual(session.insertLiteral("，"), [.insert("你好"), .insert("，")])
        waitUntilCurrent(session)
        XCTAssertTrue(batches.isEmpty, "a commit returned as edits is never sent again")
        XCTAssertFalse(session.isComposing)
        XCTAssertEqual(session.type("!"), [.insert("!")])
    }

    func testPartialSelectionThenConfirmAll() throws {
        let session = try session()
        _ = session.type("nihaoma")
        waitUntilCurrent(session)
        _ = session.chooseCandidate(try token("你好", in: session))
        waitUntilCurrent(session)
        XCTAssertTrue(batches.isEmpty)
        XCTAssertTrue(session.isComposing)
        XCTAssertTrue(session.markedText?.text.hasPrefix("你好") == true, "\(session.markedText?.text ?? "nil")")
        XCTAssertEqual(session.candidatePresentations.first?.text, "吗")
        XCTAssertEqual(session.confirmAll(), [.insert("你好吗")])
        XCTAssertNil(session.markedText)
    }

    func testSpaceSelectsAndReturnCommitsTheLetters() throws {
        let session = try session()
        _ = session.type("zhongwen")
        XCTAssertEqual(session.space(), [])
        waitUntilCurrent(session)
        XCTAssertEqual(batches.last?.edits, [.insert("中文")])
        _ = session.type("xi")
        _ = session.type("'")
        _ = session.type("an")
        XCTAssertEqual(session.markedText?.text.replacingOccurrences(of: ChineseInputSession.syllableGap, with: ""), "xi'an")
        XCTAssertEqual(session.enter(), [])
        waitUntilCurrent(session)
        XCTAssertEqual(batches.last?.edits, [.insert("xi'an")])
        XCTAssertEqual(session.space(), [.insert(" ")])
        XCTAssertEqual(session.enter(), [.returnKey])
        XCTAssertEqual(session.backspace(), [.deleteBackward])
    }

    /// Lets a suggestion lookup answer; true once suggestions show.
    private func waitForSuggestions(_ session: ChineseInputSession) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while session.suggestionTexts.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return !session.suggestionTexts.isEmpty
    }

    func testCommittedWordsOfferWhatFollowsThem() throws {
        let session = try session()
        _ = session.type("dianhua")
        XCTAssertEqual(session.space(), [])
        waitUntilCurrent(session)
        XCTAssertEqual(batches.last?.edits, [.insert("电话")])
        XCTAssertTrue(waitForSuggestions(session))
        XCTAssertTrue(session.showsStrip)
        XCTAssertTrue(session.candidatePresentations.isEmpty, "suggestions show in the strip only")
        XCTAssertTrue(session.suggestionTexts.contains("号码"), "\(session.suggestionTexts)")
        let suggestion = try XCTUnwrap(session.stripPresentations.first { $0.text == "号码" }?.selectionToken)
        XCTAssertEqual(suggestion.kind, .suggestion)
        XCTAssertEqual(session.chooseCandidate(suggestion), [.insert("号码")])
        XCTAssertEqual(session.chooseCandidate(suggestion), [], "a chosen suggestion is gone")
        // Choosing one asks about the phrase it ends in turn; typing hides them.
        _ = waitForSuggestions(session)
        _ = session.type("w")
        XCTAssertTrue(session.suggestionTexts.isEmpty)
        waitUntilCurrent(session)
        session.reset()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // A literal after the commit, and the switch, keep them away.
        _ = session.type("women")
        XCTAssertEqual(session.insertLiteral("，"), [.insert("我们"), .insert("，")])
        XCTAssertFalse(waitForSuggestions(session))
        session.updateIntelligence(ranking: .engine, suggestionsEnabled: false)
        _ = session.type("women")
        _ = session.space()
        waitUntilCurrent(session)
        XCTAssertFalse(waitForSuggestions(session))
        session.updateIntelligence(ranking: .engine, suggestionsEnabled: true)
        _ = session.type("women")
        _ = session.space()
        waitUntilCurrent(session)
        XCTAssertTrue(waitForSuggestions(session))
        XCTAssertEqual(session.backspace(), [.deleteBackward])
        XCTAssertTrue(session.suggestionTexts.isEmpty)
        session.reset()
    }

    /// Lets a correction lookup answer; the corrections shown.
    private func corrections(_ session: ChineseInputSession, within seconds: TimeInterval = 5) -> [CandidatePresentation] {
        let deadline = Date().addingTimeInterval(seconds)
        func found() -> [CandidatePresentation] { session.candidatePresentations.filter { $0.source == .typoCorrection } }
        while found().isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        return found()
    }

    func testTyposAcrossSyllablesOfferTheMeantPhrase() throws {
        let session = try session()
        for (typed, meant) in [("shenem", "什么"), ("keiy", "可以"), ("gongzo", "工作")] {
            _ = session.type(typed)
            waitUntilCurrent(session)
            let shown = corrections(session)
            XCTAssertTrue(shown.contains { $0.text == meant }, "\(typed): \(session.candidatePresentations.map(\.text))")
            let index = try XCTUnwrap(session.candidatePresentations.firstIndex { $0.text == meant && $0.source == .typoCorrection })
            XCTAssertTrue((1...2).contains(index), "corrections never come first: \(index)")
            XCTAssertEqual(session.candidatePresentations.filter { $0.text == meant }.count, 1, "shown once")
            XCTAssertEqual(session.chooseCandidate(try XCTUnwrap(session.candidatePresentations[index].selectionToken)), [])
            waitUntilCurrent(session)
            XCTAssertEqual(batches.last?.edits, [.insert(meant)])
            XCTAssertFalse(session.isComposing)
        }
        // Editing the input drops them with Rime's next answer.
        _ = session.type("shenem")
        waitUntilCurrent(session)
        XCTAssertFalse(corrections(session).isEmpty)
        _ = session.backspace()
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "shene")
        XCTAssertTrue(corrections(session, within: 0.4).isEmpty, "\(session.candidatePresentations.map(\.text))")
        session.reset()

        // Unfinished and correct spellings get none.
        for typed in ["nihaom", "zhongg", "shenme", "nihao"] {
            _ = session.type(typed)
            waitUntilCurrent(session)
            XCTAssertTrue(corrections(session, within: 0.5).isEmpty, typed)
            session.reset()
        }
    }

    func testResetDropsPendingWorkAndMovesTheEpoch() throws {
        let session = try session()
        let epoch = session.hostEpoch
        _ = session.type("nihao")
        session.reset()
        XCTAssertEqual(session.hostEpoch, epoch + 1)
        XCTAssertNil(session.markedText)
        waitUntilCurrent(session)
        XCTAssertFalse(session.isComposing, "results from before the reset are discarded")
        XCTAssertTrue(session.candidatePresentations.isEmpty)
        session.reset(preservingContext: true)
        XCTAssertEqual(session.hostEpoch, epoch + 1)
    }

    func testEnglishConfirmsAndTypesLetters() throws {
        let session = try session()
        _ = session.type("zhongwen")
        let epoch = session.hostEpoch
        XCTAssertEqual(session.toggleEnglish(), [.insert("中文")])
        XCTAssertEqual(session.inputTraits.language, .english)
        XCTAssertGreaterThan(session.hostEpoch, epoch)
        XCTAssertEqual(session.type("A"), [.insert("A")])
        XCTAssertEqual(session.inputTraits.comma, ",")
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertEqual(session.inputTraits.language, .chinese)
        XCTAssertEqual(session.inputTraits.comma, "，")
    }

    func testExpandedPanelGetsALongerList() throws {
        let session = try session()
        _ = session.type("shi")
        waitUntilCurrent(session)
        XCTAssertEqual(session.candidateCount, ChineseInputSession.collapsedCandidateLimit)
        session.setExpandedCandidates(true)
        waitUntilCurrent(session)
        XCTAssertGreaterThan(session.candidateCount, ChineseInputSession.collapsedCandidateLimit)
        let beyond = session.candidatePage(offset: ChineseInputSession.collapsedCandidateLimit, limit: 5)
        XCTAssertFalse(beyond.isEmpty)
        XCTAssertEqual(beyond.first?.selectionToken?.index, ChineseInputSession.collapsedCandidateLimit)
        session.reset()
    }

    func testKeyboardViewAppliesAsynchronousCommits() throws {
        let session = try session()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        keyboard.layoutIfNeeded()
        var edits: [KeyboardEdit] = []
        var preedits: [String?] = []
        keyboard.onEdit = { edits += $0 }
        keyboard.onPreeditChange = { preedits.append($0?.text) }
        keyboard.apply(session.type("nihao"))
        XCTAssertEqual(preedits.last, "nihao")
        waitUntilCurrent(session)
        XCTAssertEqual(preedits.last, "ni\u{2006}hao", "syllables are joined by a narrow space, not a full one")
        let button = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "候选词：你好" && $0.isUserInteractionEnabled })
        button.sendActions(for: .touchUpInside)
        waitUntilCurrent(session)
        XCTAssertEqual(edits, [.insert("你好")])
        XCTAssertEqual(preedits.last, .some(nil))
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
