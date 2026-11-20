import XCTest
@testable import Vime

/// Sentence generation on the bundled zh-v1 kvbatch-v3 package and Rime's
/// dictionary — forward only, kept across keystrokes — then rescoring with
/// the same package.
final class ChineseSentenceGenerationTests: XCTestCase {
    typealias Generation = ChineseConstrainedGeneration

    struct Setup {
        let model: ChineseLanguageModel
        let generator: ChineseSentenceGeneration.Storage.Generator
        var lexicon: ChinesePinyinLexicon { generator.lexicon }
        var vocabulary: Generation.Vocabulary { generator.vocabulary }
        var tokenizer: VimeSentenceTokenizer { model.tokenizer }
        /// The prompt in one call, allowed tokens scored only.
        var batched: ChineseKVGenerator { generator.model }
    }
    nonisolated(unsafe) private static var cached: Setup?

    func setup() throws -> Setup {
        if let cached = Self.cached { return cached }
        XCTAssertNotNil(ChinesePinyinLexicon.bundled, "RimeData.bundle is not bundled")
        let model = try ChineseLanguageModel(bundle: Bundle(for: Self.self), version: .v1)
        let setup = Setup(model: model, generator: try XCTUnwrap(ChineseSentenceGeneration.Storage.generator(for: model)))
        Self.cached = setup
        return setup
    }

    private func incremental(context: String = "", beam: Int = 16,
                             count: Int = 10) throws -> ChineseIncrementalGeneration<ChineseKVGenerator> {
        let s = try setup()
        let prompt = try Generation.prompt(.lm, context: context, keys: "", tokenizer: s.tokenizer)
        return try ChineseIncrementalGeneration(model: s.batched, vocabulary: s.vocabulary, lexicon: s.lexicon, prompt: prompt,
                                                parameters: .init(beam: beam, count: count))
    }

    /// All of `keys` at once, on a fresh search.
    func generate(_ keys: String, context: String = "", beam: Int = 16, count: Int = 10) throws -> [Generation.Result] {
        try incremental(context: context, beam: beam, count: count).update(try XCTUnwrap(ChinesePinyinKeys(keys)))
    }

    /// Typed one key at a time; the results after the last.
    private func typed(_ keys: String, on engine: ChineseIncrementalGeneration<ChineseKVGenerator>)
        throws -> [Generation.Result] {
        var results: [Generation.Result] = []
        for end in 1...keys.count {
            guard let prefix = ChinesePinyinKeys(String(keys.prefix(end))) else { continue }
            results = try engine.update(prefix)
        }
        return results
    }

    private func candidates(_ keys: String, context: String = "", scorer: Bool = true,
                            allows: (String) -> Bool = { _ in true },
                            cancelled: () -> Bool = { false }) throws -> [ChineseSentenceGeneration.Candidate]? {
        let s = try setup()
        return ChineseSentenceGeneration.candidates(keys: keys, leftContext: context, generator: s.generator,
            scorer: scorer ? s.model : nil, allows: allows, cancelled: cancelled)
    }

    func testTheDictionaryComesFromRimesTable() throws {
        let s = try setup()
        XCTAssertGreaterThan(s.lexicon.readings.count, 8000)
        XCTAssertEqual(s.lexicon.readings["中"], ["zhong"])
        XCTAssertTrue(s.lexicon.readings["行"]?.isSuperset(of: ["xing", "hang"]) ?? false)
        XCTAssertTrue(s.lexicon.readings["绿"]?.contains("lv") ?? false, "ü is written v, as Rime spells it")
        XCTAssertGreaterThan(s.vocabulary.usableCount, 8000)
        XCTAssertTrue(s.vocabulary.characters[Int(try s.tokenizer.encode("中文")[0])] == ["中", "文"])
        XCTAssertTrue(s.vocabulary.characters[Int(try s.tokenizer.encode("，")[0])].isEmpty)
    }

    func testPromptsForBothModes() throws {
        let tokenizer = try setup().tokenizer
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
        XCTAssertEqual(try generate("iiii"), [])
        XCTAssertNil(try candidates("iiii"))
        XCTAssertNil(try candidates("ni hao"))
        XCTAssertNil(try candidates("nihao", cancelled: { true }))
    }

