import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardLexicalEvidenceTests: XCTestCase {
    func testPunctuationDoesNotHideDictionaryConversion() throws {
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: isolatedLearningDirectory(), learningEnabled: false)
        for (reading, surface) in [("（がっこう", "（学校"), ("）としょかん", "）図書館")] {
            engine.reset()
            var query = ComposingText()
            RomajiConverter.insert(reading, into: &query)
            let values = engine.candidates(for: query, revision: 1, includeCorrections: false)
            let conversion = try XCTUnwrap(values.first { $0.text == surface })
            XCTAssertTrue(conversion.lexical, surface)
            XCTAssertTrue(conversion.fullConsumption && conversion.exactReading, surface)
            XCTAssertNotEqual(values.first?.source, .scriptVariant, surface)
            let slots = VimeLanguageModel.rerankingSlots(values, katakana: false)
            XCTAssertTrue(slots.contains { values[$0].text == surface }, surface)
            XCTAssertEqual(conversion.consumedInputCount, query.input.count)
        }
    }

    func testSeparatorsAreNeutralButUnknownWordsStillRejectEvidence() {
        func element(_ word: String, _ ruby: String, dictionary: Bool = false,
                     registered: Bool = false) -> DicdataElement {
            .init(word: word, ruby: ruby, cid: dictionary ? CIDData.一般名詞.cid : CIDData.固有名詞.cid,
                  mid: MIDData.一般.mid, value: -10, metadata: registered ? .isFromUserDictionary : .empty)
        }
        func evidence(_ words: [DicdataElement]) -> Bool {
            JapaneseCandidateEngine.hasDictionaryEvidence(Candidate(text: words.map(\.word).joined(),
                value: -10, composingCount: .inputCount(8), lastMid: MIDData.一般.mid, data: words))
        }
        let word = element("学校", "ガッコウ", dictionary: true)
        for separator in ["（", ")", "、", "。", "「」", "…", " "] {
            let punctuation = element(separator, separator)
            XCTAssertTrue(evidence([punctuation, word, punctuation]), separator)
            XCTAssertFalse(evidence([punctuation]), "Separators alone are not word evidence")
        }
        XCTAssertFalse(evidence([]))
        XCTAssertFalse(evidence([element("", "")]))
        for unknown in [element("みとうろく", "ミトウロク"), element("ミトウロク", "ミトウロク"),
                        element("unresolved", "unresolved"), element("空", "")] {
            XCTAssertFalse(evidence([unknown]))
            XCTAssertFalse(evidence([word, unknown]))
            XCTAssertFalse(evidence([unknown, word]))
        }
        XCTAssertTrue(evidence([element("みとうろく", "ミトウロク", registered: true)]))
        XCTAssertTrue(evidence([element("ありがとう", "アリガトウ", dictionary: true)]))
    }

    func testKanaOrthographyAndExplicitKatakanaRemainPreferred() throws {
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: isolatedLearningDirectory(), learningEnabled: false)
        for (input, preferred, alternative) in [("けが", "けが", "怪我"), ("ありがとう", "ありがとう", "有難う")] {
            engine.reset()
            var query = ComposingText()
            RomajiConverter.insert(input, into: &query)
            let values = engine.candidates(for: query, revision: 1, includeCorrections: false)
            let kana = try XCTUnwrap(values.firstIndex { $0.text == preferred })
            let kanji = try XCTUnwrap(values.firstIndex { $0.text == alternative })
            XCTAssertLessThan(kana, kanji)
        }
        engine.reset()
        var query = ComposingText()
        RomajiConverter.insert("（がっこう", into: &query)
        let values = engine.candidates(for: query, katakana: true, revision: 2, includeCorrections: false)
        XCTAssertEqual(values.first?.text, "（ガッコウ")
        XCTAssertTrue(VimeLanguageModel.rerankingSlots(values, katakana: true).isEmpty)
    }
}
