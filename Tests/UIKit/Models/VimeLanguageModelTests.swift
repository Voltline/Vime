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

    /// Independent forward pass and full-vocabulary scalar softmax for every
    /// candidate. This reference deliberately shares no prefix/logit cache.
    private func independentScores(_ model: VimeLanguageModel, context: String, candidates: [String]) throws -> [Double] {
        let prefix: [Int32] = [2] + (try model.tokenizer.encode(context))
        let sequences = try candidates.map { [Int32(2)] + (try model.tokenizer.encode(context + $0)) }
        var common = 0
        for index in 0..<([prefix] + sequences).map(\.count).min()! {
            guard sequences.allSatisfy({ $0[index] == prefix[index] }) else { break }
            common += 1
        }
        return try sequences.map { sequence in
            try autoreleasepool {
                let logits = try model.predict(Array(sequence.dropLast()))
                return try ((common - 1)..<(sequence.count - 1)).reduce(0.0) { sum, row in
                    sum + (try VimeLanguageModel.logProbabilities(logits, row: row))[Int(sequence[row + 1])]
                }
            }
        }
    }

    private func singleTokenCandidates(_ model: VimeLanguageModel, context: String) throws -> [String] {
        let prefix = try model.tokenizer.encode(context)
        return try ["東京", "大阪", "京都", "日本", "学校", "会社", "仕事", "会議", "旅行", "雨", "晴れ"].filter {
            let ids = try model.tokenizer.encode(context + $0)
            return ids.count == prefix.count + 1 && ids.starts(with: prefix)
        }
    }

    func testConversionCacheReusesAcrossChangingPoolsAndBoundariesWithoutChangingScores() throws {
        let model = try VimeLanguageModel(variant: .v21), cache = VimeLanguageModel.ConversionScoreCache()
        let context = "週末の旅行について友人と相談しているので、"
        let pools = [["東京", "大阪"], ["東京へ", "京都"],
                     ["東京へ旅行する予定です", "大阪", "日本の会社で働く"]]
        for candidates in pools {
            let expected = try independentScores(model, context: context, candidates: candidates)
            let actual = try model.scores(context: context, candidates: candidates, conversionCache: cache)
            for (a, b) in zip(actual, expected) { XCTAssertEqual(a, b, accuracy: 0.002) }
        }
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        _ = try model.scores(context: context, candidates: pools.last!, conversionCache: cache)
        XCTAssertNil(KeyboardPerformance.report()["lmScoringPrediction"], "Already scored prefixes need no transformer pass")
        XCTAssertThrowsError(try model.scores(context: context, candidates: pools[0], conversionCache: cache, cancelled: { true }))
        // The changed pool can move the joint-tokenization boundary. Cached
        // rows carry exact causal prefixes rather than old suffix score sums.
        for fixture in try fixtures().scoring {
            for text in fixture.candidates {
                _ = try model.scores(context: fixture.context, candidates: [text], conversionCache: cache)
            }
            let actual = try model.scores(context: fixture.context, candidates: fixture.candidates, conversionCache: cache)
            for (a, b) in zip(actual, fixture.sums) { XCTAssertEqual(a, b, accuracy: 0.002) }
            XCTAssertLessThanOrEqual(cache.rowCount, VimeLanguageModel.ConversionScoreCache.maximumRows)
        }
        cache.prepare(context: "全く別の文脈")
        XCTAssertEqual(cache.rowCount, 0)
    }

    func testConversionCacheEvictionKeepsNumericalParityAndBoundedMemory() throws {
        let model = try VimeLanguageModel(variant: .v21), cache = VimeLanguageModel.ConversionScoreCache()
        let context = "明日は、"
        for index in 0..<80 {
            _ = try model.scores(context: context, candidates: ["東京の予定\(index)について相談する"], conversionCache: cache)
            XCTAssertLessThanOrEqual(cache.rowCount, VimeLanguageModel.ConversionScoreCache.maximumRows)
        }
        XCTAssertEqual(cache.scoreCount, VimeLanguageModel.ConversionScoreCache.maximumScores)
        let candidates = ["東京の予定0について相談する", "大阪へ旅行する"]
        let expected = try independentScores(model, context: context, candidates: candidates)
        let actual = try model.scores(context: context, candidates: candidates, conversionCache: cache)
        for (a, b) in zip(actual, expected) { XCTAssertEqual(a, b, accuracy: 0.002) }
    }

    func testConversionCacheReusesLongCandidateWhenOnlyLastTokenChanges() throws {
        let model = try VimeLanguageModel(variant: .v21), cache = VimeLanguageModel.ConversionScoreCache()
        let context = "旅行について相談していて、"
        let texts = (0..<10).map { "東京へ行く予定の便番号は\($0)" }
        let groups = try Dictionary(grouping: texts) { Array(try model.tokenizer.encode(context + $0).dropLast()) }
        let pair = try XCTUnwrap(groups.values.first { $0.count >= 2 }).sorted().prefix(2)
        let expected = try independentScores(model, context: context, candidates: Array(pair))
        let first = try model.scores(context: context, candidates: [pair.first!], conversionCache: cache)
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        let second = try model.scores(context: context, candidates: [pair.last!], conversionCache: cache)
        XCTAssertNil(KeyboardPerformance.report()["lmScoringPrediction"], "Same complete input prefix requires no new prediction")
        XCTAssertEqual(first[0], expected[0], accuracy: 0.002)
        XCTAssertEqual(second[0], expected[1], accuracy: 0.002)
    }

    func testSharedPrefixScoresUseOnePredictionAndMatchIndependentShortAndLongContexts() throws {
        let model = try VimeLanguageModel(variant: .v21)
        let long = String("来週の旅行に備えて必要な物を整理しながら現地で何をするか友人と相談していて、まだ決まっていない予定について詳しく話すために、".suffix(64))
        for context in ["", "明日は、", long] {
            let candidates = try singleTokenCandidates(model, context: context)
            XCTAssertGreaterThanOrEqual(candidates.count, 3, "The fixture must exercise actual shared-prefix reuse")
            let reference = try independentScores(model, context: context, candidates: candidates)
            KeyboardPerformance.configure(enabled: true, reset: true)
            defer { KeyboardPerformance.configure(enabled: false) }
            let actual = try model.scores(context: context, candidates: candidates)
            for (value, expected) in zip(actual, reference) { XCTAssertEqual(value, expected, accuracy: 0.002) }
            let report = KeyboardPerformance.report()
            XCTAssertEqual(report["lmScoringPrediction"]?["totalCount"], 1)
            XCTAssertEqual(report["lmScoringPrefixReuse"]?["totalCount"], Double(candidates.count - 1))
            print("VIME_SHARED_PREFIX_REUSE context_chars=\(context.count) candidates=\(candidates.count) predictions=1")
        }
    }

    func testSharedPrefixScoresPreserveMultiTokenAndReversedCandidateNumericalParity() throws {
        let model = try VimeLanguageModel(variant: .v21)
        let context = "週末の旅行について友人と相談しているので、"
        let candidates = ["東京へ旅行する予定です", "大阪", "京都", "日本の会社で働く"]
        let reference = try independentScores(model, context: context, candidates: candidates)
        let forward = try model.scores(context: context, candidates: candidates)
        let reverse = try model.scores(context: context, candidates: Array(candidates.reversed()))
        for ((value, reversed), expected) in zip(zip(forward, reverse.reversed()), reference) {
            XCTAssertEqual(value, expected, accuracy: 0.002)
            XCTAssertEqual(reversed, expected, accuracy: 0.002)
        }
    }

    func testSharedPrefixReuseStillHonorsCancellationBetweenCandidates() throws {
        let model = try VimeLanguageModel(variant: .v21)
        let candidates = try singleTokenCandidates(model, context: "明日は、")
        XCTAssertGreaterThanOrEqual(candidates.count, 3)
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        XCTAssertThrowsError(try model.scores(context: "明日は、", candidates: candidates, cancelled: {
            (KeyboardPerformance.report()["lmScoringPrefixReuse"]?["totalCount"] ?? 0) >= 1
        }))
        XCTAssertEqual(KeyboardPerformance.report()["lmScoringPrediction"]?["totalCount"], 1)
        XCTAssertEqual(KeyboardPerformance.report()["lmScoringPrefixReuse"]?["totalCount"], 1)
    }
    func testNativeSentencePieceMatchesFrozenCorpusAndUnicode() throws {
        let lm = try VimeLanguageModel(variant: .v21)
        let data = try fixtures()
        XCTAssertGreaterThan(data.tokenization.count, 1000)
        for item in data.tokenization {
            XCTAssertEqual(try lm.tokenizer.encode(item.text), item.ids, item.text)
            XCTAssertEqual(try lm.tokenizer.decode(item.ids), item.decoded, item.text)
        }
    }
    func testJointSuffixScoresMatchMacINT8IncludingBoundaryRetokenization() throws {
        let lm = try VimeLanguageModel(variant: .v21)
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
        let lm = try VimeLanguageModel(variant: .v21)
        XCTAssertThrowsError(try lm.scores(context: "", candidates: ["東京", "東京"]))
        XCTAssertThrowsError(try lm.scores(context: "", candidates: ["", "東京"]))
        XCTAssertThrowsError(try lm.scores(context: "▁", candidates: ["東京", "大阪"]))
        XCTAssertThrowsError(try lm.scores(context: String(repeating: "東京", count: 200), candidates: ["駅", "都"]))
        XCTAssertThrowsError(try lm.scores(context: "", candidates: ["東京", "大阪"], cancelled: { true }))
        XCTAssertThrowsError(try lm.predict([]))
        XCTAssertThrowsError(try lm.predict([16384]))
        XCTAssertThrowsError(try lm.predict(Array(repeating: 2, count: 129)))
    }

    func testNextWordFinalRankingReusesGeneratedScoresWithNumericalParity() throws {
        let model = try VimeLanguageModel(variant: .v21)
        for prompt in ["明日は", "私は", "東京"] {
            let cache = VimeLanguageModel.SuggestionScoreCache()
            let words = try model.scoredNextWords(prompt: prompt, cache: cache)
            let pool = words.generated.map { NextWordSuggestion(text: $0.text, source: .contextPrediction,
                score: 0, userScore: 0) }
            XCTAssertGreaterThan(pool.count, 1)
            let ranked = model.rerankPostComposition(pool, prompt: prompt, cache: cache)
            XCTAssertEqual(cache.reuses, pool.count)
            XCTAssertEqual(cache.scoringPasses, 0, "No repeated inference for already-scored continuations")
            let reference = model.rerankPostComposition(pool, prompt: prompt)
            XCTAssertEqual(ranked.map(\.text), reference.map(\.text))
            for (actual, expected) in zip(ranked, reference) {
                XCTAssertEqual(try XCTUnwrap(actual.modelScore), try XCTUnwrap(expected.modelScore), accuracy: 0.0001)
            }
            print("NEXT_WORD_FINAL_CACHE", prompt, "reused", cache.reuses, "fresh", cache.scoringPasses)
        }
    }

    func testNextWordStagesShareValidatedTokensAndPreserveHistorySelection() throws {
        let model = try VimeLanguageModel(variant: .v21)
        defer { KeyboardPerformance.configure(enabled: false) }
        let history = ["京都に行く", "▁", "大阪に行く", "京都に行く", "最後の未使用"]
        for prompt in ["明日は", "私は", "東京"] {
            let expectedWords = try model.nextWords(prompt: prompt)
            let expectedHistory = Array(Set(history.filter { text in
                guard !expectedWords.contains(text), !text.isEmpty, text.count <= 64,
                      let ids = try? model.tokenizer.encode(prompt + text), ids.count <= VimeLanguageModel.contextLength,
                      let decoded = try? model.tokenizer.decode(ids) else { return false }
                return decoded.utf8.elementsEqual((prompt + text).utf8)
            }.prefix(CandidatePreferenceMemory.Policy.maximumRememberedSuggestions))).sorted()
            let texts = expectedWords + expectedHistory
            let reference = try independentScores(model, context: prompt, candidates: texts)
            let cache = VimeLanguageModel.SuggestionScoreCache()
            KeyboardPerformance.configure(enabled: true, reset: true)
            let scored = try model.scoredNextWords(prompt: prompt, history: history, cache: cache)
            XCTAssertEqual(scored.generated.map(\.text), expectedWords)
            XCTAssertEqual(scored.history.map(\.text), expectedHistory)
            let actual = scored.generated + scored.history
            for (value, sum) in zip(actual, reference) { XCTAssertEqual(value.logProbabilitySum, sum, accuracy: 0.002) }
            let beforeFinal = KeyboardPerformance.report()["lmScoringTokenization"]?["totalCount"]
            XCTAssertEqual(beforeFinal, Double(1 + texts.count + 1),
                "Validate the context, each unique selected continuation and one rejected history entry")
            XCTAssertEqual(cache.tokenizationCount, 1 + texts.count)
            let pool = actual.map { NextWordSuggestion(text: $0.text, source: .contextPrediction, score: 0, userScore: 0) }
            let ranked = model.rerankPostComposition(pool, prompt: prompt, cache: cache)
            XCTAssertEqual(KeyboardPerformance.report()["lmScoringTokenization"]?["totalCount"], beforeFinal,
                "Final ranking must not tokenize any already validated context or continuation")
            XCTAssertEqual(cache.reuses, texts.count)
            XCTAssertEqual(cache.scoringPasses, 0)
            for value in ranked {
                let index = try XCTUnwrap(texts.firstIndex(of: value.text))
                XCTAssertEqual(try XCTUnwrap(value.modelScore), reference[index], accuracy: 0.002)
            }
            print("NEXT_WORD_TOKEN_REUSE", prompt, "validated", beforeFinal ?? 0,
                "finalExtra", (KeyboardPerformance.report()["lmScoringTokenization"]?["totalCount"] ?? 0) - (beforeFinal ?? 0))
            KeyboardPerformance.configure(enabled: false)
        }
    }

    func testSuggestionTokenCacheIsBoundedAndRequiresExactUTF8() throws {
        let model = try VimeLanguageModel(variant: .v21)
        defer { KeyboardPerformance.configure(enabled: false) }
        let cache = VimeLanguageModel.SuggestionScoreCache()
        let expected = try model.scores(context: "", candidates: ["が"]).first
        let actual = try model.scores(context: "", candidates: ["が"], cache: cache).first
        XCTAssertEqual(actual, expected)
        let decomposed = "か\u{3099}"
        let reference = try model.scores(context: "", candidates: [decomposed])
        KeyboardPerformance.configure(enabled: true, reset: true)
        let separate = try model.scores(context: "", candidates: [decomposed], cache: cache)
        XCTAssertEqual(try XCTUnwrap(separate.first), try XCTUnwrap(reference.first), accuracy: 0.0001)
        XCTAssertEqual(cache.tokenizationCount, 3, "Empty context and two distinct UTF-8 spellings")
        XCTAssertEqual(KeyboardPerformance.report()["lmScoringTokenization"]?["totalCount"], 1,
            "A canonically equivalent string must still pass its own exact round trip")
        KeyboardPerformance.configure(enabled: false)
        for index in 0..<(VimeLanguageModel.SuggestionScoreCache.maximumTokenizations + 5) {
            _ = try model.scores(context: "", candidates: ["東京\(index)"], cache: cache)
        }
        XCTAssertEqual(cache.tokenizationCount, VimeLanguageModel.SuggestionScoreCache.maximumTokenizations)
        let saturated = try model.scores(context: "", candidates: ["京都に行く"], cache: cache)
        let uncached = try model.scores(context: "", candidates: ["京都に行く"])
        XCTAssertEqual(try XCTUnwrap(saturated.first), try XCTUnwrap(uncached.first), accuracy: 0.0001,
            "A full token cache still scores new strings correctly")
        weak var released: VimeLanguageModel.SuggestionScoreCache?
        do {
            let request = VimeLanguageModel.SuggestionScoreCache()
            released = request
            _ = try model.scoredNextWords(prompt: "明日は", cache: request)
            XCTAssertGreaterThan(request.tokenizationCount, 0)
        }
        XCTAssertNil(released, "The shared model must not retain a completed request's tokens")
        let fresh = VimeLanguageModel.SuggestionScoreCache()
        KeyboardPerformance.configure(enabled: true, reset: true)
        XCTAssertThrowsError(try model.scoredNextWords(prompt: "明日は", cache: fresh, cancelled: { true }))
        XCTAssertEqual(fresh.tokenizationCount, 0)
        XCTAssertNil(KeyboardPerformance.report()["lmScoringTokenization"])
    }

    func testScoreCacheRevalidatesBoundaryAndPromptAgainstFrozenReferences() throws {
        let model = try VimeLanguageModel(variant: .v21)
        let cache = VimeLanguageModel.SuggestionScoreCache()
        for item in try fixtures().scoring {
            // Individually-scored candidates can have a different common
            // boundary from the final pool. Reuse must preserve frozen scores.
            for text in item.candidates { _ = try model.scores(context: item.context, candidates: [text], cache: cache) }
            let actual = try model.scores(context: item.context, candidates: item.candidates, cache: cache)
            for (value, reference) in zip(actual, item.sums) { XCTAssertEqual(value, reference, accuracy: 0.002) }
        }
        XCTAssertGreaterThan(cache.reuses, 0)
        // Same continuations under another context must not inherit prior scores.
        let candidates = ["飲む", "買う"]
        let cached = try model.scores(context: "朝は", candidates: candidates, cache: cache)
        let fresh = try model.scores(context: "朝は", candidates: candidates)
        for (actual, expected) in zip(cached, fresh) { XCTAssertEqual(actual, expected, accuracy: 0.0001) }
    }
    func testPaddingAndCausality() throws {
        let lm = try VimeLanguageModel(variant: .v21)
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
        let lm = try VimeLanguageModel(variant: .v21)
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
        let lm = try VimeLanguageModel(variant: .v21)
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
        let lm = try VimeLanguageModel(variant: .v21)
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

    func testRerankingUsesValidatedTokensOnceAndKeepsUnsupportedSlots() throws {
        let model = try VimeLanguageModel(variant: .v21)
        let context = "明日は、"
        let texts = ["東京", "▁", String(repeating: "東京", count: 200), "大阪", "京都"]
        let pool = texts.map { text in
            CandidateSnapshot(candidate: Candidate(text: text, value: .zero, composingCount: .inputCount(1),
                lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false), revision: 85,
                source: .rememberedConversion, remainingComposition: ComposingText(),
                originalInputCount: 1, consumedInputCount: 1, queryReading: "ア")
        }
        let supported = [0, 3, 4]
        let sums = try independentScores(model, context: context, candidates: supported.map { texts[$0] })
        let expected = CandidateCompetitionPolicy.applying(sums, slots: supported, to: pool)
        let trace = CandidatePipelineTrace(revision: 85, consumedInputCount: 1)
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        let actual = model.rerank(pool, context: context, katakana: false, trace: trace, cancelled: { false })
        XCTAssertEqual(actual.map(\.presentation), expected.map(\.presentation))
        for (value, reference) in zip(actual, expected) {
            XCTAssertEqual(value.features.languageModel, reference.features.languageModel, accuracy: 0.002)
        }
        XCTAssertEqual(trace.snapshot()[.supported]?.count, supported.count)
        XCTAssertEqual(trace.snapshot()[.scored]?.count, supported.count)
        XCTAssertEqual(KeyboardPerformance.report()["lmScoringTokenization"]?["totalCount"], Double(texts.count + 1),
            "One round trip per candidate and one for the context, including rejected entries")
        XCTAssertEqual(actual[1].presentation, pool[1].presentation)
        XCTAssertEqual(actual[2].presentation, pool[2].presentation)
        KeyboardPerformance.configure(enabled: true, reset: true)
        XCTAssertEqual(model.rerank(pool, context: context, katakana: false, cancelled: { true }).map(\.presentation), pool.map(\.presentation))
        XCTAssertNil(KeyboardPerformance.report()["lmScoringTokenization"], "Cancelled input must not start tokenization")
        XCTAssertNil(KeyboardPerformance.report()["lmScoringPrediction"])
    }

    func testPostCompositionReusesValidatedTokensAndMatchesIndependentScores() throws {
        let model = try VimeLanguageModel(variant: .v21)
        let prompt = "コーヒーを"
        let unique = ["買う", "飲む", "飲みたい"]
        let reference = try independentScores(model, context: prompt, candidates: unique)
        let texts = [unique[0], "▁", String(repeating: "東京", count: 200), unique[1], unique[2], unique[1], "▁"]
        let pool = texts.map { NextWordSuggestion(text: $0, source: .contextPrediction, score: -100, userScore: 0) }
        let supported = [0, 3, 4, 5]
        let sums = [reference[0], reference[1], reference[2], reference[1]]
        let order = sums.indices.sorted { sums[$0] == sums[$1] ? $0 < $1 : sums[$0] > sums[$1] }
        var expected = pool
        for (rank, index) in order.enumerated() {
            expected[supported[index]].modelScore = sums[index]
            expected[supported[index]].score = PostCompositionSuggestionReranker.Policy.sourceEvidence
                - PostCompositionSuggestionReranker.Policy.orderCost * log1p(Double(rank))
        }
        expected = expected.indices.sorted {
            expected[$0].score == expected[$1].score ? $0 < $1 : expected[$0].score > expected[$1].score
        }.map { expected[$0] }
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        let actual = model.rerankPostComposition(pool, prompt: prompt)
        XCTAssertEqual(actual.map(\.text), expected.map(\.text))
        for (value, target) in zip(actual, expected) {
            XCTAssertEqual(value.score, target.score)
            if let sum = target.modelScore { XCTAssertEqual(try XCTUnwrap(value.modelScore), sum, accuracy: 0.002) }
            else { XCTAssertNil(value.modelScore) }
        }
        XCTAssertEqual(KeyboardPerformance.report()["lmScoringTokenization"]?["totalCount"], 6,
            "Context plus five unique continuations; invalid and valid duplicates are checked once")
        KeyboardPerformance.configure(enabled: true, reset: true)
        XCTAssertEqual(model.rerankPostComposition(pool, prompt: prompt, cancelled: { true }).map(\.text), texts)
        XCTAssertNil(KeyboardPerformance.report()["lmScoringTokenization"])
        XCTAssertNil(KeyboardPerformance.report()["lmScoringPrediction"])
        var checks = 0
        _ = model.rerankPostComposition(pool, prompt: prompt, cancelled: { checks += 1; return checks >= 3 })
        XCTAssertEqual(KeyboardPerformance.report()["lmScoringTokenization"]?["totalCount"], 2,
            "Cancellation during validation stops before the second continuation")
        XCTAssertNil(KeyboardPerformance.report()["lmScoringPrediction"])
    }

    func testSentenceInitialRerankingMatchesFrozenBOSScoresAndProtectsLearnedLeader() throws {
        let model = try VimeLanguageModel(variant: .v21)
        let fixture = try XCTUnwrap(try fixtures().scoring.first { $0.context.isEmpty })
        let texts = Array(fixture.candidates.reversed()), sums = Array(fixture.sums.reversed())
        var pool = texts.map { text in
            CandidateSnapshot(candidate: Candidate(text: text, value: .zero, composingCount: .inputCount(1),
                lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false), revision: 86,
                source: .rememberedConversion, remainingComposition: ComposingText(),
                originalInputCount: 1, consumedInputCount: 1, queryReading: "トウキョウ")
        }
        let expected = CandidateCompetitionPolicy.applying(sums, slots: Array(pool.indices), to: pool)
        let actual = model.rerank(pool, context: "", katakana: false, cancelled: { false })
        XCTAssertEqual(actual.map(\.presentation), expected.map(\.presentation))
        for (value, reference) in zip(actual, expected) {
            XCTAssertEqual(value.features.languageModel, reference.features.languageModel, accuracy: 0.002)
        }
        pool[0].userPreferenceConfidence = 1
        pool[0].userPreferenceScore = CandidatePreferenceMemory.Policy.maximumChoiceBonus
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        XCTAssertEqual(model.rerank(pool, context: "", katakana: false, cancelled: { false }).map(\.presentation), pool.map(\.presentation))
        XCTAssertNil(KeyboardPerformance.report()["lmScoringPrediction"], "A confirmed sentence-initial personal leader keeps its order")
        XCTAssertNil(KeyboardPerformance.report()["lmScoringTokenization"])
    }
    func testNextWordsAreShortAndStopBeforePunctuation() throws {
        let lm = try VimeLanguageModel(variant: .v21)
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
        host.updatePreedit(session.markedText)
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
