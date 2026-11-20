import XCTest
@testable import Vime

/// Sentence corrections: where the slip is looked for, how options are
/// weighed, and the batched prefix scoring they run on.
final class ChineseSentenceCorrectionTests: XCTestCase {
    typealias Correction = ChineseSentenceCorrection

    private func candidate(_ text: String, covers: Bool = true) -> RimeCandidate {
        RimeCandidate(text: text, comment: nil, coversInput: covers, sentence: true)
    }

    // MARK: Prefix scoring

    nonisolated(unsafe) private static var cachedModel: ChineseLanguageModel?
    private func chinese() throws -> ChineseLanguageModel {
        if let model = Self.cachedModel { return model }
        let model = try ChineseLanguageModel(bundle: Bundle(for: Self.self))
        Self.cachedModel = model
        return model
    }

    /// Each text alone, the whole sequence in one row with nothing shared:
    /// the log probabilities of its tokens after where it parts from the context.
    private func unshared(context: String, texts: [String], model: ChineseLanguageModel) throws -> [Double] {
        let contextIDs = [Int32(2)] + (context.isEmpty ? [] : try model.tokenizer.encode(context))
        let empty = try model.batch.prefix([])
        return try texts.map { text in
            let sequence = [Int32(2)] + (try model.tokenizer.encode(context + text))
            var start = 0
            while start < min(contextIDs.count, sequence.count), contextIDs[start] == sequence[start] { start += 1 }
            let values = try model.batch.scores(after: empty, rows: [sequence])[0]
            // Entry i scores token i + 1.
            return values.enumerated().reduce(0.0) { $0 + ($1.offset + 1 >= start ? Double($1.element) : 0) }
        }
    }

    func testPrefixScoringMatchesEachSentenceAlone() throws {
        let model = try chinese()
        let texts = ["想去看电影", "想去看点硬", "想去看电影了吗", "下雨了", "想去看电影"]
        for context in ["", "我今天"] {
            let expected = try unshared(context: context, texts: texts, model: model)
            let scores = try ChinesePrefixScoring.scores(context: context, candidates: texts, model: model.batch,
                                                         tokenizer: model.tokenizer)
            XCTAssertEqual(scores.count, texts.count)
            for (score, reference) in zip(scores, expected) { XCTAssertEqual(score, reference, accuracy: 1e-3, context) }

            // A floor below a score keeps it exact; one above stops it.
            let floors = expected.enumerated().map { $0.offset.isMultiple(of: 2) ? $0.element - 0.5 : $0.element + 0.5 }
            let pruned = try ChinesePrefixScoring.scores(context: context, candidates: texts, floors: floors,
                                                         model: model.batch, tokenizer: model.tokenizer)
            for (index, score) in pruned.enumerated() {
                if index.isMultiple(of: 2) { XCTAssertEqual(score, expected[index], accuracy: 1e-3) }
                else { XCTAssertEqual(score, -.infinity, texts[index]) }
            }
        }
    }

