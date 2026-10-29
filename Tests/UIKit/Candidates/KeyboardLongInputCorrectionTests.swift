import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

/// Typos inside long readings and stray l from the neighbouring ー key.
/// Every query uses the bundled conversion dictionary and the default budget.
@MainActor
final class KeyboardLongInputCorrectionTests: XCTestCase {
    private func query(_ raw: String) -> ComposingText {
        var value = ComposingText(); RomajiConverter.insert(raw, into: &value); return value
    }

    /// Unoptimized builds run the search 3–15× slower than the keyboard, so
    /// they check results without the deadline. Release runs keep the budget.
    private static let clock: () -> TimeInterval = {
#if DEBUG
        { 0 }
#else
        { ProcessInfo.processInfo.systemUptime }
#endif
    }()

    private func corrections(_ raw: String, engine: JapaneseCandidateEngine = JapaneseCandidateEngine()) -> [CandidateSnapshot] {
        let composition = query(raw)
        let base = engine.candidates(for: composition, revision: 1, includeCorrections: false)
        return engine.addingCorrections(to: base, for: composition, katakana: false, revision: 1, now: Self.clock)
    }

    func testLocalReadingMatchesWholeReconversion() {
        let inputs = ["hassoushimadu", "konnnichiha", "kitte", "shinnnyuu", "kannna", "ralmenn", "kolhilwonomu",
                      "nihongowobenkyoushimadu", "watashihanihongowobenkyoushiteimadu", "kyakkannteki", "onnnanoko"]
        var checked = 0
        for raw in inputs {
            for variant in KeyboardCorrectionVariants.generate(for: query(raw)) {
                guard let roman = variant.suggestion.correctedRomanInput else { continue }
                XCTAssertEqual(variant.reading, query(roman).convertTarget, "\(raw) → \(roman)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    func testLongSentenceGenerationFitsTheBudget() throws {
#if DEBUG
        throw XCTSkip("Timing is meaningful only in an optimized build (-configuration Release ENABLE_TESTABILITY=YES).")
#else
        _ = KeyboardCorrectionVariants.generate(for: query("nihongo")) // Load the Roman table once.
        let composition = query("kyouhashitsukanabashodebenkyoushimasu")
        let started = ProcessInfo.processInfo.systemUptime
        let variants = KeyboardCorrectionVariants.generate(for: composition)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertFalse(variants.isEmpty)
        XCTAssertLessThan(elapsed, JapaneseCandidateEngine.correctionBudgetSeconds / 4)
#endif
    }

    func testTypoNearTheEndOfLongInputIsCorrected() {
        let cases = [("hassoushimadu", "発送します"),
                     ("nihongowobenkyoushimadu", "日本語を勉強します"),
                     ("watashihanihongowobenkyoushiteimadu", "私は日本語を勉強しています"),
                     ("kyouhashitsukanabashodebenkyoushimasu", "今日は静かな場所で勉強します")]
        for (raw, expected) in cases {
            let engine = JapaneseCandidateEngine()
            let values = corrections(raw, engine: engine)
            XCTAssertTrue(values.contains { $0.text == expected && $0.source == .typoCorrection },
                          "\(raw): \(values.prefix(8).map(\.text)) \(engine.lastCorrectionMetrics)")
            // The best correction (a homophone may come first) is visible.
            let best = values.firstIndex { $0.source == .typoCorrection }
            XCTAssertLessThanOrEqual(best ?? .max, CandidateCorrectionPolicy.correctionDisplayRank, raw)
        }
    }

    /// One adjacent-key slip in the polite ending, across verb classes.
    func testPoliteEndingSlipAcrossVerbClasses() {
        let cases = [("shirabemadu", "調べます"), ("tabemadu", "食べます"), ("yomimadu", "読みます"), ("kakimadu", "書きます"),
                     ("okimadu", "起きます"), ("tsukaimadu", "使います"), ("oshiemadu", "教えます"), ("benkyoushimadu", "勉強します")]
        let engine = JapaneseCandidateEngine()
        for (raw, expected) in cases {
            let values = corrections(raw, engine: engine)
            let best = values.firstIndex { $0.source == .typoCorrection }
            XCTAssertTrue(values.contains { $0.text == expected && $0.source == .typoCorrection }, "\(raw): \(values.prefix(6).map(\.text))")
            XCTAssertLessThanOrEqual(best ?? .max, CandidateCorrectionPolicy.correctionDisplayRank, raw)
        }
    }

    /// The first reading is usually right; the search stops shortly after it
    /// instead of spending the first display's wait on the rest of the list.
    func testSearchStopsSoonAfterAnAdmission() {
        let engine = JapaneseCandidateEngine()
        _ = corrections("tabemadu", engine: engine)
        XCTAssertLessThanOrEqual(engine.lastCorrectionMetrics.queries, 1 + CandidateCorrectionPolicy.queriesAfterAdmission)
    }

    func testFirstAdmittedReadingDoesNotHideABetterOne() {
        let values = corrections("ikimadu")
        XCTAssertTrue(values.contains { $0.correction?.suggestedReading == "いきます" },
                      "\(values.filter { $0.correction != nil }.map(\.text))")
    }

    func testStrayLFromTheProlongedKeyIsCorrected() {
        for (raw, expected) in [("ralmenn", "らーめん"), ("kolhilwonomu", "こーひーをのむ"), ("sulpalnoyasai", "すーぱーのやさい")] {
            let values = corrections(raw)
            XCTAssertTrue(values.contains { $0.correction?.suggestedReading == expected },
                          "\(raw): \(values.filter { $0.correction != nil }.map(\.text))")
        }
    }

    func testCorrectInputStillGetsNoCorrection() {
        for raw in ["hassoushimasu", "watashihanihongowobenkyoushiteimasu", "ra-men", "ko-hi-wonomu", "shimadusan"] {
            XCTAssertFalse(corrections(raw).contains { $0.source == .typoCorrection }, raw)
        }
    }

    /// The keyboard never moves a displayed choice, so a correction is useful
    /// only if it joins the first display, inside the model ranking window.
    func testCorrectionJoinsTheFirstDisplayInsteadOfTheEnd() async throws {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        worker.allowLanguageModel()
        var query = ComposingText()
        RomajiConverter.insert("hassoushimadu", into: &query)
        // Load the model and the correction cache; the measured request repeats
        // the input, as typing does when a word is revisited.
        let warmed = expectation(description: "warm-up correction")
        warmed.assertForOverFulfill = false
        worker.candidates(for: query, katakana: false, revision: 1, leftContext: "", continuity: nil) { values, _, _ in
            if values.contains(where: { $0.source == .typoCorrection }) { warmed.fulfill() }
        }
        await fulfillment(of: [warmed], timeout: 10)
        _ = await worker.resourceState()
        let displayed = expectation(description: "first display")
        let late = XCTestExpectation(description: "late correction") // Awaited only in Debug.
        late.assertForOverFulfill = false
        var first: [CandidateSnapshot] = []
        var lateCorrections = 0
        worker.candidates(for: query, katakana: false, revision: 2, leftContext: "", continuity: nil) { values, _, supplementary in
            if supplementary {
                lateCorrections += values.filter { $0.source == .typoCorrection }.count
                if lateCorrections > 0 { late.fulfill() }
            } else {
                first = values
                displayed.fulfill()
            }
        }
        await fulfillment(of: [displayed], timeout: 5)
        let best = first.firstIndex { $0.source == .typoCorrection }
#if DEBUG
        // Unoptimized code can miss the window; the correction must then still
        // arrive as a late addition.
        if best == nil { await fulfillment(of: [late], timeout: 5) }
#else
        XCTAssertLessThanOrEqual(best ?? .max, CandidateCorrectionPolicy.correctionDisplayRank, "\(first.prefix(4).map(\.text))")
#endif
        if best != nil {
            _ = await worker.resourceState()
            XCTAssertEqual(lateCorrections, 0, "A settled search is not repeated after the first display")
        }
        worker.reset()
    }

    /// A stray letter has no model comparison to wait for, but the literal
    /// cannot be meant, so the first display waits for its correction.
    func testStrayLetterCorrectionJoinsTheFirstDisplay() async throws {
        XCTAssertTrue(JapaneseCandidateWorker.hasStrayLetter("らlめん"))
        XCTAssertFalse(JapaneseCandidateWorker.hasStrayLetter("らーめn"))
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        var query = ComposingText()
        RomajiConverter.insert("ralmenn", into: &query)
        let warmed = expectation(description: "warm-up correction")
        warmed.assertForOverFulfill = false
        worker.candidates(for: query, katakana: false, revision: 1, leftContext: "", continuity: nil) { values, _, _ in
            if values.contains(where: { $0.source == .typoCorrection }) { warmed.fulfill() }
        }
        await fulfillment(of: [warmed], timeout: 10)
        let displayed = expectation(description: "first display")
        var first: [CandidateSnapshot] = []
        worker.candidates(for: query, katakana: false, revision: 2, leftContext: "", continuity: nil) { values, _, supplementary in
            guard !supplementary else { return }
            first = values
            displayed.fulfill()
        }
        await fulfillment(of: [displayed], timeout: 5)
        XCTAssertTrue(first.prefix(2).contains { $0.correction?.suggestedReading == "らーめん" }, "\(first.prefix(4).map(\.text))")
        worker.reset()
    }
}
