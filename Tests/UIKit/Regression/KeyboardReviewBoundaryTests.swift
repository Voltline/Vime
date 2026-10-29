import XCTest
import UIKit

@MainActor
final class KeyboardReviewBoundaryTests: XCTestCase {
    private func ready(_ session: KeyboardSession) -> XCTestExpectation {
        let result = expectation(description: "real worker delivers the current revision")
        var delivered = false
        session.onCandidatesChange = {
            if session.candidatesAreCurrent && !delivered { delivered = true; result.fulfill() }
        }
        return result
    }

    func testTrailingNQueuesThreeSpacesWithoutRestartingBoundaryQuery() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.updateIntelligence(ranking: .engine, suggestionsEnabled: false)
        let result = ready(session)
        _ = session.type("kan")
        _ = session.space()
        let request = session.revision
        _ = session.space(); _ = session.space()
        XCTAssertEqual(session.revision, request)
        XCTAssertEqual(session.candidateRequestCount, 1, "The per-key query already reads the trailing n as ん")
        XCTAssertEqual(session.raw, "kan")
        XCTAssertEqual(session.composition, "かn", "The query boundary must not rewrite live input")
        await fulfillment(of: [result], timeout: 10)
        session.onCandidatesChange = nil
        XCTAssertGreaterThan(session.candidates.count, 2)
        XCTAssertEqual(session.selectedIndex, 2)
        XCTAssertFalse(try XCTUnwrap(session.selectedText).contains("n"))
        let selected = try XCTUnwrap(session.selectedText)
        XCTAssertEqual(session.enter(), [.insert(selected)])
        XCTAssertNil(session.preedit)
    }

    func testCancelledNBoundaryThenNewInputDropsQueuedSelectionAndOldResults() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.updateIntelligence(ranking: .engine, suggestionsEnabled: false)
        _ = session.type("kan"); _ = session.space(); _ = session.space()
        let oldRevision = session.revision
        XCTAssertEqual(session.backspace(), [])
        XCTAssertEqual(session.preedit, "かn")
        let result = ready(session)
        XCTAssertEqual(session.type("a"), [])
        session.acceptCandidateUpdate([], revision: oldRevision, supplementary: false)
        XCTAssertFalse(session.candidatesAreCurrent)
        await fulfillment(of: [result], timeout: 10)
        session.onCandidatesChange = nil
        XCTAssertEqual(session.raw, "kana")
        XCTAssertEqual(session.preedit, "かな")
        XCTAssertNil(session.selectedIndex)
        XCTAssertFalse(session.candidateSnapshots.isEmpty)
        XCTAssertTrue(session.candidateSnapshots.allSatisfy { $0.revision == session.revision })
        XCTAssertEqual(session.enter(), [.insert("かな")])
    }

    func testCancellingPublishedConversionRejectsItsTokenAndRecoversWithModelEnabled() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        let initial = ready(session)
        _ = session.type("nihongo")
        await fulfillment(of: [initial], timeout: 10)
        _ = session.space()
        XCTAssertNotNil(session.selectedIndex)
        let token = try XCTUnwrap(session.candidatePresentations.first?.selectionToken)
        let result = ready(session)
        XCTAssertEqual(session.backspace(), [])
        XCTAssertTrue(session.chooseCandidate(token).isEmpty)
        XCTAssertEqual(session.preedit, "にほんご")
        await fulfillment(of: [result], timeout: 10)
        session.onCandidatesChange = nil
        XCTAssertNil(session.selectedIndex)
        let index = try XCTUnwrap(session.candidates.firstIndex(of: "日本語"))
        XCTAssertEqual(session.chooseStrip(index), [.insert("日本語")])
    }

    func testLineDeletionHandlesEmojiCombiningMarksSelectedNewlineAndEmptyCaret() {
        let view = UITextView()
        let prefix = "前\n👨‍👩‍👧‍👦e\u{301}"
        let selected = "選択\n"
        view.text = prefix + selected + "後"
        view.selectedRange = NSRange(location: prefix.utf16.count, length: selected.utf16.count)
        XCTAssertEqual(KeyboardTextNavigation.deleteLinePrefix(in: view), "👨‍👩‍👧‍👦e\u{301}" + selected)
        XCTAssertEqual(view.text, "前\n後")
        XCTAssertEqual(view.selectedRange, NSRange(location: "前\n".utf16.count, length: 0))
        XCTAssertEqual(KeyboardTextNavigation.deleteLinePrefix(in: view), "")
        XCTAssertEqual(view.text, "前\n後")
        view.text = "前\n選択後"
        view.selectedRange = NSRange(location: "前\n".utf16.count, length: "選択".utf16.count)
        XCTAssertEqual(KeyboardTextNavigation.deleteLinePrefix(in: view), "選択")
        XCTAssertEqual(view.text, "前\n後")
        view.text = ""; view.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertEqual(KeyboardTextNavigation.deleteLinePrefix(in: view), "")
    }

    func testHostContextMismatchRejectsPublishedSuggestionWithoutEditing() throws {
        let session = KeyboardSession()
        session.phraseSuggestions = true
        var before = ""
        session.leftContextProvider = { before }
        _ = session.type("ekini")
        let index = try XCTUnwrap(session.candidates.firstIndex(of: "駅に"))
        XCTAssertEqual(session.choose(index), [.insert("駅に")])
        before = "駅に"
        let token = try XCTUnwrap(session.stripPresentations.first?.selectionToken, "Need an actual published suggestion to exercise rejection")
        before = "別の正文"
        XCTAssertEqual(session.chooseCandidate(token), [])
        XCTAssertTrue(session.suggestions.isEmpty)
        XCTAssertEqual(before, "別の正文")
    }
}