    /// VimeML's fixture for `score`: the shared prefix once, every
    /// continuation's tokens in one call per 16.
    func testScoreFunctionMatchesVimeMLFixture() throws {
        struct Case: Decodable {
            let context: String
            let candidates: [String]
            let prefix_ids: [Int32]
            let continuation_ids: [[Int32]]
            let scores_package: [Double]
            let calls: Int
        }
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "KVBatchV4Fixture-fp32kv-score", withExtension: "jsonl"))
        let cases = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
        XCTAssertEqual(cases.count, 8)
        // A fresh package, to see which functions load.
        let chinese = try ChineseLanguageModel(bundle: bundle, version: .v1)
        let model = chinese.batch
        XCTAssertEqual(model.maximumBatch, 16)
        for item in cases {
            let before = model.predictions
            let prefix = try model.prefix(Array(item.prefix_ids.dropLast()))
            let tokens = try model.scores(after: prefix, rows: item.continuation_ids.map { [item.prefix_ids.last!] + $0 })
            XCTAssertEqual(model.predictions - before, item.calls, item.context)
            for (values, expected) in zip(tokens, item.scores_package) {
                XCTAssertEqual(values.reduce(0) { $0 + Double($1) }, expected, accuracy: 1e-3, item.candidates.joined(separator: " "))
            }
            let scores = try ChinesePrefixScoring.scores(context: item.context, candidates: item.candidates, model: model,
                                                         tokenizer: chinese.tokenizer)
            for (score, expected) in zip(scores, item.scores_package) { XCTAssertEqual(score, expected, accuracy: 1e-3) }
        }
        XCTAssertEqual(model.loadedFunctions, [.prefix, .score])
    }

    func testScoringManyRowsMatchesEachSentenceAlone() throws {
        let model = try chinese()
        // More than one call's worth, of different lengths.
        let texts = (0..<20).map { "我想去看第\($0)场电影" + String(repeating: "了", count: $0 % 4) } + ["下雨了"]
        for context in ["", "晚上一起吃饭吗"] {
            let expected = try unshared(context: context, texts: texts, model: model)
            let scores = try ChinesePrefixScoring.scores(context: context, candidates: texts, model: model.batch,
                                                         tokenizer: model.tokenizer)
            for (score, reference) in zip(scores, expected) { XCTAssertEqual(score, reference, accuracy: 1e-3, context) }
            let floors = expected.enumerated().map { $0.offset.isMultiple(of: 2) ? $0.element - 0.5 : $0.element + 0.5 }
            let pruned = try ChinesePrefixScoring.scores(context: context, candidates: texts, floors: floors,
                                                         model: model.batch, tokenizer: model.tokenizer)
            for (index, score) in pruned.enumerated() where !index.isMultiple(of: 2) { XCTAssertEqual(score, -.infinity) }
        }
    }

    /// The row tokens a call may take change how many calls run, not what they score.
    func testScoringStaysWithinItsRowTokens() throws {
        let chinese = try ChineseLanguageModel(bundle: Bundle(for: Self.self))
        let model = chinese.batch
        let texts = (0..<16).map { "我想去看第\($0)场电影然后顺便吃个晚饭再回家休息一下明天还要早起" }
        let context = "我们今天下午三点在公司楼下的咖啡店见面"
        XCTAssertGreaterThan(model.rowTokens(), 0)
        let expected = try unshared(context: context, texts: texts, model: chinese)
        var calls: [Int] = []
        for limit in [Int?.none, 1 << 20, 1] {
            model.forgetPrefix()
            model.rowTokenLimit = limit
            let before = model.predictions
            let scores = try ChinesePrefixScoring.scores(context: context, candidates: texts, model: model,
                                                         tokenizer: chinese.tokenizer)
            calls.append(model.predictions - before)
            for (score, reference) in zip(scores, expected) { XCTAssertEqual(score, reference, accuracy: 1e-3) }
        }
        XCTAssertEqual(calls[1], 2, "unbounded: the shared prefix, then every row at once")
        XCTAssertGreaterThanOrEqual(calls[0], calls[1])
        XCTAssertEqual(calls[2], 1 + texts.count, "one row a call")
    }

    // MARK: The reranking scores

    /// Reranking sums every candidate from where the first of them parts
    /// from the context, so a candidate that merges with the context's last
    /// character compares over the same tokens as the others.
    func testRerankingScoresShareTheirStart() throws {
        let model = try chinese()
        let context = "我们明天去", texts = ["实验", "试验", "市演", "上海"]
        let scores = try model.scores(context: context, candidates: texts)
        let shared = try ChinesePrefixScoring.scores(context: context, candidates: texts, sharedStart: true,
                                                     model: model.batch, tokenizer: model.tokenizer)
        for (score, reference) in zip(scores, shared) { XCTAssertEqual(score, reference, accuracy: 1e-9) }
        // One candidate: its own start is the shared one.
        for text in texts {
            XCTAssertEqual(try model.scores(context: context, candidates: [text])[0],
                           try unshared(context: context, texts: [text], model: model)[0], accuracy: 1e-3, text)
        }
        XCTAssertThrowsError(try model.scores(context: context, candidates: ["实验", "实验"]), "repeats are ineligible")
        XCTAssertThrowsError(try model.scores(context: context, candidates: ["实验"], cancelled: { true }))
    }

    func testTokenScoresAddUpToTheScore() throws {
        let model = try chinese()
        for (context, text) in [("", "今天天气很好"), ("我们明天去", "实验室做实验")] {
            let tokens = try model.tokenScores(context: context, text: text)
            XCTAssertFalse(tokens.isEmpty)
            XCTAssertEqual(tokens.reduce(0) { $0 + $1.logProbability },
                           try model.scores(context: context, candidates: [text])[0], accuracy: 1e-3)
            XCTAssertTrue(tokens.allSatisfy { $0.logProbability <= 0 })
            XCTAssertTrue(text.hasSuffix(tokens.last!.text))
        }
    }

    // MARK: Where to look

    func testWindowsFollowTheWeakestTokens() throws {
        let lexicon = try XCTUnwrap(ChinesePinyinLexicon.bundled, "RimeData.bundle is not bundled")
        // 我 wo, 想 xiang, 去 qu.
        let tokens: [(text: String, logProbability: Double)] = [("我", -0.5), ("想", -6), ("去", -0.2)]
        XCTAssertEqual(Correction.windows(tokens: tokens, text: "我想去", input: "woxiangqu", lexicon: lexicon), [1...8, -1...3])
        XCTAssertNil(Correction.windows(tokens: tokens, text: "我想去", input: "nihao", lexicon: lexicon),
                     "letters the sentence does not spell: everywhere")
        XCTAssertNil(Correction.windows(tokens: [("我想", -1)], text: "我想去", input: "woxiangqu", lexicon: lexicon),
                     "tokens that do not make up the sentence")
    }

    func testSpellingsEditOnlyInsideTheWindows() {
        let all = Correction.spellings(for: "woxiangqu", windows: nil)
        XCTAssertFalse(all.isEmpty)
        let late = Correction.spellings(for: "woxiangqu", windows: [7...9])
        XCTAssertFalse(late.isEmpty)
        XCTAssertLessThan(late.count, all.count)
        for item in late {
            let typed = Array("woxiangqu"), letters = Array(item.spelling)
            var at = 0
            while at < min(typed.count, letters.count), typed[at] == letters[at] { at += 1 }
            XCTAssertTrue((7...9).contains(at), item.spelling)
        }
    }

    func testTheLastLetterIsNeverDropped() {
        // A lone initial at the end is the next syllable starting; dropping
        // it shortened the lead a moment after each such key.
        for input in ["jintiantianqihenhaok", "woxiangqumaidongxim", "nihaom"] {
            let spellings = Correction.spellings(for: input, windows: nil)
            XCTAssertFalse(spellings.isEmpty, input)
            XCTAssertFalse(spellings.contains { $0.spelling == String(input.dropLast()) }, input)
        }
    }

    // MARK: Weighing

    func testOptionsKeepWholeConversionsOnce() {
        let found: [(spelling: String, candidates: [RimeCandidate])] = [
            ("woxiangqu", [candidate("我想去"), candidate("我想取")]),
            ("woxiangwu", [candidate("wo", covers: false), candidate("我想屋"), candidate("我想去"), candidate("我想无"), candidate("我想舞")]),
            ("unknown", [candidate("未知")]),
        ]
        let options = Correction.options(found, edits: ["woxiangqu": .neighbour, "woxiangwu": .swap],
                                         literal: "我想去", allows: { $0 != "我想无" })
        XCTAssertEqual(options.map(\.candidate.text), ["我想取", "我想屋"],
                       "the literal never, a spelling's first two whole conversions, spellings without an edit never")
        XCTAssertEqual(options.map(\.rank), [1, 0])
        XCTAssertEqual(options[0].penalty, Correction.penalties[.neighbour]! + Correction.placePenalty, accuracy: 1e-9)
    }

    func testCorrectionsShowSecondAndLeadOnlyByAClearMargin() {
        let drop = Correction.Option(spelling: "a", edit: .drop, rank: 0, candidate: candidate("甲"))
        let swap = Correction.Option(spelling: "b", edit: .swap, rank: 0, candidate: candidate("乙"))
        let literal = -20.0
        XCTAssertNil(Correction.decide(literal: literal, text: "丙丁", options: [drop, swap], scores: [-21, -18]),
                     "a swap pays its penalty")
        XCTAssertNil(Correction.decide(literal: literal, text: "丙丁", options: [drop], scores: [-19]),
                     "a narrow win does not show")
        let second = Correction.decide(literal: literal, text: "丙丁", options: [drop, swap], scores: [-16, -30])
        XCTAssertEqual(second?.option, drop)
        XCTAssertEqual(second?.leads, false)
        let first = Correction.decide(literal: literal, text: "丙丁", options: [drop, swap], scores: [-16, -10])
        XCTAssertEqual(first?.option, swap)
        XCTAssertEqual(first?.leads, true, "beats the sentence by 10 - 3")
        XCTAssertNil(Correction.decide(literal: literal, text: "丙丁", options: [drop], scores: [-.infinity]), "stopped by its floor")
        // The floor is exactly where an option stops being able to show.
        XCTAssertNil(Correction.decide(literal: literal, text: "丙丁", options: [swap], scores: [Correction.floor(literal: literal, option: swap)]))
        XCTAssertNotNil(Correction.decide(literal: literal, text: "丙丁", options: [swap],
                                          scores: [Correction.floor(literal: literal, option: swap) + 0.01]))
    }

    func testACorrectionOfOnlyTheLastCharacterNeverLeads() {
        XCTAssertTrue(Correction.changesOnlyTheEnd("我想去", of: "我想区"))
        XCTAssertTrue(Correction.changesOnlyTheEnd("我想", of: "我想区"), "one shorter")
        XCTAssertTrue(Correction.changesOnlyTheEnd("我想去哪", of: "我想区"))
        XCTAssertFalse(Correction.changesOnlyTheEnd("我像去", of: "我想区"))
        let end = Correction.Option(spelling: "woxiangqu", edit: .neighbour, rank: 0, candidate: candidate("我想去"))
        let middle = Correction.Option(spelling: "woxianqu", edit: .drop, rank: 0, candidate: candidate("我先去"))
        let decision = Correction.decide(literal: -20, text: "我想区", options: [end], scores: [-5])
        XCTAssertEqual(decision?.option, end)
        XCTAssertEqual(decision?.leads, false, "it still shows second")
        XCTAssertEqual(Correction.decide(literal: -20, text: "我想区", options: [middle], scores: [-5])?.leads, true)
    }

    func testOnlyPlainLettersOfASearchedLengthAreSearched() {
        XCTAssertTrue(Correction.wants("woxiangqu"))
        XCTAssertFalse(Correction.wants("wo"))
        XCTAssertFalse(Correction.wants("wo'xiang"))
        XCTAssertFalse(Correction.wants(String(repeating: "a", count: 49)))
    }
}
