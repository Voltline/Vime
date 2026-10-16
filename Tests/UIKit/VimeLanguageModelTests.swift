import XCTest
import CoreML
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class VimeLanguageModelTests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Token: Decodable { let text: String; let ids: [Int32]; let decoded: String }
        struct Score: Decodable { let context: String; let candidates: [String]; let sums: [Double] }
        let tokenization: [Token]
        struct Phrase: Decodable { let prompt: String; let firstText: String; let firstIDs: [Int32]; let firstSum: Double }
        let phrases: [Phrase]
        let scoring: [Score]
    }
    private func fixtures() throws -> Fixtures {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "VimeLMFixturesV21", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
    func testNativeSentencePieceMatchesFrozenCorpusAndUnicode() throws {
        let lm = try VimeLanguageModel()
        let data = try fixtures()
        XCTAssertGreaterThan(data.tokenization.count, 1000)
        for item in data.tokenization {
            XCTAssertEqual(try lm.tokenizer.encode(item.text), item.ids, item.text)
            XCTAssertEqual(try lm.tokenizer.decode(item.ids), item.decoded, item.text)
        }
    }
    func testJointSuffixScoresMatchMacINT8IncludingBoundaryRetokenization() throws {
        let lm = try VimeLanguageModel()
        let corpus = try fixtures().scoring
        XCTAssertFalse(corpus.isEmpty, "An empty reference corpus cannot certify numerical parity")
        for item in corpus {
            XCTAssertFalse(item.candidates.isEmpty, item.context)
            XCTAssertEqual(item.candidates.count, item.sums.count, "Every candidate needs an independent frozen reference")
            let actual = try lm.scores(context: item.context, candidates: item.candidates)
            XCTAssertEqual(actual.count, item.sums.count)
            for (value, reference) in zip(actual, item.sums) { XCTAssertEqual(value, reference, accuracy: 0.002) }
        }
    }
    func testWholePoolFallbackAndCancellation() throws {
        let lm = try VimeLanguageModel()
        XCTAssertThrowsError(try lm.scores(context: "", candidates: ["東京", "東京"]))
        XCTAssertThrowsError(try lm.scores(context: "", candidates: ["", "東京"]))
        XCTAssertThrowsError(try lm.scores(context: "▁", candidates: ["東京", "大阪"]))
        XCTAssertThrowsError(try lm.scores(context: String(repeating: "東京", count: 200), candidates: ["駅", "都"]))
        XCTAssertThrowsError(try lm.scores(context: "", candidates: ["東京", "大阪"], cancelled: { true }))
        XCTAssertThrowsError(try lm.predict([]))
        XCTAssertThrowsError(try lm.predict([16384]))
        XCTAssertThrowsError(try lm.predict(Array(repeating: 2, count: 129)))
    }
    func testPaddingAndCausality() throws {
        let lm = try VimeLanguageModel()
        let ids: [Int32] = [2] + (try lm.tokenizer.encode("明日の会議までに、"))
        let plain = try lm.predict(ids)
        let padded = try lm.predict(ids + Array(repeating: 0, count: 128 - ids.count))
        let future = try lm.predict(ids + Array(repeating: 4675, count: 128 - ids.count))
        for row in ids.indices {
            let a = try VimeLanguageModel.logProbabilities(plain, row: row)
            let b = try VimeLanguageModel.logProbabilities(padded, row: row)
            let c = try VimeLanguageModel.logProbabilities(future, row: row)
            XCTAssertLessThan(zip(a,b).map { abs($0-$1) }.max()!, 0.0002)
            XCTAssertLessThan(zip(b,c).map { abs($0-$1) }.max()!, 0.0002)
        }
    }
    func testRerankerRetainsMetadataAndExplicitScriptAndCancelledOrders() throws {
        let lm = try VimeLanguageModel()
        let engine = JapaneseCandidateEngine()
        var query = ComposingText()
        RomajiConverter.insert("nihongo", into: &query)
        let values = engine.candidates(for: query, revision: 73, includeCorrections: false)
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(lm.rerank(values, context: "", katakana: true, cancelled: { false }).map(\.presentation), values.map(\.presentation))
        XCTAssertEqual(lm.rerank(values, context: "", katakana: false, cancelled: { true }).map(\.presentation), values.map(\.presentation))
        let reordered = lm.rerank(values, context: "", katakana: false, cancelled: { false })
        XCTAssertEqual(Set(reordered.map(\.text)), Set(values.map(\.text)))
        XCTAssertTrue(reordered.allSatisfy { $0.revision == 73 })
        for index in values.indices where !VimeLanguageModel.rerankingSlots(values, katakana: false).contains(index) {
            XCTAssertEqual(reordered[index].presentation, values[index].presentation)
        }
    }
    func testNativeBeamMatchesTwentyMacINT8Prefixes() throws {
        let lm = try VimeLanguageModel()
        let corpus = try fixtures().phrases
        XCTAssertEqual(corpus.count, 20, "All twenty frozen prefixes must be checked")
        for phrase in corpus {
            XCTAssertFalse(phrase.firstText.isEmpty)
            XCTAssertFalse(phrase.firstIDs.isEmpty)
            let suggestions = try lm.suggestions(prompt: phrase.prompt)
            let first = try XCTUnwrap(suggestions.first, phrase.prompt)
            XCTAssertEqual(first.tokenIDs, phrase.firstIDs, phrase.prompt)
            XCTAssertEqual(first.text, phrase.firstText, phrase.prompt)
            XCTAssertEqual(first.logProbabilitySum, phrase.firstSum, accuracy: 0.005, phrase.prompt)
            XCTAssertEqual(Set(suggestions.map(\.text)).count, suggestions.count)
        }
        XCTAssertThrowsError(try lm.suggestions(prompt: "東京", cancelled: { true }))
    }

    func testRerankerUsesFrozenScoresAndPreservesIneligibleSlot() throws {
        let lm = try VimeLanguageModel()
        let reference = try XCTUnwrap(try fixtures().scoring.first { $0.context == "コーヒーを" })
        XCTAssertEqual(reference.candidates, ["飲む", "買う", "飲みたい"])
        // Warm the same deployed model, and independently check its numerical
        // scores before testing the sorting adapter against the frozen order.
        let sums = try lm.scores(context: reference.context, candidates: reference.candidates)
        XCTAssertEqual(sums.count, reference.sums.count)
        for (sum, frozen) in zip(sums, reference.sums) { XCTAssertEqual(sum, frozen, accuracy: 0.002) }
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: isolatedLearningDirectory())
        func native(_ raw: String, _ surface: String) throws -> CandidateSnapshot {
            var query = ComposingText(); RomajiConverter.insert(raw, into: &query)
            var value = try XCTUnwrap(engine.candidates(for: query, revision: 84, includeCorrections: false).first {
                $0.text == surface && $0.source == .conversion && $0.fullConsumption && $0.exactReading && $0.lexical
            }, surface)
            value.userPreferenceScore = 0
            value.features = CandidateScoreFeatures()
            return value
        }
        let drink = try native("nomu", "飲む")
        let buy = try native("kau", "買う")
        let want = try native("nomitai", "飲みたい")
        let script = CandidateSnapshot(candidate: drink.candidate, revision: 84, source: .scriptVariant,
            remainingComposition: ComposingText(), originalInputCount: drink.originalInputCount,
            consumedInputCount: drink.consumedInputCount, queryReading: drink.queryReading)
        // An adapter unit corpus assembled from three real lexical conversions,
        // not a claim that these different readings share one IME query. Put
        // them in a deliberately wrong order so identity reranking must fail.
        let pool = [buy, script, want, drink]
        XCTAssertEqual(VimeLanguageModel.rerankingSlots(pool, katakana: false), [0, 2, 3])
        let ranked = lm.rerank(pool, context: reference.context, katakana: false, cancelled: { false })
        XCTAssertEqual([ranked[0].text, ranked[2].text, ranked[3].text], ["飲む", "飲みたい", "買う"])
        XCTAssertEqual(ranked[1].presentation, script.presentation)
        XCTAssertEqual(ranked[0].candidate, drink.candidate)
        var personalized = pool
        personalized[2].userPreferenceScore = CandidatePreferenceMemory.Policy.maximumBonus
        XCTAssertEqual(lm.rerank(personalized, context: reference.context, katakana: false, cancelled: { false })[0].text, "飲みたい")
    }
    func testNextWordsAreShortAndStopBeforePunctuation() throws {
        let lm = try VimeLanguageModel()
        var report: [String: [String]] = [:]
        for prompt in ["ご確認のほど、", "本日はお忙しい中", "明日の会議までに", "朝起きたら、コーヒーを", "パスワードを入力して"] {
            let words = try lm.nextWords(prompt: prompt)
            report[prompt] = words
            XCTAssertFalse(words.isEmpty, prompt)
            XCTAssertEqual(Set(words).count, words.count)
            for word in words {
                XCTAssertFalse(word.contains { "。！？、".contains($0) }, word)
                XCTAssertFalse(word.contains("\u{fffd}"))
                XCTAssertLessThanOrEqual(try lm.tokenizer.encode(prompt + word).count - (try lm.tokenizer.encode(prompt).count), 4)
            }
        }
        print("NEXT_WORDS", report)
        XCTAssertThrowsError(try lm.nextWords(prompt: "東京", cancelled: { true }))
    }
    func testSentenceContextKeepsOnlyUnfinishedSentence() {
        XCTAssertEqual(VimeLanguageModel.sentenceContext("今日は晴れ。明日の会議までに、"), "明日の会議までに、")
        XCTAssertEqual(VimeLanguageModel.sentenceContext("ありがとう。"), "")
        XCTAssertEqual(VimeLanguageModel.sentenceContext("一行目\n 二行目"), "二行目")
        XCTAssertEqual(VimeLanguageModel.sentenceContext(String(repeating: "あ", count: 200)).count, 64)
    }
    func testEngineRankingPublishesNoLanguageModelReorder() async throws {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        var query = ComposingText()
        RomajiConverter.insert("kisha", into: &query)
        var published: [[String]] = []
        worker.candidates(for: query, katakana: false, revision: 1, leftContext: "明日の", continuity: nil,
                          ranking: .engine) { values, _, _ in published.append(values.map(\.text)) }
        try await Task.sleep(for: .seconds(2))
        let first = try XCTUnwrap(published.first)
        // Corrections may append entries; a pure permutation could only come from the LM.
        XCTAssertFalse(published.dropFirst().contains { $0 != first && $0.sorted() == first.sorted() })
    }
    func testSessionShowsAndInsertsPhraseSuggestionsAfterCommit() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.phraseSuggestions = true
        let view = UITextView()
        let host = KeyboardHostConnection(setMarkedText: { view.setMarkedText($0, selectedRange: $1) },
            unmarkText: { view.unmarkText() }, insertText: { view.insertText($0) }, deleteBackward: { view.deleteBackward() })
        session.leftContextProvider = {
            let caret = view.markedTextRange?.start ?? view.selectedTextRange?.start ?? view.endOfDocument
            return view.text(in: view.textRange(from: view.beginningOfDocument, to: caret)!)
        }
        let candidates = expectation(description: "candidates")
        var delivered = false
        session.onCandidatesChange = {
            if session.isComposing && session.candidatesAreCurrent && !delivered { delivered = true; candidates.fulfill() }
        }
        _ = session.type("ekini")
        host.updateMarkedText(session.preedit)
        await fulfillment(of: [candidates], timeout: 10)
        let index = try XCTUnwrap(session.candidates.firstIndex(of: "駅に"))
        let suggested = expectation(description: "suggestions")
        var suggestedOnce = false
        session.onCandidatesChange = {
            if !session.suggestions.isEmpty && !suggestedOnce { suggestedOnce = true; suggested.fulfill() }
        }
        let commit = session.chooseStrip(index)
        XCTAssertEqual(commit, [.insert("駅に")])
        host.apply(commit, preedit: session.markedText)
        XCTAssertEqual(view.text, "駅に")
        XCTAssertNil(view.markedTextRange)
        await fulfillment(of: [suggested], timeout: 10)
        session.onCandidatesChange = nil
        XCTAssertTrue(session.showsStrip)
        XCTAssertEqual(session.stripPresentations.map(\.text), session.suggestions)
        let first = try XCTUnwrap(session.suggestions.first, "Missing real async suggestions must fail, not crash the test process")
        let edits = session.chooseStrip(0)
        // A native suggestion can replace the committed suffix. Validate the
        // complete operation batch against a real text input, including deletes.
        XCTAssertEqual(try XCTUnwrap(edits.last), .insert(first))
        XCTAssertTrue(edits.dropLast().allSatisfy { $0 == .deleteBackward })
        XCTAssertLessThanOrEqual(edits.count - 1, "駅に".count)
        host.apply(edits, preedit: session.markedText)
        XCTAssertEqual(view.text, String("駅に".dropLast(edits.count - 1)) + first)
        XCTAssertNil(view.markedTextRange)
        XCTAssertTrue(session.suggestions.isEmpty)
        _ = session.type("a")
        XCTAssertTrue(session.suggestions.isEmpty)
        session.phraseSuggestions = false
        session.reset()
        XCTAssertFalse(session.showsStrip)
    }

}