    func testRescoringUsesTheContextAndKeepsGenerationScores() throws {
        let generated = try generate("shiyan", context: "我们明天去")
        let rescored = try XCTUnwrap(try candidates("shiyan", context: "我们明天去"))
        XCTAssertEqual(Set(rescored.map(\.text)), Set(generated.map(\.text)))
        let model = try setup().model.scores(context: "我们明天去", candidates: rescored.map(\.text))
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
            XCTAssertEqual(try Generation.prompt(.lm, context: context, keys: item.keys, tokenizer: s.tokenizer),
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
    /// of each sentence after the prompt: within INT8 noise of what the
    /// package's `score` function gives. Rows where VimeML's own
    /// `v1_context_scores` disagree with its generation score are left out
    /// (r1 had 171; r1 is withdrawn).
    func testGenerationScoresMatchVimeMLWhereItIsConsistent() throws {
        let fixtures = try fixtures(), s = try setup()
        var checked = 0
        for item in fixtures.cases {
            let consistent = zip(item.top, item.v1_context_scores).filter { abs($0.gen_score - $1) < 0.01 }.map(\.0)
            guard !consistent.isEmpty else { continue }
            let prefix = try s.model.batch.prefix(Array(item.prompt_ids.dropLast()))
            let rows = consistent.map { [item.prompt_ids.last!] + $0.ids }
            for (top, values) in zip(consistent, try s.model.batch.scores(after: prefix, rows: rows)) {
                let score = values.reduce(0) { $0 + Double($1) }
                XCTAssertEqual(score, top.gen_score, accuracy: max(0.75, 0.005 * abs(top.gen_score)), "\(item.id) \(top.text)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    /// The reranking scores VimeML computed for its top texts, one joint call each.
    func testContextScoresMatchVimeML() throws {
        let fixtures = try fixtures(), s = try setup()
        for item in fixtures.cases {
            let scores = try s.model.scores(context: VimeLanguageModel.sentenceContext(item.context),
                                            candidates: item.top.map(\.text))
            for (index, score) in scores.enumerated() {
                let expected = item.v1_context_scores[index]
                XCTAssertEqual(score, expected, accuracy: max(0.75, 0.005 * abs(expected)), "\(item.id) \(item.top[index].text)")
            }
        }
    }

    // MARK: Forward only, kept across keystrokes

    /// Same texts; scores within what attention over more or fewer cache slots changes.
    private func assertSame(_ a: [Generation.Result], _ b: [Generation.Result], _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(a.map(\.text)), Set(b.map(\.text)), message, file: file, line: line)
        XCTAssertEqual(a.first?.text, b.first?.text, message, file: file, line: line)
        let scores = Dictionary(b.map { ($0.text, $0.score) }, uniquingKeysWith: max)
        for result in a { XCTAssertEqual(result.score, scores[result.text] ?? 0, accuracy: 1e-3, message, file: file, line: line) }
    }

    func testTypingFindsTheObviousSentence() throws {
        let engine = try incremental()
        for (keys, text) in [("nihao", "你好"), ("zhongwenshurufa", "中文输入法"), ("zwsrf", "中文输入法"),
                             ("jintiantianqihenhao", "今天天气很好"), ("woxiangchifan", "我想吃饭")] {
            XCTAssertEqual(try typed(keys, on: engine).first?.text, text, keys)
        }
    }

    func testTypingKeyByKeyMatchesAllAtOnce() throws {
        let s = try setup()
        let typing = try incremental(context: "今天")
        for keys in ["women", "womenqugongyuansanbu", "wmqgy", "xi'an"] {
            let found = try typed(keys, on: typing)
            assertSame(found, try generate(keys, context: "今天"), keys)
        }
        // Backspace and typing the same key again cost no model call.
        _ = try typing.update(XCTUnwrap(ChinesePinyinKeys("womenqugongyuan")))
        let calls = s.batched.batch.predictions
        let short = try typing.update(XCTUnwrap(ChinesePinyinKeys("womenqugongyua")))
        XCTAssertEqual(try typing.update(XCTUnwrap(ChinesePinyinKeys("womenqugongyuan"))).first?.text, "我们去公园")
        XCTAssertFalse(short.isEmpty)
        XCTAssertEqual(s.batched.batch.predictions, calls)
        // A new first letter runs only the prompt again.
        let fresh = try incremental()
        _ = try fresh.update(XCTUnwrap(ChinesePinyinKeys("nihao")))
        let before = s.batched.batch.predictions
        XCTAssertEqual(try fresh.update(XCTUnwrap(ChinesePinyinKeys("w"))).first?.text, try generate("w").first?.text)
        XCTAssertEqual(s.batched.batch.predictions - before, 2, "the prompt again, then the fresh engine's prompt")
    }

    /// Typed key by key against VimeML's r2, which searches every key
    /// position it can still reach rather than forward only, so the two are
    /// not expected to match. Set VIME_INCREMENTAL_REPORT to a file path for
    /// the numbers and the cases that differ.
    func testForwardOnlyAgainstVimeML() throws {
        let fixtures = try fixtures(), s = try setup()
        var report: [String] = []
        var top = 0, topThree = 0, order = 0, shared = 0, total = 0, worst = 0.0
        var calls: [Int] = []
        for item in fixtures.cases {
            let context = VimeLanguageModel.sentenceContext(item.context)
            XCTAssertEqual(try Generation.prompt(.lm, context: context, keys: item.keys, tokenizer: s.tokenizer),
                           item.prompt_ids, "\(item.id) prompt")
            let engine = try incremental(context: context, beam: fixtures.search.beam, count: fixtures.search.topk)
            let before = s.batched.batch.predictions
            let found = try typed(item.keys, on: engine)
            calls.append(s.batched.batch.predictions - before)
            let expected = Dictionary(item.top.map { ($0.text, $0.gen_score) }, uniquingKeysWith: max)
            total += item.top.count
            if found.first?.text == item.top.first?.text { top += 1 }
            if found.prefix(3).contains(where: { $0.text == item.top.first?.text }) { topThree += 1 }
            if found.map(\.text) == item.top.map(\.text) { order += 1 }
            for result in found {
                guard let score = expected[result.text] else { continue }
                shared += 1; worst = max(worst, abs(score - result.score))
            }
            if found.first?.text != item.top.first?.text {
                report.append("\(item.id) keys \(item.keys) forward \(found.map(\.text)) r2 \(item.top.map(\.text))")
            }
        }
        let n = fixtures.cases.count
        report.insert("""
            cases \(n); against r2: same top \(top), r2's top in the first three \(topThree), same order \(order), \
            shared \(shared)/\(total), worst shared score difference \(worst); \
            calls per case typed key by key: mean \(Double(calls.reduce(0, +)) / Double(n)), max \(calls.max() ?? 0)
            """, at: 0)
        if let path = ProcessInfo.processInfo.environment["VIME_INCREMENTAL_REPORT"] {
            try? report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        print(report[0])
        // Sanity floors only; the two rules differ by design.
        XCTAssertGreaterThanOrEqual(Double(topThree), 0.95 * Double(n), report[0])
        XCTAssertLessThan(worst, 0.7, report[0])
    }
}
