import XCTest

@MainActor
final class KeyboardPreeditTests: XCTestCase {
    func testKanaPreeditAndAmbiguousRomanSuffixes() {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        for (raw, preedit) in [("nihongo", "にほんご"), ("n", "n"), ("nn", "ん"),
                               ("na", "な"), ("nya", "にゃ"), ("kan", "かn"),
                               ("kanna", "かんあ"), ("konnichiha", "こんいちは"),
                               ("kannya", "かんや"), ("sonnna", "そんな"),
                               ("gakkou", "がっこう"), ("nanim", "なにm")] {
            session.reset()
            for c in raw { XCTAssertTrue(session.type(String(c)).isEmpty) }
            XCTAssertEqual(session.preedit, preedit)
            XCTAssertEqual(session.raw, raw)
        }
        session.reset(); _ = session.type("n")
        XCTAssertEqual(session.enter(), [.insert("ん")])
        XCTAssertNil(session.preedit)
        _ = session.type("kan"); _ = session.type("a")
        XCTAssertEqual(session.preedit, "かな", "Prediction must not freeze ambiguous n")
        _ = session.toggleKana(); XCTAssertEqual(session.preedit, "カナ")
        _ = session.toggleKana(); XCTAssertEqual(session.preedit, "かな")
        _ = session.backspace(); XCTAssertEqual(session.preedit, "か")
        XCTAssertEqual(session.toggleEnglish(), [.insert("か")])
        XCTAssertNil(session.preedit)
        XCTAssertEqual(session.type("Hello"), [.insert("Hello")])
    }

    func testDoubleNBatchInsertionAndKanaDeletion() {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        for (raw, kana) in [("kanna", "かんあ"), ("konnichiha", "こんいちは"), ("kannya", "かんや")] {
            session.reset(); _ = session.type(raw)
            XCTAssertEqual(session.preedit, kana)
            XCTAssertEqual(session.raw, raw)
        }
        session.reset(); _ = session.type("kanna")
        _ = session.backspace(); XCTAssertEqual(session.preedit, "かん")
        _ = session.backspace(); XCTAssertEqual(session.preedit, "か")
        session.reset(); _ = session.type("kan"); _ = session.type("ya")
        XCTAssertEqual(session.preedit, "かにゃ", "Trailing single n remains editable")
    }
}
