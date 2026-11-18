import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

/// The prediction blocklist: every region, Japanese side.
@MainActor
final class PredictionBlocklistTests: XCTestCase {
    private func list(_ terms: [String], allowed: [String] = []) -> LearningExclusionList {
        LearningExclusionList(data: LearningExclusionList.encode(blocked: terms, allowed: allowed))
    }

    private func suggestion(_ text: String) -> NextWordSuggestion {
        NextWordSuggestion(text: text, source: .contextPrediction, score: 0, userScore: 0)
    }

    /// The real list is opened from its sealed copy, so it is absent where the key is.
    func testBundledListLeavesEverydayWordsAlone() throws {
        let bundled = PredictionBlocklist.shared
        try XCTSkipUnless(bundled.isAvailable, "PredictionBlocklist.bin is not bundled")
        for word in ["电话号码", "今天天气很好", "我们一起去吃饭吧", "こんにちは", "何も", "猫", "ありがとうございます"] {
            XCTAssertFalse(bundled.matches(word), word)
        }
    }

    func testNextWordSuggestionsLeaveOutBlockedTerms() {
        let blocked = list(["禁止語"])
        let merged = PostCompositionSuggestionReranker.merge(
            native: [suggestion("禁止語"), suggestion("今日")],
            neural: [suggestion("禁止語です"), suggestion("明日")], blocklist: blocked)
        XCTAssertEqual(Set(merged.map(\.text)), ["今日", "明日"])

        let unfiltered = PostCompositionSuggestionReranker.merge(
            native: [suggestion("禁止語"), suggestion("今日")], neural: [], blocklist: list([]))
        XCTAssertEqual(Set(unfiltered.map(\.text)), ["禁止語", "今日"], "ordinary words are untouched")
    }

    func testCompletionsLeaveOutBlockedTermsButTypingStillConverts() throws {
        func query(_ input: String) -> ComposingText {
            var value = ComposingText(); RomajiConverter.insert(input, into: &value); return value
        }
        let engine = JapaneseCandidateEngine()
        let open = engine.candidates(for: query("nanim"), revision: 1, includeCorrections: false)
        XCTAssertTrue(open.contains { $0.text == "何も" && $0.predictionStatus }, "\(open.prefix(12).map(\.text))")

        engine.predictionBlocklist = list(["何も"])
        engine.reset()
        let predicted = engine.candidates(for: query("nanim"), revision: 2, includeCorrections: false)
        XCTAssertFalse(predicted.contains { $0.text == "何も" }, "\(predicted.prefix(12).map(\.text))")
        XCTAssertTrue(predicted.contains { $0.text == "何" }, "other candidates stay")

        engine.reset()
        let typed = engine.candidates(for: query("nanimo"), revision: 3, includeCorrections: false)
        XCTAssertTrue(typed.contains { $0.text == "何も" && !$0.predictionStatus }, "\(typed.prefix(12).map(\.text))")
    }

    func testTaiwanFlagStaysHiddenOnlyInMainlandChina() {
        let flag = "\u{1F1F9}\u{1F1FC}"
        XCTAssertTrue(KeyboardEmojiAvailability.isRegionallyHidden(flag, excluded: KeyboardEmojiAvailability.excluded(in: "CN")))
        for region in ["TW", "HK", "JP", "US", nil] as [String?] {
            XCTAssertFalse(KeyboardEmojiAvailability.isRegionallyHidden(flag, excluded: KeyboardEmojiAvailability.excluded(in: region)),
                           region ?? "nil")
        }
        XCTAssertFalse(PredictionBlocklist.shared.matches(flag), "the blocklist does not take over the flag")
    }
}
