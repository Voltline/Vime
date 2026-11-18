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

    /// A suggestion is also checked joined to the text before it.
    func testNextWordSuggestionsLeaveOutTermsCompletedByTheLeftContext() {
        let blocked = list(["禁止語"])
        let after = PostCompositionSuggestionReranker.merge(
            native: [suggestion("語"), suggestion("です")], neural: [suggestion("語です")], leftContext: "これは禁止", blocklist: blocked)
        XCTAssertEqual(Set(after.map(\.text)), ["です"])

        let elsewhere = PostCompositionSuggestionReranker.merge(
            native: [suggestion("語"), suggestion("です")], neural: [], leftContext: "日本", blocklist: blocked)
        XCTAssertEqual(Set(elsewhere.map(\.text)), ["語", "です"], "the same words after other text stay")

        let earlier = PostCompositionSuggestionReranker.merge(
            native: [suggestion("語")], neural: [], leftContext: "禁止。今日は日本の伝統", blocklist: blocked)
        XCTAssertEqual(earlier.map(\.text), ["語"], "only the end of the left context counts")

        let afterTyped = PostCompositionSuggestionReranker.merge(
            native: [suggestion("です"), suggestion("の")], neural: [], leftContext: "禁止語", blocklist: blocked)
        XCTAssertEqual(Set(afterTyped.map(\.text)), ["です", "の"], "a term typed before is not held against what follows")
    }

    /// Japanese has its own, narrower list: borderline everyday words and what
    /// follows them stay, while Chinese keeps the broad list.
    func testBundledJapaneseListLeavesBorderlineWordsAlone() throws {
        let japanese = PredictionBlocklist.japanese
        try XCTSkipUnless(japanese.isAvailable, "PredictionBlocklistJapanese.bin is not bundled")
        let borderline = ["人妻", "熟女", "幼女戦記", "下着", "水着", "胸", "お尻", "不倫", "風俗", "アダルトチルドレン",
                          "無修正", "個人撮影", "ぶっかけうどん", "フェラーリ", "パチンコ", "やらせ", "痴漢被害", "日本の伝統",
                          "薬", "売る", "薬物", "大麻", "麻薬", "ソープ", "ドラッグストア", "援助", "本番"]
        for word in borderline { XCTAssertFalse(japanese.matches(word), word) }
        for context in ["人妻", "下着", "女子高生", "温泉"] {
            let merged = PostCompositionSuggestionReranker.merge(
                native: [suggestion("の"), suggestion("と")], neural: [suggestion("が")], leftContext: context, blocklist: japanese)
            XCTAssertEqual(Set(merged.map(\.text)), ["の", "と", "が"], context)
        }
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
