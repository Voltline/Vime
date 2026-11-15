import XCTest
@testable import Vime

/// Constrained generation with the bundled zh-v1 KV package and Rime's
/// dictionary, then rescoring with the stateless package.
final class ChineseSentenceGenerationTests: XCTestCase {
    typealias Generation = ChineseConstrainedGeneration

    struct Setup {
        let kv: VimeKVLanguageModel
        let stateless: VimeLanguageModel
        let lexicon: ChinesePinyinLexicon
        let vocabulary: Generation.Vocabulary
        /// The zh-v1 batched KV package (kvbatch-v2): prompts in one call,
        /// allowed tokens scored only.
        let batched: ChineseKVGenerator
    }
    nonisolated(unsafe) private static var cached: Setup?

    func setup() throws -> Setup {
        if let cached = Self.cached { return cached }
        let bundle = Bundle(for: Self.self)
        let stateless = try VimeLanguageModel(bundle: bundle, variant: .zhV1)
        let kv = try VimeKVLanguageModel(bundle: bundle, tokenizer: stateless.tokenizer)
        let lexicon = try XCTUnwrap(ChinesePinyinLexicon.bundled, "RimeData.bundle is not bundled")
        let setup = Setup(kv: kv, stateless: stateless, lexicon: lexicon,
                          vocabulary: Generation.Vocabulary(tokenizer: kv.tokenizer, size: kv.vocabularySize, lexicon: lexicon),
                          batched: ChineseKVGenerator(batch: try VimeKVBatchLanguageModel(bundle: bundle)))
        Self.cached = setup
        return setup
    }

    func generate(_ keys: String, context: String = "", beam: Int = 16, count: Int = 10) throws -> [Generation.Result] {
        let s = try setup()
        let prompt = try Generation.prompt(.lm, context: context, keys: keys, tokenizer: s.kv.tokenizer)
        return try Generation.generate(model: s.kv, vocabulary: s.vocabulary, lexicon: s.lexicon,
            keys: try XCTUnwrap(ChinesePinyinKeys(keys)), prompt: prompt, mode: .lm,
            parameters: .init(beam: beam, count: count))
    }

    private func candidates(_ keys: String, context: String = "", scorer: Bool = true,
                            allows: (String) -> Bool = { _ in true },
                            cancelled: () -> Bool = { false }) throws -> [ChineseSentenceGeneration.Candidate]? {
        let s = try setup()
        return ChineseSentenceGeneration.candidates(keys: keys, leftContext: context, generator: s.kv,
            tokenizer: s.kv.tokenizer, vocabulary: s.vocabulary, lexicon: s.lexicon,
            scorer: scorer ? s.stateless : nil, allows: allows, cancelled: cancelled)
    }

    func testTheDictionaryComesFromRimesTable() throws {
        let s = try setup()
        XCTAssertGreaterThan(s.lexicon.readings.count, 8000)
        XCTAssertEqual(s.lexicon.readings["中"], ["zhong"])
        XCTAssertTrue(s.lexicon.readings["行"]?.isSuperset(of: ["xing", "hang"]) ?? false)
        XCTAssertTrue(s.lexicon.readings["绿"]?.contains("lv") ?? false, "ü is written v, as Rime spells it")
        XCTAssertGreaterThan(s.vocabulary.usableCount, 8000)
        XCTAssertTrue(s.vocabulary.characters[Int(try s.kv.tokenizer.encode("中文")[0])] == ["中", "文"])
        XCTAssertTrue(s.vocabulary.characters[Int(try s.kv.tokenizer.encode("，")[0])].isEmpty)
    }

    func testPromptsForBothModes() throws {
        let tokenizer = try setup().kv.tokenizer
        let context = try tokenizer.encode("今天"), keys = try tokenizer.encode("nihao")
        XCTAssertEqual(try Generation.prompt(.task, context: "今天", keys: "nihao", tokenizer: tokenizer),
                       [2, 4] + context + [5] + keys + [6])
        XCTAssertEqual(try Generation.prompt(.lm, context: "今天", keys: "nihao", tokenizer: tokenizer), [2] + context)
        XCTAssertEqual(try Generation.prompt(.lm, context: "", keys: "nihao", tokenizer: tokenizer), [2])
        XCTAssertEqual(try Generation.prompt(.task, context: "", keys: "nihao", tokenizer: tokenizer), [2, 4, 5] + keys + [6])
    }

