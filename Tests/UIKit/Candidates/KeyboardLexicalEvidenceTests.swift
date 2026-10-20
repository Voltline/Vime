import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardLexicalEvidenceTests: XCTestCase {
    func testSuruVerbDiagnostics() throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: false)
        for input in ["りふぁくたりんぐします", "でぷろいします", "きゃっしゅします", "べんちまーくします", "みらーりんぐします", "さいひょうかします", "どうきします", "べんきょうします", "しんせいします", "しんじゅくします", "しみん", "よこはまし", "ししょくします", "りふぁくたりんぐしました", "でぷろいしません", "きゃっしゅして", "りふぁくたりんぐする"] {
            engine.reset()
            var query = ComposingText()
            RomajiConverter.insert(input, into: &query)
            let values = engine.candidates(for: query, revision: 1, includeCorrections: false)
            print("SURU_INPUT \(input) TOP \(values.prefix(8).map(\.text))")
            for value in values.prefix(5) {
                print("SURU_DATA \(value.text) score=\(value.features.total) native=\(value.engineScore) rank=\(value.engineRank) parts=\(value.candidate.data)")
            }
        }
    }

    /// azooKey's first-clause list can lead with a single-bunsetsu reading
    /// (「…市ます」) that mainResults ranks below the suru verb. Dictionary order
    /// is what the strip shows whenever the model window is missed.
    func testSuruVerbOutranksFirstClauseNounReading() {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: false)
        let expected = [
            "rifakutaringusimasu": "リファクタリングします", "depuroisimasu": "デプロイします",
            "kyasshusimasu": "キャッシュします", "bentimaーkusimasu": "ベンチマークします",
            "miraーringusimasu": "ミラーリングします", "benkyousimasu": "勉強します",
            "rifakutaringusimasita": "リファクタリングしました", "depuroisimasenn": "デプロイしません",
            "kyasshusite": "キャッシュして"
        ]
        for (input, surface) in expected.sorted(by: { $0.key < $1.key }) {
            engine.reset()
            var query = ComposingText()
            RomajiConverter.insert(input, into: &query)
            let values = engine.candidates(for: query, revision: 1, includeCorrections: false)
            XCTAssertEqual(values.first?.text, surface, input)
            let top = values.first?.features.total ?? 0
            for value in values.dropFirst() where value.fullConsumption && value.text.contains(where: { "市氏誌師".contains($0) }) {
                XCTAssertLessThan(value.features.total, top - 1, "\(input): \(value.text)")
            }
        }
    }

    func testMixedPhraseCanCompeteWithoutAdmittingUnknownCorrection() {
        let word = DicdataElement(word: "学校", ruby: "ガッコウ", cid: CIDData.一般名詞.cid,
                                  mid: MIDData.一般.mid, value: -10)
        let unknown = DicdataElement(word: "ミトウロク", ruby: "ミトウロク", cid: CIDData.固有名詞.cid,
                                     mid: MIDData.一般.mid, value: -10)
        let number = DicdataElement(word: "17", ruby: "17", cid: CIDData.固有名詞.cid,
                                    mid: MIDData.一般.mid, value: -10)
        for tail in [unknown, number] {
            let native = Candidate(text: word.word + tail.word, value: -20, composingCount: .inputCount(8),
                                   lastMid: MIDData.一般.mid, data: [word, tail])
            let value = CandidateSnapshot(candidate: native, revision: 1, source: .conversion,
                remainingComposition: ComposingText(), originalInputCount: 8, consumedInputCount: 8,
                queryReading: word.ruby + tail.ruby)
            XCTAssertFalse(JapaneseCandidateEngine.hasDictionaryEvidence(native), "Correction admission stays strict")
            XCTAssertTrue(value.lexical)
            XCTAssertTrue(value.exactReading)
            XCTAssertEqual(VimeLanguageModel.rerankingSlots([value], katakana: false), [0])
            let ranked = CandidateReranker().rank([value], input: value.queryReading, katakana: false, previous: nil)
            XCTAssertEqual(ranked.first?.features.exactReading, CandidateRankingWeights().exactLexical)
            XCTAssertEqual(ranked.first?.candidate, native, "Keep native segmentation and consumption for selection")
        }
        let fallback = Candidate(text: unknown.word, value: -10, composingCount: .inputCount(4),
                                 lastMid: MIDData.一般.mid, data: [unknown])
        XCTAssertFalse(JapaneseCandidateEngine.hasConversionEvidence(fallback))
    }

    func testUnfinishedRomanSuffixDoesNotReceiveExactConversionBonus() throws {
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: isolatedLearningDirectory(), learningEnabled: false)
        var query = ComposingText()
        RomajiConverter.insert("kouen", into: &query)
        let values = engine.candidates(for: query, revision: 1, includeCorrections: false)
        XCTAssertEqual(values.first?.text, "公園")
        for value in values where value.reading.hasSuffix("n") {
            XCTAssertFalse(value.exactReading)
            XCTAssertEqual(value.features.exactReading, 0)
        }
    }

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
