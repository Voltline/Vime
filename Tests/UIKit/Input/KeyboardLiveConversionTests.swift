import XCTest

@MainActor
final class KeyboardLiveConversionTests: XCTestCase {
    private func session(live: Bool = true) -> KeyboardSession {
        let session = KeyboardSession(memoryDirectoryURL: isolatedLearningDirectory())
        session.setLiveConversion(live)
        return session
    }

    func testOffKeepsTheKanaPreeditAndCommit() {
        let session = session(live: false)
        for c in "toukyou" { _ = session.type(String(c)) }
        XCTAssertEqual(session.preedit, "とうきょう")
        XCTAssertEqual(session.enter(), [.insert("とうきょう")])
    }

    func testPreeditShowsTheFirstCandidateAndReturnCommitsIt() {
        let session = session()
        for c in "toukyou" { _ = session.type(String(c)) }
        XCTAssertEqual(session.preedit, "東京")
        XCTAssertEqual(session.candidateSnapshots.first?.text, "東京", "The strip leads with the preedit")
        XCTAssertNil(session.selectedIndex)
        XCTAssertEqual(session.enter(), [.insert("東京")])
        XCTAssertFalse(session.isComposing)
        XCTAssertEqual(session.reconvertibleCommit?.text, "東京", "↩ still offers the reading")
        XCTAssertEqual(session.reconvertCommit(), [.deleteBackward, .deleteBackward])
        XCTAssertEqual(session.preedit, "東京", "The restored reading shows its conversion")
    }

    func testSpaceMovesPastTheShownConversionAndBackspaceReturns() {
        let session = session()
        for c in "toukyou" { _ = session.type(String(c)) }
        XCTAssertGreaterThan(session.candidateSnapshots.count, 1)
        _ = session.space()
        XCTAssertEqual(session.selectedIndex, 1, "Space picks the next candidate")
        XCTAssertEqual(session.preedit, session.candidateSnapshots[1].text
            + PreeditPresentation.kana(for: session.candidateSnapshots[1].remainingComposition, mode: .hiragana))
        _ = session.backspace()
        XCTAssertNil(session.selectedIndex)
        XCTAssertEqual(session.preedit, "東京")
        _ = session.space(); _ = session.space()
        let chosen = session.candidateSnapshots[2].text
        XCTAssertEqual(session.enter().first, .insert(chosen))
    }

    func testTypingAfterASelectionCommitsItFirst() {
        let session = session()
        for c in "toukyou" { _ = session.type(String(c)) }
        _ = session.space()
        let chosen = session.candidateSnapshots[1].text
        XCTAssertEqual(session.type("e"), [.insert(chosen)])
        XCTAssertEqual(session.composition, "え")
    }

    func testOnlyWholeExactConversionsDriveThePreedit() {
        let session = session()
        for raw in ["toukyou", "nihongo", "kyouhaiitenki", "toukyoi", "arigatou"] {
            session.reset()
            for c in raw { _ = session.type(String(c)) }
            for value in session.candidateSnapshots where value.isPrediction || value.correction != nil || !value.fullConsumption {
                XCTAssertFalse(KeyboardSession.isLiveCandidate(value), "\(raw): \(value.text)")
            }
            if let first = session.candidateSnapshots.first, KeyboardSession.isLiveCandidate(first) {
                XCTAssertEqual(session.preedit, first.text, raw)
            }
            XCTAssertFalse(session.candidateSnapshots.dropFirst().contains(where: KeyboardSession.isLiveCandidate)
                && !KeyboardSession.isLiveCandidate(session.candidateSnapshots[0]), "\(raw): the best live conversion leads")
        }
    }

    func testTrailingNShowsItsConversion() {
        let session = session()
        for c in "nihon" { _ = session.type(String(c)) }
        XCTAssertEqual(session.preedit, "日本")
        XCTAssertEqual(session.composition, "にほn", "The n stays editable underneath")
        XCTAssertEqual(session.enter(), [.insert("日本")])
        for c in "nihona" { _ = session.type(String(c)) }
        XCTAssertEqual(session.composition, "にほな", "A vowel still makes な")
        XCTAssertFalse(session.preedit?.contains("n") ?? true, session.preedit ?? "")
    }

    func testAnUnresolvedConsonantFollowsTheKnownConversion() throws {
        let session = session()
        for c in "toukyou" { _ = session.type(String(c)) }
        _ = session.type("t")
        let first = try XCTUnwrap(session.candidateSnapshots.first)
        try XCTSkipIf(KeyboardSession.isLiveCandidate(first), "The engine resolved the consonant")
        XCTAssertEqual(session.preedit, "東京t")
        XCTAssertEqual(session.enter(), [.insert("東京t")], "Return commits what is shown")
    }

    func testKatakanaModeIsNotConverted() {
        let session = session()
        _ = session.toggleKana()
        for c in "toukyou" { _ = session.type(String(c)) }
        XCTAssertEqual(session.preedit, "トウキョウ")
        XCTAssertEqual(session.enter(), [.insert("トウキョウ")])
    }

    func testRangeControlsShowTheirUnitAndReturnCommitsIt() throws {
        let session = session()
        for c in "watashinonamae" { _ = session.type(String(c)) }
        session.adjustConversionRange(by: -1)
        let first = try XCTUnwrap(session.candidateSnapshots.first)
        XCTAssertFalse(first.fullConsumption)
        let rest = PreeditPresentation.kana(for: first.remainingComposition, mode: .hiragana)
        XCTAssertEqual(session.preedit, first.text + rest)
        XCTAssertEqual(session.enter(), [.insert(first.text)])
        XCTAssertEqual(session.composition, rest)
    }

    func testTurningItOffRestoresTheKanaPreedit() {
        let session = session()
        for c in "toukyou" { _ = session.type(String(c)) }
        XCTAssertEqual(session.preedit, "東京")
        session.setLiveConversion(false)
        XCTAssertEqual(session.preedit, "とうきょう")
    }

    func testPendingResultsKeepTheLastConversion() async {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.candidateRanking = .engine
        session.setLiveConversion(true)
        var ready: XCTestExpectation?
        session.onCandidatesChange = {
            if session.candidatesAreCurrent, !session.candidateSnapshots.isEmpty { ready?.fulfill(); ready = nil }
        }
        func settle() async {
            let expectation = expectation(description: "current list")
            ready = expectation
            await fulfillment(of: [expectation], timeout: 10)
        }
        for c in "toukyou" { _ = session.type(String(c)) }
        await settle()
        XCTAssertEqual(session.preedit, "東京")
        _ = session.type("n")
        XCTAssertFalse(session.candidatesAreCurrent)
        XCTAssertEqual(session.preedit, "東京n", "New kana follow the last conversion until the result arrives")
        await settle()
        _ = session.backspace()
        XCTAssertEqual(session.preedit, "東京", "Deleting back to a known reading shows its conversion at once")
        await settle()
        XCTAssertEqual(session.preedit, "東京")
        _ = session.type("t")
        XCTAssertEqual(session.enter(), [.insert("東京t")], "Return before the result commits what is shown")
        XCTAssertFalse(session.isComposing)
    }
}
