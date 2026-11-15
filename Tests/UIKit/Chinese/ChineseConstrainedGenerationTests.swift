import XCTest
@testable import Vime

/// The constraints and the search, with a small dictionary and a fake model.
final class ChineseConstrainedGenerationTests: XCTestCase {
    typealias Generation = ChineseConstrainedGeneration

    /// Logits depend on the whole token sequence, so every path scores differently.
    final class FakeModel: ChineseGenerationModel {
        typealias State = [Int32]
        let vocabularySize: Int
        private(set) var calls = 0
        var eosBias: Float = 0
        init(vocabularySize: Int) { self.vocabularySize = vocabularySize }
        func logits(_ tokens: [Int32]) -> [Float] {
            var seed: UInt64 = 1469598103934665603
            for token in tokens { seed = (seed ^ UInt64(token)) &* 1099511628211 }
            return (0..<vocabularySize).map { id in
                let value = Float(sin(Double(seed % 10007) * 0.37 + Double(id) * 1.91)) * 3
                return id == Int(Generation.eos) ? value + eosBias : value
            }
        }
        func start(_ prompt: [Int32]) throws -> (logits: [Float], state: [Int32]) {
            calls += 1; return (logits(prompt), prompt)
        }
        func extend(_ state: [Int32], with token: Int32) throws -> (logits: [Float], state: [Int32]) {
            calls += 1; return (logits(state + [token]), state + [token])
        }
        /// The exact score of `tokens` after `prompt`.
        func score(_ tokens: [Int32], prompt: [Int32], eos: Bool) -> Double {
            var sequence = prompt, total = 0.0
            for token in tokens + (eos ? [Generation.eos] : []) {
                let row = logits(sequence)
                total += Double(row[Int(token)]) - (try! Generation.logNormalizer(row))
                sequence.append(token)
            }
            return total
        }
    }

    static let lexicon = ChinesePinyinLexicon(readings: [
        "中": ["zhong"], "文": ["wen"], "行": ["xing", "hang"], "长": ["chang", "zhang"], "银": ["yin"],
        "你": ["ni"], "好": ["hao"], "西": ["xi"], "安": ["an"], "先": ["xian"], "是": ["shi"], "时": ["shi"],
    ])
    static let texts = ["", "", "", "", "", "", "", "",
        "中", "文", "中文", "行", "长", "银行", "你", "好", "你好", "西", "安", "先", "西安", "是", "时",
        "a", "中a", "龘", "长长"]
    static let vocabulary = Generation.Vocabulary(texts: texts, lexicon: lexicon)
    static func id(_ text: String) -> Int32 { Int32(texts.firstIndex(of: text)!) }

    private func generate(_ keys: String, mode: Generation.Mode = .lm, beam: Int = 16, count: Int = 10,
                          maximumLength: Int = 128, model: FakeModel? = nil) throws -> [Generation.Result] {
        let model = model ?? FakeModel(vocabularySize: Self.texts.count)
        return try Generation.generate(model: model, vocabulary: Self.vocabulary, lexicon: Self.lexicon,
            keys: XCTUnwrap(ChinesePinyinKeys(keys)), prompt: [2], mode: mode,
            parameters: .init(beam: beam, count: count, maximumLength: maximumLength))
    }

    private func texts(_ keys: String) throws -> Set<String> { Set(try generate(keys).map(\.text)) }

    /// Every sentence a token sequence can spell, scored exactly.
    private func exhaustive(_ keys: String, mode: Generation.Mode, model: FakeModel) throws -> [String: Double] {
        let spelling = Generation.Spelling(keys: try XCTUnwrap(ChinesePinyinKeys(keys)), lexicon: Self.lexicon,
                                           vocabulary: Self.vocabulary)
        var best: [String: Double] = [:]
        func walk(_ tokens: [Int32], _ position: Int) {
            if position == spelling.keys.count {
                let text = tokens.map { Self.texts[Int($0)] }.joined()
                best[text] = max(best[text] ?? -.infinity, model.score(tokens, prompt: [2], eos: mode == .task))
                return
            }
            for step in spelling.steps(from: position) { walk(tokens + [step.token], step.end) }
        }
        walk([], 0)
        return best
    }

    func testOnlyDictionaryCharacterTokensAreUsable() {
        let characters = Self.vocabulary.characters
        XCTAssertEqual(characters[Int(Self.id("中文"))], ["中", "文"])
        XCTAssertTrue(characters[Int(Self.id("a"))].isEmpty, "not Chinese")
        XCTAssertTrue(characters[Int(Self.id("中a"))].isEmpty, "not only Chinese")
        XCTAssertTrue(characters[Int(Self.id("龘"))].isEmpty, "not in the dictionary")
        XCTAssertTrue(characters[0...7].allSatisfy(\.isEmpty))
        XCTAssertEqual(Self.vocabulary.usableCount, 16)
    }

