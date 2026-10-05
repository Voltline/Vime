import XCTest

@MainActor
final class KeyboardNInterpretationTests: XCTestCase {
    func testLiteralPreeditKeepsOriginalNReading() {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        for (raw, kana) in [("renai", "れない"), ("rennai", "れんあい"),
                            ("konna", "こんあ"), ("konichiha", "こにちは"),
                            ("konnichiha", "こんいちは"), ("nn", "ん"),
                            ("na", "な"), ("nya", "にゃ")] {
            session.reset()
            for c in raw { _ = session.type(String(c)) }
            XCTAssertEqual(session.raw, raw)
            XCTAssertEqual(session.preedit, kana, raw)
        }
    }

    func testNAlternativesAreCandidatesNotInputRewrites() {
        let session = KeyboardSession()
        for (raw, kana, expected) in [("renai", "れない", "恋愛"), ("rennai", "れんあい", "恋愛"),
                                      ("konna", "こんあ", "こんな"), ("konichiha", "こにちは", "こんにちは"),
                                      ("konnichiha", "こんいちは", "こんにちは")] {
            session.reset(); _ = session.type(raw)
            print("N_READING \(raw) preedit=\(session.preedit ?? "") \(session.candidateSnapshots.prefix(8).map { "\($0.text):\($0.candidate.value):\($0.candidate.data.map(\.ruby).joined())" })")
            XCTAssertEqual(session.preedit, kana)
            XCTAssertTrue(session.candidates.contains(expected), raw)
            if raw != "renai" { XCTAssertEqual(session.candidates.first, expected, raw) }
            if let index = session.candidates.firstIndex(of: expected) {
                XCTAssertEqual(session.choose(index), [.insert(expected)])
                XCTAssertNil(session.preedit)
            }
        }
    }

    func testReturnConfirmsLiteralReadingWithoutSelectingCorrection() {
        let session = KeyboardSession()
        _ = session.type("konna")
        XCTAssertEqual(session.candidates.first, "こんな")
        XCTAssertEqual(session.enter(), [.insert("こんあ")])
        _ = session.type("rennai")
        XCTAssertEqual(session.enter(), [.insert("れんあい")])
    }
}
