import XCTest
import UIKit

@MainActor
final class VimeAuditRegressionTests: XCTestCase {
    func testSuggestionsAppearWhenHostAcknowledgesCommittedText() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.phraseSuggestions = true
        var before = ""
        session.leftContextProvider = { before }
        let candidates = expectation(description: "candidates")
        var delivered = false
        session.onCandidatesChange = {
            if session.candidatesAreCurrent && !delivered { delivered = true; candidates.fulfill() }
        }
        _ = session.type("ekini")
        await fulfillment(of: [candidates], timeout: 10)
        let index = try XCTUnwrap(session.candidates.firstIndex(of: "駅に"))
        let suggestions = expectation(description: "suggestions with current host context")
        var suggested = false
        session.onCandidatesChange = {
            if !session.suggestions.isEmpty && !suggested { suggested = true; suggestions.fulfill() }
        }
        let edits = session.choose(index)
        for edit in edits { if case let .insert(text) = edit { before += text } }
        await fulfillment(of: [suggestions], timeout: 10)
        session.onCandidatesChange = nil
        XCTAssertFalse(session.suggestions.isEmpty)
    }

    func testTwoQueuedSpacesOnResolvedReadingAdvanceTwice() async {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.updateIntelligence(ranking: .engine, suggestionsEnabled: false)
        let ready = expectation(description: "resolved candidates")
        var delivered = false
        session.onCandidatesChange = {
            if session.candidatesAreCurrent && !delivered { delivered = true; ready.fulfill() }
        }
        _ = session.type("nihongo")
        _ = session.space()
        _ = session.space()
        await fulfillment(of: [ready], timeout: 10)
        session.onCandidatesChange = nil
        XCTAssertEqual(session.selectedIndex, 1)
    }

    func testLineDeletionAtLineStartStillDeletesSelection() {
        let view = UITextView()
        view.text = "selectedsuffix"
        view.selectedRange = NSRange(location: 0, length: 8)
        XCTAssertEqual(KeyboardTextNavigation.deleteLinePrefix(in: view), "selected")
        XCTAssertEqual(view.text, "suffix")
    }

    func testTwoQueuedSpacesAfterUnresolvedNAdvanceToSecondCandidate() async {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.updateIntelligence(ranking: .engine, suggestionsEnabled: false)
        let ready = expectation(description: "boundary candidates")
        var delivered = false
        session.onCandidatesChange = {
            if session.candidatesAreCurrent && !delivered { delivered = true; ready.fulfill() }
        }
        _ = session.type("kan")
        _ = session.space()
        _ = session.space()
        await fulfillment(of: [ready], timeout: 10)
        session.onCandidatesChange = nil
        XCTAssertGreaterThan(session.candidates.count, 1)
        XCTAssertEqual(session.selectedIndex, 1, "Two spaces should advance twice, as they do for a resolved reading")
    }

    func testCancellingQueuedConversionRestoresUsableCandidates() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.updateIntelligence(ranking: .engine, suggestionsEnabled: false)
        _ = session.type("nihongo")
        _ = session.space()
        let cancelledRevision = session.revision
        let ready = expectation(description: "cancelled session restores its own candidates")
        var delivered = false
        session.onCandidatesChange = {
            if session.candidatesAreCurrent && !delivered { delivered = true; ready.fulfill() }
        }
        _ = session.backspace()
        XCTAssertGreaterThan(session.revision, cancelledRevision)
        session.acceptCandidateUpdate([], revision: cancelledRevision, supplementary: false)
        XCTAssertFalse(session.candidatesAreCurrent, "A cancelled result cannot mark the replacement query complete")
        await fulfillment(of: [ready], timeout: 10)
        session.onCandidatesChange = nil
        XCTAssertEqual(session.preedit, "にほんご")
        XCTAssertNil(session.selectedIndex)
        XCTAssertTrue(session.candidatesAreCurrent, "Cancelling conversion must not leave a permanently pending request")
        XCTAssertFalse(session.candidates.isEmpty)
        let japanese = try XCTUnwrap(session.candidates.firstIndex(of: "日本語"))
        XCTAssertEqual(session.chooseStrip(japanese), [.insert("日本語")])
        XCTAssertNil(session.preedit)
    }

    func testLiveLearningWritersPreserveEachOthersAcceptedEvidence() throws {
        let directory = isolatedLearningDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CandidatePreferenceMemory(directory: directory)
        let second = CandidatePreferenceMemory(directory: directory)
        for _ in 0..<3 { first.record(reading: "ハシ", surface: "橋") }
        first.flush()
        XCTAssertGreaterThan(CandidatePreferenceMemory(directory: directory).score(reading: "ハシ", surface: "橋"), 0)
        for _ in 0..<3 { second.record(reading: "ネコ", surface: "猫") }
        second.flush()
        let restored = CandidatePreferenceMemory(directory: directory)
        XCTAssertGreaterThan(restored.score(reading: "ハシ", surface: "橋"), 0, "A stale writer must not replace another writer's accepted evidence")
        XCTAssertGreaterThan(restored.score(reading: "ネコ", surface: "猫"), 0)
    }
}
