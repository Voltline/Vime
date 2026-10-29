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

    func testApostropheEndsNBeforeAVowel() {
        for (raw, preedit, word) in [("kan'i", "かんい", "簡易"), ("shin'you", "しんよう", "信用"), ("gen'in", "げんいn", "原因")] {
            let session = KeyboardSession(memoryDirectoryURL: isolatedLearningDirectory())
            for c in raw { _ = session.type(String(c)) }
            XCTAssertEqual(session.preedit, preedit)
            XCTAssertTrue(session.candidates.prefix(5).contains(word), "\(raw): \(session.candidates.prefix(5))")
        }
        let session = KeyboardSession(memoryDirectoryURL: isolatedLearningDirectory())
        _ = session.type("kan"); _ = session.type("'")
        XCTAssertEqual(session.preedit, "かん")
        _ = session.backspace()
        XCTAssertEqual(session.preedit, "か", "Deleting ん removes the n and its apostrophe")
        session.reset(); _ = session.type("ka'")
        XCTAssertEqual(session.preedit, "か'", "An apostrophe after other kana stays literal")
    }

    func testTrailingNReadsAsNWhileTyping() {
        for (raw, word) in [("nihon", "日本"), ("hon", "本"), ("ten", "天"), ("jikan", "時間"),
                            ("watashinohon", "私の本"), ("gohan", "ご飯")] {
            let session = KeyboardSession(memoryDirectoryURL: isolatedLearningDirectory())
            for c in raw { _ = session.type(String(c)) }
            let shown = session.candidateSnapshots
            XCTAssertTrue(shown.prefix(5).contains { $0.text == word }, "\(raw): \(shown.prefix(5).map(\.text))")
            for value in shown {
                // English and symbol forms are fine; にほn or 手n is the unresolved n.
                XCTAssertFalse(value.text.contains { !$0.isASCII } && value.text.contains { $0.isASCII && $0.isLetter },
                               "\(raw): \(value.text)")
                XCTAssertFalse(value.remainingComposition.convertTarget.contains { $0.isASCII }, "\(raw): \(value.text)")
            }
            XCTAssertTrue(session.preedit?.hasSuffix("n") ?? false, "The live preedit keeps the editable n")
            guard case .insert(let text)? = session.choose(0).first else { return XCTFail(raw) }
            XCTAssertFalse(text.contains("n"), "\(raw): \(text)")
        }
        let session = KeyboardSession(memoryDirectoryURL: isolatedLearningDirectory())
        _ = session.type("nihon"); _ = session.type("a")
        XCTAssertEqual(session.preedit, "にほな", "A following vowel still makes な-row kana")
    }
}
