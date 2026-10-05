import XCTest

@MainActor
final class KeyboardPredictionTests: XCTestCase {
    func testEveryRomanKeyRequestsPredictionIncludingUnresolvedSuffix() async {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        let first = expectation(description: "nani")
        session.onCandidatesChange = { first.fulfill() }
        for c in "nani" { _ = session.type(String(c)) }
        XCTAssertEqual(session.candidateRequestCount, 4)
        XCTAssertEqual(session.preedit, "なに")
        await fulfillment(of: [first], timeout: 10)
        XCTAssertEqual(session.candidates.first, "何")
        let second = expectation(description: "nanim request completes without a vowel")
        session.onCandidatesChange = { second.fulfill() }
        _ = session.type("m")
        XCTAssertEqual(session.candidateRequestCount, 5)
        XCTAssertEqual(session.preedit, "なにm")
        XCTAssertFalse(session.candidatesAreCurrent)
        await fulfillment(of: [second], timeout: 10)
        XCTAssertTrue(session.candidatesAreCurrent)
        XCTAssertTrue(session.candidates.contains("何も"))
        XCTAssertEqual(session.candidates.first, "何も")
        let third = expectation(description: "nanimo")
        session.onCandidatesChange = { third.fulfill() }
        _ = session.type("o")
        XCTAssertEqual(session.candidateRequestCount, 6)
        XCTAssertEqual(session.preedit, "なにも")
        await fulfillment(of: [third], timeout: 10)
        XCTAssertEqual(session.candidates.first, "何も")
        let deleted = expectation(description: "Kana backspace requests prediction immediately")
        session.onCandidatesChange = { deleted.fulfill() }
        _ = session.backspace()
        XCTAssertEqual(session.preedit, "なに")
        XCTAssertEqual(session.candidateRequestCount, 7)
        XCTAssertFalse(session.candidatesAreCurrent)
        await fulfillment(of: [deleted], timeout: 10)
        XCTAssertEqual(session.candidates.first, "何")
        session.onCandidatesChange = nil
    }

    func testCandidateMetadataAndPartialConsumption() {
        let session = KeyboardSession()
        _ = session.type("naniwo")
        let partial = session.candidateSnapshots.firstIndex { $0.text == "何" }
        XCTAssertNotNil(partial)
        if let partial {
            let snapshot = session.candidateSnapshots[partial]
            XCTAssertEqual(snapshot.source, .conversion)
            XCTAssertEqual(snapshot.candidate.data.map(\.ruby).joined(), "ナニ")
            XCTAssertEqual(snapshot.remainingComposition.convertTarget, "を")
            XCTAssertEqual(snapshot.revision, session.revision)
            XCTAssertEqual(session.choose(partial), [.insert("何")])
            XCTAssertEqual(session.preedit, "を")
            XCTAssertEqual(session.enter(), [.insert("を")])
        }
        _ = session.type("nanim")
        if let index = session.candidateSnapshots.firstIndex(where: { $0.text == "何も" }) {
            let snapshot = session.candidateSnapshots[index]
            XCTAssertEqual(snapshot.source, .prediction)
            XCTAssertEqual(snapshot.candidate.data.map(\.ruby).joined(), "ナニモ")
            XCTAssertTrue(snapshot.remainingComposition.isEmpty)
            XCTAssertEqual(session.choose(index), [.insert("何も")])
            XCTAssertNil(session.preedit, "Predicted completion also consumes the unresolved m")
        } else { XCTFail("Missing unresolved suffix prediction") }
        _ = session.type("kan")
        XCTAssertEqual(session.preedit, "かn")
        _ = session.space()
        XCTAssertFalse(session.selectedText?.contains("n") ?? true)
        _ = session.backspace()
        XCTAssertEqual(session.preedit, "かn", "Canceling conversion restores editable n")
        _ = session.type("a")
        XCTAssertEqual(session.preedit, "かな")
    }

    func testPredictionRankingAndBackspaceBranches() {
        let session = KeyboardSession()
        for (raw, expected) in [("nani", "何"), ("nanim", "何も"), ("nanimo", "何も"),
                                ("arigat", "ありがとう"), ("arigato", "ありがとう")] {
            session.reset()
            for c in raw { _ = session.type(String(c)) }
            XCTAssertTrue(session.candidates.contains(expected), raw)
            if raw.hasPrefix("nani") { XCTAssertEqual(session.candidates.first, expected, raw) }
            XCTAssertTrue(session.candidateSnapshots.allSatisfy { $0.revision == session.revision })
        }
        session.reset(); _ = session.type("nanimo")
        _ = session.backspace()
        XCTAssertEqual(session.preedit, "なに", "A completed も is deleted as one kana, not restored to m")
        session.reset(); _ = session.type("nanim")
        _ = session.backspace()
        XCTAssertEqual(session.preedit, "なに", "An unresolved m is deleted immediately")
        XCTAssertEqual(session.candidates.first, "何")
    }

    func testDoubleNCandidatesUseCorrectReading() {
        let session = KeyboardSession()
        for (raw, literal, kana) in [("kanna", "かんあ", "かんな"), ("konnichiha", "こんいちは", "こんにちは")] {
            session.reset(); _ = session.type(raw)
            XCTAssertEqual(session.preedit, literal)
            XCTAssertTrue(session.candidates.contains(kana))
            let reading = RomajiConverter.katakana(kana)
            XCTAssertTrue(session.candidateSnapshots.contains {
                $0.source == .readingAlternative && $0.remainingComposition.isEmpty
                    && $0.candidate.data.map(\.ruby).joined() == reading
            }, "Full conversion must have the correct reading: \(raw)")
        }
    }
}