    func testFullPinyin() throws {
        XCTAssertEqual(try texts("zhongwen"), ["中文"])
        XCTAssertEqual(try texts("nihao"), ["你好"])
        XCTAssertEqual(try texts("ZhongWen"), ["中文"], "keys are case-insensitive")
    }

    func testInitials() throws {
        XCTAssertEqual(try texts("zw"), ["中文", "长文"], "z begins zhong and zhang")
        XCTAssertEqual(try texts("zhongw"), ["中文"])
        XCTAssertEqual(try texts("nh"), ["你好", "你行"], "h begins hao and hang (行)")
    }

    func testZhChShInitials() throws {
        XCTAssertTrue(try texts("zhw").isSuperset(of: ["中文", "长文", "中好文"]), "zh, or z then h")
        XCTAssertEqual(try texts("ch"), ["长", "长好", "长行"], "ch, or c then h")
        XCTAssertEqual(try texts("sh"), ["是", "时", "是好", "时好", "是行", "时行"])
        XCTAssertFalse(try texts("zh").contains("是"))
    }

    func testPolyphonicCharacters() throws {
        XCTAssertEqual(try texts("yinhang"), ["银行"])
        XCTAssertEqual(try texts("yinxing"), ["银行"], "each character may take any of its readings")
        XCTAssertTrue(try texts("changzhang").contains("长长"))
        XCTAssertTrue(try texts("zhangchang").contains("长长"))
        XCTAssertTrue(try texts("ch").contains("长"))
        XCTAssertTrue(try texts("zh").contains("长"), "长 also reads zhang")
    }

    func testATokenCanSpellTheKeysInSeveralWays() throws {
        func spelling(_ keys: String) throws -> Generation.Spelling {
            Generation.Spelling(keys: try XCTUnwrap(ChinesePinyinKeys(keys)), lexicon: Self.lexicon, vocabulary: Self.vocabulary)
        }
        // 时 as s (then 好 as h, 好 as hao) or as sh (then 好 as hao).
        XCTAssertEqual(try spelling("shhao").ends(of: ["时"], from: 0), [1, 2])
        XCTAssertEqual(try texts("shhao"), ["是好", "时好", "是好好", "时好好", "是行好", "时行好"])
        let chch = try spelling("chch")
        XCTAssertEqual(chch.ends(of: ["长"], from: 0), [1, 2], "c and ch both begin chang")
        XCTAssertEqual(chch.ends(of: ["长", "长"], from: 0), [3, 4], "the second 长 only after ch: h begins nothing of 长")
        XCTAssertEqual(chch.steps(from: 0).filter { $0.token == Self.id("长") }.map(\.end), [1, 2])
        XCTAssertEqual(chch.steps(from: 0).filter { $0.token == Self.id("长长") }.map(\.end), [3, 4])
        // Only reachable ends: x alone leaves "ian", which nothing spells.
        let xian = try spelling("xian")
        XCTAssertEqual(xian.ends(of: ["先"], from: 0), [4])
        XCTAssertEqual(xian.ends(of: ["西"], from: 0), [2])
        XCTAssertTrue(try texts("xian").isSuperset(of: ["先", "西安"]))
        XCTAssertTrue(try texts("xan").contains("西安"), "x begins xi")
    }

    func testApostrophesSeparateSyllables() throws {
        let texts = try texts("xi'an")
        XCTAssertTrue(texts.contains("西安"))
        XCTAssertFalse(texts.contains("先"), "xian may not span the apostrophe")
        XCTAssertNil(ChinesePinyinKeys("xi an"))
        XCTAssertNil(ChinesePinyinKeys("'"))
    }

    func testUnreachableKeys() {
        XCTAssertThrowsError(try generate("zhongq")) { XCTAssertEqual($0 as? Generation.Failure, .unreachable) }
        XCTAssertThrowsError(try generate("i")) { XCTAssertEqual($0 as? Generation.Failure, .unreachable) }
        let spelling = Generation.Spelling(keys: ChinesePinyinKeys("zhongqwen")!, lexicon: Self.lexicon,
                                           vocabulary: Self.vocabulary)
        XCTAssertEqual(spelling.reachable, [false, false, false, false, false, false, true, false, true, true])
        XCTAssertTrue(spelling.steps(from: 0).isEmpty)
    }

    func testAWideBeamFindsTheExactBestSentences() throws {
        for mode in [Generation.Mode.lm, .task] {
            for keys in ["zhongwen", "xian", "zw", "changzhang", "shhao", "nihaozhongwen", "xianxian"] {
                let model = FakeModel(vocabularySize: Self.texts.count)
                let expected = try exhaustive(keys, mode: mode, model: model)
                let found = try generate(keys, mode: mode, beam: 1000, count: 3, model: model)
                let top = expected.sorted { $0.value > $1.value }.prefix(3)
                XCTAssertEqual(found.map(\.text), top.map(\.key), "\(keys) \(mode)")
                for (result, (_, score)) in zip(found, top) { XCTAssertEqual(result.score, score, accuracy: 1e-9) }
                XCTAssertEqual(found.map(\.score), found.map(\.score).sorted(by: >))
            }
        }
    }

