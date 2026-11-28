import XCTest

@MainActor
final class KoreanInputSessionTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("KoreanTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeSession(
        exclusions: LearningExclusionList = LearningExclusionList(data: Data()),
        exclusionsApply: @escaping () -> Bool = { false },
        blocklist: LearningExclusionList = PredictionBlocklist.korean
    ) -> KoreanInputSession {
        let learning = KoreanPersonalLearningStore(directory: tempDir)
        return KoreanInputSession(
            lexicon: KoreanLexicon.shared,
            learning: learning,
            exclusions: exclusions,
            exclusionsApply: exclusionsApply,
            blocklist: blocklist
        )
    }

    func testTypeSpaceBackspaceEnterAndConfirm() {
        let session = makeSession()
        XCTAssertEqual(session.inputTraits.language, .korean)
        XCTAssertEqual(session.type("ㅎ"), [])
        XCTAssertEqual(session.type("ㅏ"), [])
        XCTAssertEqual(session.type("ㄴ"), [])
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(session.markedText?.text, "한")

        // Space commits composed word + ASCII space.
        XCTAssertEqual(session.space(), [.insert("한 ")])
        XCTAssertFalse(session.isComposing)
        XCTAssertNil(session.markedText)

        // Backspace outside composition deletes one whole committed character in host.
        XCTAssertEqual(session.backspace(), [.deleteBackward])

        // Enter commits composed word + returnKey.
        _ = session.type("ㄱ")
        _ = session.type("ㅏ")
        XCTAssertEqual(session.enter(), [.insert("가"), .returnKey])
        XCTAssertFalse(session.isComposing)

        // Confirm commits without space or return.
        _ = session.type("ㄴ")
        _ = session.type("ㅏ")
        XCTAssertEqual(session.confirm(), [.insert("나")])
        XCTAssertFalse(session.isComposing)
    }

    func testWordCompletionAndChooseCandidateAppendsSpace() throws {
        let session = makeSession()
        // Type partial jamo for 학교 (ㅎㅏㄱㄱ)
        for ch in ["ㅎ", "ㅏ", "ㄱ", "ㄱ"] {
            _ = session.type(ch)
        }
        XCTAssertEqual(session.markedText?.text, "학ㄱ")
        let titles = session.candidatePresentations.map(\.text)
        XCTAssertTrue(titles.contains("학교"), "Expected 학교 in completions, got \(titles)")

        let token = try XCTUnwrap(session.candidatePresentations.first(where: { $0.text == "학교" })?.selectionToken)
        let edits = session.chooseCandidate(token)
        XCTAssertEqual(edits, [.insert("학교 ")])
        XCTAssertFalse(session.isComposing)
        XCTAssertNil(session.markedText)
    }

    func testStemAndParticleCompletions() {
        let session = makeSession()
        // Complete noun stem: 학교 -> 학교에, 학교에서, 학교는, 학교를
        for ch in HangulComposer.decomposeToJamo("학교") {
            _ = session.type(String(ch))
        }
        let titles = session.candidatePresentations.map(\.text)
        XCTAssertTrue(titles.contains("학교에") || titles.contains("학교에서") || titles.contains("학교는"),
                      "Expected particle completions for 학교, got \(titles)")

        // Partial particle jamo: 학교 + ㅇㅔㅅ -> 학교에서
        _ = session.type("ㅇ")
        _ = session.type("ㅔ")
        _ = session.type("ㅅ")
        let partialTitles = session.candidatePresentations.map(\.text)
        XCTAssertTrue(partialTitles.contains("학교에서"), "Expected 학교에서, got \(partialTitles)")
    }

    func testNextWordBigramSuggestionsAfterCommit() {
        let session = makeSession()
        for ch in HangulComposer.decomposeToJamo("안녕히") {
            _ = session.type(String(ch))
        }
        _ = session.space()
        let nextWords = session.stripPresentations.map(\.text)
        XCTAssertTrue(nextWords.contains("계세요") || nextWords.contains("가세요"),
                      "Expected next-word bigram after 안녕히, got \(nextWords)")
    }

    func testPersonalLearningAndExclusionAndBlocklist() {
        let exclusionData = LearningExclusionList.encode(blocked: ["비밀단어"], allowed: [])
        let exclusions = LearningExclusionList(data: exclusionData)
        let learning = KoreanPersonalLearningStore(directory: tempDir)
        let session = KoreanInputSession(
            lexicon: KoreanLexicon.shared,
            learning: learning,
            exclusions: exclusions,
            exclusionsApply: { true },
            blocklist: PredictionBlocklist.korean
        )

        // Learn a normal word.
        for ch in HangulComposer.decomposeToJamo("바이미테스트") { _ = session.type(String(ch)) }
        _ = session.space()
        XCTAssertTrue(learning.isLearned("바이미테스트"))

        // Excluded word must not be learned.
        for ch in HangulComposer.decomposeToJamo("비밀단어") { _ = session.type(String(ch)) }
        _ = session.space()
        XCTAssertFalse(learning.isLearned("비밀단어"))

        // Blocked word must not be learned or suggested.
        for ch in HangulComposer.decomposeToJamo("시발") { _ = session.type(String(ch)) }
        _ = session.space()
        XCTAssertFalse(learning.isLearned("시발"))
    }

    func testJamoLevelErrorCorrectionWithoutAutoRewrite() {
        let session = makeSession()
        // Adjacent transposition typo: ㅎㄴㅏㄱㅜㄱ instead of ㅎㅏㄴㄱㅜㄱ (한국)
        for ch in ["ㅎ", "ㄴ", "ㅏ", "ㄱ", "ㅜ", "ㄱ"] {
            _ = session.type(ch)
        }
        // Marked text must NOT be auto-rewritten.
        XCTAssertEqual(session.markedText?.text, "ㅎ나국")
        let titles = session.candidatePresentations.map(\.text)
        XCTAssertTrue(titles.contains("한국"), "Expected typo correction 한국, got \(titles)")

        // Space still commits user's typed text (never silently rewrites).
        XCTAssertEqual(session.space(), [.insert("ㅎ나국 ")])
    }

    func testValidWordDoesNotTriggerRedundantCorrection() {
        let validWords = ["안녕하세요", "감사합니다", "학교", "학교에서", "시간", "친구", "오늘", "내일"]
        for word in validWords {
            let jamos = HangulComposer.decomposeToJamo(word)
            let corrections = KoreanErrorCorrector.corrections(
                for: word,
                jamos: jamos,
                lexicon: KoreanLexicon.shared
            )
            XCTAssertTrue(corrections.isEmpty, "Valid word \(word) should not trigger corrections: \(corrections)")
        }
    }

    func testShortPrefixCompletionsIncludeGlobalTopFrequencyWords() {
        let session = makeSession()

        // 1-jamo prefix ㄱ (4819 matches): top 3 must include 감사합니다.
        _ = session.type("ㄱ")
        let topG = Array(session.candidatePresentations.prefix(3).map(\.text))
        XCTAssertTrue(topG.contains("감사합니다"), "Expected 감사합니다 in top 3 for ㄱ, got \(topG)")

        // 2-jamo prefix ㅇㅣ: top 3 must include 있다.
        session.reset()
        _ = session.type("ㅇ")
        _ = session.type("ㅣ")
        let topI = Array(session.candidatePresentations.prefix(3).map(\.text))
        XCTAssertTrue(topI.contains("있다"), "Expected 있다 in top 3 for ㅇㅣ, got \(topI)")
    }

    func testOOVWordRequiresTwoUsesBeforeRankingFirst() {
        let learning = KoreanPersonalLearningStore(directory: tempDir)
        let session = KoreanInputSession(
            lexicon: KoreanLexicon.shared,
            learning: learning,
            exclusions: LearningExclusionList(data: Data()),
            exclusionsApply: { false },
            blocklist: PredictionBlocklist.korean
        )
        let oovWord = "학교바이미"
        XCTAssertNil(KoreanLexicon.shared.exactMatch(surface: oovWord))

        // Commit OOV word once: must NOT rank first for prefix 학교.
        for ch in HangulComposer.decomposeToJamo(oovWord) { _ = session.type(String(ch)) }
        _ = session.space()
        for ch in HangulComposer.decomposeToJamo("학교") { _ = session.type(String(ch)) }
        XCTAssertNotEqual(session.candidatePresentations.first?.text, oovWord,
                          "Single-use OOV word must not rank #1 ahead of lexicon words")
        session.reset()

        // Commit OOV word a second time: now ranks #1 for prefix 학교.
        for ch in HangulComposer.decomposeToJamo(oovWord) { _ = session.type(String(ch)) }
        _ = session.space()
        for ch in HangulComposer.decomposeToJamo("학교") { _ = session.type(String(ch)) }
        XCTAssertEqual(session.candidatePresentations.first?.text, oovWord,
                       "OOV word used twice should rank #1")
    }

    func testImmediateLineDeletionDoesNotLearnCommittedWord() {
        let learning = KoreanPersonalLearningStore(directory: tempDir)
        let session = KoreanInputSession(
            lexicon: KoreanLexicon.shared,
            learning: learning,
            exclusions: LearningExclusionList(data: Data()),
            exclusionsApply: { false },
            blocklist: PredictionBlocklist.korean
        )

        // Commit via Space, then immediately delete line -> reverted from learning store.
        for ch in HangulComposer.decomposeToJamo("오타테스트") { _ = session.type(String(ch)) }
        _ = session.space()
        session.didApplyEdits([.deleteToLineStart])
        XCTAssertFalse(learning.isLearned("오타테스트"))
        XCTAssertEqual(learning.frequency(of: "오타테스트"), 0)

        // Composing word confirmed right before line delete -> also reverted.
        for ch in HangulComposer.decomposeToJamo("삭제테스트") { _ = session.type(String(ch)) }
        let edits = session.confirmAll()
        session.didApplyEdits(edits + [.deleteToLineStart])
        XCTAssertFalse(learning.isLearned("삭제테스트"))
    }

    func testResetIDDoesNotLoadLearningStoreWhenKoreanIsUnused() {
        let learning = KoreanPersonalLearningStore(directory: tempDir)
        XCTAssertFalse(learning.isLoaded)
        learning.applyResetIfNeeded(resetID: "reset-id-1")
        XCTAssertFalse(learning.isLoaded, "Applying resetID must not load Korean learning store while inactive")
    }

    func testReleaseLanguageModelsUnmapsLexicon() {
        let session = makeSession()
        _ = session.type("ㅎ")
        XCTAssertTrue(KoreanLexicon.shared.isLoaded)
        session.releaseLanguageModels()
        XCTAssertFalse(KoreanLexicon.shared.isLoaded)
    }
}