    func testEverySentenceSpellsTheKeys() throws {
        let s = try setup()
        for keys in ["nihao", "zhongwenshurufa", "jintiantianqihenhao", "wmmtjm", "xi'an", "zhshm"] {
            let results = try generate(keys)
            XCTAssertFalse(results.isEmpty, keys)
            XCTAssertEqual(Set(results.map(\.text)).count, results.count, "distinct texts")
            XCTAssertEqual(results.map(\.score), results.map(\.score).sorted(by: >))
            let spelling = Generation.Spelling(keys: ChinesePinyinKeys(keys)!, lexicon: s.lexicon, vocabulary: s.vocabulary)
            for result in results {
                let characters = Array(result.text.unicodeScalars)
                XCTAssertTrue(characters.allSatisfy { s.lexicon.contains($0) }, result.text)
                XCTAssertTrue(spelling.ends(of: characters, from: 0).contains(spelling.keys.count), "\(keys) → \(result.text)")
                XCTAssertEqual(result.tokens.flatMap { s.vocabulary.characters[Int($0)] }, characters)
            }
        }
    }

    func testFindsTheObviousSentence() throws {
        for (keys, text) in [("nihao", "你好"), ("zhongwenshurufa", "中文输入法"), ("zwsrf", "中文输入法"),
                             ("jintiantianqihenhao", "今天天气很好"), ("woxiangchifan", "我想吃饭")] {
            let found = try generate(keys).map(\.text)
            XCTAssertEqual(found.first, text, "\(keys): \(found)")
        }
    }

    func testUnreachableKeysFallBack() throws {
        XCTAssertThrowsError(try generate("iiii")) { XCTAssertEqual($0 as? Generation.Failure, .unreachable) }
        XCTAssertNil(try candidates("iiii"))
        XCTAssertNil(try candidates("ni hao"))
        XCTAssertNil(try candidates("nihao", cancelled: { true }))
    }

    func testRescoringUsesTheContextAndKeepsGenerationScores() throws {
        let generated = try generate("shiyan", context: "我们明天去")
        let rescored = try XCTUnwrap(try candidates("shiyan", context: "我们明天去"))
        XCTAssertEqual(Set(rescored.map(\.text)), Set(generated.map(\.text)))
        let model = try setup().stateless.scores(context: "我们明天去", candidates: rescored.map(\.text))
        for (candidate, score) in zip(rescored, model) {
            XCTAssertEqual(try XCTUnwrap(candidate.modelScore), score, accuracy: 1e-9)
            XCTAssertEqual(candidate.score, candidate.generationScore + 1.6 * score, accuracy: 1e-9)
        }
        XCTAssertEqual(rescored.map(\.score), rescored.map(\.score).sorted(by: >))
        // Without the reranking model, the generation alone orders them.
        let alone = try XCTUnwrap(try candidates("shiyan", context: "我们明天去", scorer: false))
        XCTAssertEqual(alone.map(\.text), generated.map(\.text))
        XCTAssertTrue(alone.allSatisfy { $0.modelScore == nil })
    }

    func testGeneratedSentencesGoThroughTheExclusions() throws {
        let top = try XCTUnwrap(try generate("nihao").first?.text)
        let list = LearningExclusionList(data: LearningExclusionList.encode(blocked: [top], allowed: []))
        let active = try XCTUnwrap(try candidates("nihao") {
            LearningExclusionPolicy.allowsLearning($0, active: true, list: list)
        })
        XCTAssertFalse(active.contains { $0.text.contains(top) })
        let inactive = try XCTUnwrap(try candidates("nihao") {
            LearningExclusionPolicy.allowsLearning($0, active: false, list: list)
        })
        XCTAssertTrue(inactive.contains { $0.text == top })
        XCTAssertNil(try candidates("nihao") { _ in false }, "nothing left: Rime's candidates stay")
    }