    func testTaskModeCountsTheEndOfSentence() throws {
        let model = FakeModel(vocabularySize: Self.texts.count)
        let lm = try generate("zhongwen", mode: .lm, model: model)
        let task = try generate("zhongwen", mode: .task, model: model)
        XCTAssertEqual(lm.map(\.text), ["中文"])
        let tokens = try XCTUnwrap(task.first?.tokens)
        XCTAssertEqual(task.first?.score ?? 0, model.score(tokens, prompt: [2], eos: true), accuracy: 1e-9)
        XCTAssertLessThan(task[0].score, model.score(tokens, prompt: [2], eos: false))
    }

    func testTheBeamAndCountBoundTheSearch() throws {
        let narrow = try generate("xianxianxian", beam: 1, count: 10)
        XCTAssertFalse(narrow.isEmpty)
        XCTAssertEqual(try generate("xianxianxian", count: 2).count, 2)
        let model = FakeModel(vocabularySize: Self.texts.count)
        _ = try generate("xianxianxian", beam: 2, count: 10, model: model)
        let wide = FakeModel(vocabularySize: Self.texts.count)
        _ = try generate("xianxianxian", beam: 64, count: 10, model: wide)
        XCTAssertLessThan(model.calls, wide.calls)
    }

    func testEachKeyPositionKeepsItsOwnBeam() throws {
        // Beam 1: the prompt, then at most one hypothesis run per key position that has any.
        let keys = try XCTUnwrap(ChinesePinyinKeys("xianxianxian"))
        let spelling = Generation.Spelling(keys: keys, lexicon: Self.lexicon, vocabulary: Self.vocabulary)
        var positions: Set<Int> = [0], frontier = [0]
        while let position = frontier.popLast() {
            for step in spelling.steps(from: position) where step.end < keys.count && positions.insert(step.end).inserted {
                frontier.append(step.end)
            }
        }
        let model = FakeModel(vocabularySize: Self.texts.count)
        let found = try generate("xianxianxian", beam: 1, count: 10, model: model)
        XCTAssertLessThanOrEqual(model.calls, positions.count)
        XCTAssertGreaterThan(model.calls, 1)
        XCTAssertEqual(found.count, 1, "the last position keeps one sentence too")
        // Every position still reached: 先先先 (three tokens) and 西安… compete only at the end.
        XCTAssertEqual(try generate("xianxianxian", beam: 1000, count: 1000).count,
                       try exhaustive("xianxianxian", mode: .lm, model: FakeModel(vocabularySize: Self.texts.count)).count)
    }

    func testTheLengthLimitCountsThePrompt() throws {
        // A token is expanded only while the prompt and it leave room for another.
        XCTAssertEqual(try generate("zhongwen", maximumLength: 3).map(\.text), ["中文"])
        XCTAssertEqual(try generate("zhongwen", maximumLength: 2).map(\.text), ["中文"], "one token 中文 fits")
        XCTAssertThrowsError(try generate("zhongwen", maximumLength: 1)) { XCTAssertEqual($0 as? Generation.Failure, .prompt) }
    }

    func testCancellationStopsAtOnce() throws {
        let model = FakeModel(vocabularySize: Self.texts.count)
        var checks = 0
        XCTAssertThrowsError(try Generation.generate(model: model, vocabulary: Self.vocabulary, lexicon: Self.lexicon,
            keys: ChinesePinyinKeys("xianxianxian")!, prompt: [2], mode: .lm,
            cancelled: { checks += 1; return checks > 3 })) { XCTAssertEqual($0 as? Generation.Failure, .cancelled) }
        XCTAssertLessThanOrEqual(model.calls, 3)
    }

    // MARK: Rescoring

    func testRescoringAddsTheWeightedModelScore() {
        let generated = [Generation.Result(text: "甲", tokens: [1], score: -1),
                         Generation.Result(text: "乙", tokens: [2], score: -2)]
        let rescored = ChineseSentenceGeneration.rescored(generated, modelScores: [-5, -3])
        XCTAssertEqual(rescored.map(\.text), ["乙", "甲"])
        XCTAssertEqual(rescored[0].score, -2 + 1.6 * -3, accuracy: 1e-12)
        XCTAssertEqual(rescored[1].modelScore, -5)
    }

    func testWithoutModelScoresTheGenerationDecides() {
        let generated = [Generation.Result(text: "甲", tokens: [1], score: -2),
                         Generation.Result(text: "乙", tokens: [2], score: -1)]
        for scores in [nil, [-1.0], [-1, .nan]] as [[Double]?] {
            let rescored = ChineseSentenceGeneration.rescored(generated, modelScores: scores)
            XCTAssertEqual(rescored.map(\.text), ["乙", "甲"])
            XCTAssertTrue(rescored.allSatisfy { $0.modelScore == nil && $0.score == $0.generationScore })
        }
    }
}
