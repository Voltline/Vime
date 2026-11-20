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
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertEqual(session.preedit, "か")
        XCTAssertEqual(session.type("Hello"), [.insert("ka"), .insert("Hello")])
        XCTAssertNil(session.preedit)
        XCTAssertTrue(session.suppressesEnglishCompletions)
    }

    func testToggleEnglishPreservesCandidatesAndCommitsRawOnTypingOrToggleBack() {
        let session = KeyboardSession(asynchronousCandidates: false, memoryDirectoryURL: isolatedLearningDirectory())
        // 1. Toggle to English keeps candidates; typing commits raw romaji + new letter and suppresses English completions.
        _ = session.type("nihon")
        XCTAssertEqual(session.preedit, "にほn")
        XCTAssertFalse(session.candidatePresentations.isEmpty)
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertEqual(session.inputTraits.language, .english)
        XCTAssertTrue(session.isComposing)
        XCTAssertFalse(session.candidatePresentations.isEmpty)
        XCTAssertEqual(session.type("a"), [.insert("nihon"), .insert("a")])
        XCTAssertFalse(session.isComposing)
        XCTAssertTrue(session.candidatePresentations.isEmpty)
        XCTAssertTrue(session.suppressesEnglishCompletions)
        XCTAssertEqual(session.type("b"), [.insert("b")])
        XCTAssertTrue(session.suppressesEnglishCompletions)
        XCTAssertEqual(session.space(), [.insert(" ")])
        XCTAssertFalse(session.suppressesEnglishCompletions)

        // 2. Backspace while in English keeps Japanese composing & candidates; Space commits first candidate.
        _ = session.toggleEnglish()
        _ = session.type("nihon")
        let firstBefore = session.candidatePresentations.first?.text
        XCTAssertNotNil(firstBefore)
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertEqual(session.backspace(), [])
        XCTAssertEqual(session.preedit, "にほ")
        XCTAssertFalse(session.candidatePresentations.isEmpty)
        let firstAfterBackspace = try! XCTUnwrap(session.candidatePresentations.first?.text)
        XCTAssertEqual(session.space(), [.insert(firstAfterBackspace)])
        XCTAssertFalse(session.isComposing)
        XCTAssertEqual(session.inputTraits.language, .english)

        // 3. Return commits directly while candidates are kept in English.
        _ = session.toggleEnglish()
        _ = session.type("kana")
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertEqual(session.enter(), [.insert("かな")])
        XCTAssertFalse(session.isComposing)

        // 4. Toggling back to Japanese while still composing commits raw romaji with no candidates left.
        _ = session.toggleEnglish()
        _ = session.type("tokyo")
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(session.toggleEnglish(), [.insert("tokyo")])
        XCTAssertEqual(session.inputTraits.language, .japanese)
        XCTAssertFalse(session.isComposing)
        XCTAssertTrue(session.candidatePresentations.isEmpty)

        // 5. Direct kana input (flick/9-key) followed by English typing commits the kana + letter.
        _ = session.type("こん")
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertEqual(session.type("a"), [.insert("こん"), .insert("a")])
        XCTAssertTrue(session.suppressesEnglishCompletions)
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