    func testTheRequestDeadlineStopsGeneration() throws {
        let request = ChineseCandidateRanking.Request(deadline: ProcessInfo.processInfo.systemUptime)
        XCTAssertNil(try candidates("zhongwenshurufa", cancelled: { request.isCancelled }))
    }

    // MARK: Alignment with VimeML

    /// VimeML's reference (vime_zh_generation_fixture_v1, r2): the same search
    /// in lm mode with the FP32 PyTorch checkpoint, 125 cases.
    private struct Fixtures: Decodable {
        struct Search: Decodable { let mode: String; let beam: Int; let topk: Int; let token_limit: Int }
        struct Case: Decodable {
            struct Top: Decodable { let text: String; let ids: [Int32]; let gen_score: Double }
            let id: String
            let kind: String
            let keys: String
            let context: String
            let prompt_ids: [Int32]
            let top: [Top]
            let v1_context_scores: [Double]
        }
        let format: String
        let tokenizer_sha256: String
        let search: Search
        let cases: [Case]
    }

    private func fixtures() throws -> Fixtures {
        guard let url = Bundle(for: Self.self).url(forResource: "VimeMLGenerationFixturesZhV1", withExtension: "json") else {
            throw XCTSkip("VimeMLGenerationFixturesZhV1.json is not bundled")
        }
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.format, "vime_zh_generation_fixture_v1")
        XCTAssertEqual(fixtures.search.mode, "lm")
        XCTAssertEqual(fixtures.search.beam, ChineseSentenceGeneration.parameters.beam)
        XCTAssertEqual(fixtures.search.topk, ChineseSentenceGeneration.parameters.count)
        XCTAssertEqual(fixtures.search.token_limit, ChineseSentenceGeneration.parameters.maximumLength)
        return fixtures
    }

    /// Every sentence VimeML found is one this search could find: the same
    /// prompt, usable tokens, a spelling of the keys under the same rules.
    func testVimeMLSentencesFollowTheSameRules() throws {
        let fixtures = try fixtures(), s = try setup()
        for item in fixtures.cases {
            let context = VimeLanguageModel.sentenceContext(item.context)
            XCTAssertEqual(try Generation.prompt(.lm, context: context, keys: item.keys, tokenizer: s.kv.tokenizer),
                           item.prompt_ids, "\(item.id) prompt")
            let keys = try XCTUnwrap(ChinesePinyinKeys(item.keys))
            let spelling = Generation.Spelling(keys: keys, lexicon: s.lexicon, vocabulary: s.vocabulary)
            for top in item.top {
                XCTAssertTrue(top.ids.allSatisfy { !s.vocabulary.characters[Int($0)].isEmpty }, "\(item.id) \(top.text) tokens")
                let characters = top.ids.flatMap { s.vocabulary.characters[Int($0)] }
                XCTAssertEqual(String(String.UnicodeScalarView(characters)), top.text)
                XCTAssertTrue(spelling.ends(of: characters, from: 0).contains(keys.count), "\(item.id) \(top.text) spelling")
            }
        }
    }

    /// The generation scores VimeML reports are the model's log probability
    /// of each sentence: within INT8 noise of what the KV package gives.
    /// Rows where VimeML's own `v1_context_scores` disagree with its
    /// generation score are left out (r1 had 171; r1 is withdrawn).
    func testGenerationScoresMatchVimeMLWhereItIsConsistent() throws {
        let fixtures = try fixtures(), s = try setup()
        var checked = 0
        for item in fixtures.cases {
            for (top, check) in zip(item.top, item.v1_context_scores) where abs(top.gen_score - check) < 0.01 {
                var step = try s.kv.forward(item.prompt_ids)
                var score = 0.0
                for id in top.ids {
                    score += Double(step.logits[Int(id)]) - (try Generation.logNormalizer(step.logits))
                    step = try s.kv.forward([id], after: step.cache)
                }
                XCTAssertEqual(score, top.gen_score, accuracy: max(0.75, 0.005 * abs(top.gen_score)), "\(item.id) \(top.text)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    /// The search itself against VimeML's top 10. Set VIME_GENERATION_REPORT
    /// to a path for the differences.
    /// FP32 there, INT8 here: VimeML expects the same texts, scores within
    /// about 0.5 (0.56 seen) and rare swaps of near-tied neighbours.
    func testMatchesVimeMLReference() throws {
        let fixtures = try fixtures(), s = try setup()
        var report: [String] = [], sameTop = 0, overlap = 0, worst = 0.0
        for item in fixtures.cases {
            let context = VimeLanguageModel.sentenceContext(item.context)
            let prompt = try Generation.prompt(.lm, context: context, keys: item.keys, tokenizer: s.kv.tokenizer)
            XCTAssertEqual(prompt, item.prompt_ids, "\(item.id) prompt")
            let found = try generate(item.keys, context: context, beam: fixtures.search.beam, count: fixtures.search.topk)
            let expected = Dictionary(uniqueKeysWithValues: item.top.map { ($0.text, $0) })
            let shared = found.filter { expected[$0.text] != nil }
            // A text can come from more than one token sequence; INT8 noise may pick another of near-equal score.
            for result in shared {
                let reference = expected[result.text]!
                worst = max(worst, abs(result.score - reference.gen_score))
                XCTAssertEqual(result.score, reference.gen_score, accuracy: 0.75, "\(item.id) \(result.text)")
            }
            XCTAssertTrue(found.prefix(3).contains { $0.text == item.top.first?.text },
                          "\(item.id): \(found.map(\.text)) vs \(item.top.map(\.text))")
            if found.first?.text == item.top.first?.text { sameTop += 1 }
            overlap += shared.count
            if shared.count < item.top.count || found.first?.text != item.top.first?.text {
                report.append("\(item.id) shared \(shared.count)/\(item.top.count) found \(found.map(\.text)) expected \(item.top.map(\.text))")
            }
            if ProcessInfo.processInfo.environment["VIME_GENERATION_DUMP"] != nil,
               let line = try? JSONSerialization.data(withJSONObject: ["id": item.id, "found": found.map { ["text": $0.text, "score": $0.score, "ids": $0.tokens.map(Int.init)] }]) {
                report.append("DUMP " + String(decoding: line, as: UTF8.self))
            }
        }
        report.insert("cases \(fixtures.cases.count) same top \(sameTop) shared \(overlap)/\(fixtures.cases.reduce(0) { $0 + $1.top.count }) worst score difference \(worst)", at: 0)
        if let path = ProcessInfo.processInfo.environment["VIME_GENERATION_REPORT"] {
            try? report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThanOrEqual(Double(sameTop), 0.95 * Double(fixtures.cases.count), report[0])
        XCTAssertGreaterThanOrEqual(Double(overlap), 0.95 * Double(fixtures.cases.reduce(0) { $0 + $1.top.count }), report[0])
    }

    /// The reranking scores VimeML computed for its top texts, one joint call each.
    func testContextScoresMatchVimeML() throws {
        let fixtures = try fixtures(), s = try setup()
        for item in fixtures.cases {
            let scores = try s.stateless.scores(context: VimeLanguageModel.sentenceContext(item.context),
                                                candidates: item.top.map(\.text))
            for (index, score) in scores.enumerated() {
                let expected = item.v1_context_scores[index]
                XCTAssertEqual(score, expected, accuracy: max(0.75, 0.005 * abs(expected)), "\(item.id) \(item.top[index].text)")
            }
        }
    }

    // MARK: Forward only, kept across keystrokes

    private func incremental<Model: ChineseScoringModel>(_ model: Model, context: String = "", beam: Int = 16,
                                                         count: Int = 10) throws -> ChineseIncrementalGeneration<Model> {
        let s = try setup()
        let prompt = try Generation.prompt(.lm, context: context, keys: "", tokenizer: s.kv.tokenizer)
        return try ChineseIncrementalGeneration(model: model, vocabulary: s.vocabulary, lexicon: s.lexicon, prompt: prompt,
                                                parameters: .init(beam: beam, count: count))
    }

    /// Typed one key at a time; the results after the last.
    private func typed<Model: ChineseScoringModel>(_ keys: String, on engine: ChineseIncrementalGeneration<Model>)
        throws -> [Generation.Result] {
        var results: [Generation.Result] = []
        for end in 1...keys.count {
            guard let prefix = ChinesePinyinKeys(String(keys.prefix(end))) else { continue }
            results = try engine.update(prefix)
        }
        return results
    }

    /// Same texts; scores within what attention over more or fewer cache slots changes.
    private func assertSame(_ a: [Generation.Result], _ b: [Generation.Result], _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(a.map(\.text)), Set(b.map(\.text)), message, file: file, line: line)
        XCTAssertEqual(a.first?.text, b.first?.text, message, file: file, line: line)
        let scores = Dictionary(b.map { ($0.text, $0.score) }, uniquingKeysWith: max)
        for result in a { XCTAssertEqual(result.score, scores[result.text] ?? 0, accuracy: 1e-3, message, file: file, line: line) }
    }

    func testTypingFindsTheObviousSentence() throws {
        let s = try setup()
        let engine = try incremental(s.batched)
        for (keys, text) in [("nihao", "你好"), ("zhongwenshurufa", "中文输入法"), ("zwsrf", "中文输入法"),
                             ("jintiantianqihenhao", "今天天气很好"), ("woxiangchifan", "我想吃饭")] {
            XCTAssertEqual(try typed(keys, on: engine).first?.text, text, keys)
        }
    }

    func testTypingKeyByKeyMatchesAllAtOnce() throws {
        let s = try setup()
        let typing = try incremental(s.batched, context: "今天")
        for keys in ["women", "womenqugongyuansanbu", "wmqgy", "xi'an"] {
            let found = try typed(keys, on: typing)
            assertSame(found, try incremental(s.batched, context: "今天").update(XCTUnwrap(ChinesePinyinKeys(keys))), keys)
        }
        // Backspace and typing the same key again cost no model call.
        _ = try typing.update(XCTUnwrap(ChinesePinyinKeys("womenqugongyuan")))
        let calls = s.batched.batch.predictions
        let short = try typing.update(XCTUnwrap(ChinesePinyinKeys("womenqugongyua")))
        XCTAssertEqual(try typing.update(XCTUnwrap(ChinesePinyinKeys("womenqugongyuan"))).first?.text, "我们去公园")
        XCTAssertFalse(short.isEmpty)
        XCTAssertEqual(s.batched.batch.predictions, calls)
    }

    func testBatchedAndSingleRowSearchesAgree() throws {
        let s = try setup()
        for keys in ["zhongwenshurufa", "wmmtjm"] {
            assertSame(try incremental(s.batched).update(XCTUnwrap(ChinesePinyinKeys(keys))),
                       try incremental(s.kv).update(XCTUnwrap(ChinesePinyinKeys(keys))), keys)
        }
    }

    /// The batched package typed key by key finds what the chunk package
    /// (the same zh-v1 INT8 weights, every token scored) finds with all the
    /// keys at once, in the same order, on every r2 case; a new first letter
    /// runs only the prompt again.
    func testBatchedPackageSearchesLikeTheChunkPackage() throws {
        let fixtures = try fixtures(), s = try setup()
        var order = 0, worst = 0.0, differ: [String] = []
        for item in fixtures.cases {
            let context = VimeLanguageModel.sentenceContext(item.context)
            let batched = try typed(item.keys, on: try incremental(s.batched, context: context, beam: fixtures.search.beam,
                                                                   count: fixtures.search.topk))
            let chunk = try incremental(s.kv, context: context, beam: fixtures.search.beam, count: fixtures.search.topk)
                .update(XCTUnwrap(ChinesePinyinKeys(item.keys)))
            if batched.map(\.text) == chunk.map(\.text) { order += 1 } else { differ.append("\(item.id) \(item.keys)") }
            for (a, b) in zip(batched, chunk) where a.text == b.text { worst = max(worst, abs(a.score - b.score)) }
        }
        let summary = "batched vs chunk: same order \(order)/\(fixtures.cases.count), worst score difference \(worst); differ: \(differ)"
        print(summary)
        if let path = ProcessInfo.processInfo.environment["VIME_INCREMENTAL_REPORT"] {
            try? summary.write(toFile: path + ".batched", atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(order, fixtures.cases.count, summary)
        XCTAssertLessThan(worst, 1e-3, summary)

        let typing = try incremental(s.batched)
        _ = try typing.update(XCTUnwrap(ChinesePinyinKeys("nihao")))
        let calls = s.batched.batch.predictions
        XCTAssertEqual(try typing.update(XCTUnwrap(ChinesePinyinKeys("w"))).first?.text,
                       try incremental(s.batched).update(XCTUnwrap(ChinesePinyinKeys("w"))).first?.text)
        XCTAssertEqual(s.batched.batch.predictions - calls, 2, "the prompt again, then the fresh engine's prompt")
    }

    /// Forward only against VimeML's r2 (which keeps only reachable key
    /// positions) and against the reachable search here. Not expected to
    /// match: VimeML makes r3 under the same rule. Set VIME_INCREMENTAL_REPORT
    /// to a file path for the numbers and the cases that differ.
    func testForwardOnlyAgainstTheReachableSearch() throws {
        let fixtures = try fixtures(), s = try setup()
        var report: [String] = []
        var top = 0, shared = 0, order = 0, sameSet = 0
        var topReachable = 0, sharedReachable = 0, orderReachable = 0, setReachable = 0, total = 0, worst = 0.0
        var calls: [Int] = []
        for item in fixtures.cases {
            let context = VimeLanguageModel.sentenceContext(item.context)
            let engine = try incremental(s.batched, context: context, beam: fixtures.search.beam, count: fixtures.search.topk)
            let before = s.batched.batch.predictions
            let found = try typed(item.keys, on: engine)
            calls.append(s.batched.batch.predictions - before)
            let reachable = try generate(item.keys, context: context, beam: fixtures.search.beam, count: fixtures.search.topk)
            let expected = item.top.map(\.text)
            total += expected.count
            if found.first?.text == expected.first { top += 1 }
            if found.map(\.text) == expected { order += 1 }
            if Set(found.map(\.text)) == Set(expected) { sameSet += 1 }
            shared += found.filter { expected.contains($0.text) }.count
            if found.first?.text == reachable.first?.text { topReachable += 1 }
            if found.map(\.text) == reachable.map(\.text) { orderReachable += 1 }
            if Set(found.map(\.text)) == Set(reachable.map(\.text)) { setReachable += 1 }
            let scores = Dictionary(reachable.map { ($0.text, $0.score) }, uniquingKeysWith: max)
            for result in found {
                guard let score = scores[result.text] else { continue }
                sharedReachable += 1; worst = max(worst, abs(score - result.score))
            }
            if found.map(\.text) != reachable.map(\.text) {
                report.append("\(item.id) keys \(item.keys) forward \(found.map(\.text)) reachable \(reachable.map(\.text))")
            }
        }
        let n = fixtures.cases.count
        report.insert("""
            cases \(n); against r2: same top \(top), same order \(order), same set \(sameSet), shared \(shared)/\(total); \
            against the reachable search: same top \(topReachable), same order \(orderReachable), same set \(setReachable), \
            shared \(sharedReachable)/\(total), worst shared score difference \(worst); \
            batched calls per case typed key by key: mean \(Double(calls.reduce(0, +)) / Double(n)), max \(calls.max() ?? 0)
            """, at: 0)
        if let path = ProcessInfo.processInfo.environment["VIME_INCREMENTAL_REPORT"] {
            try? report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        print(report[0])
        // A sanity floor only; the two rules differ by design.
        XCTAssertGreaterThanOrEqual(Double(topReachable), 0.8 * Double(n), report[0])
    }
}
