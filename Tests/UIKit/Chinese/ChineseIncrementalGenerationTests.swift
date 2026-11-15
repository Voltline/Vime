import XCTest
@testable import Vime

/// The search kept across keystrokes, with the fake model and dictionary of
/// `ChineseConstrainedGenerationTests`.
final class ChineseIncrementalGenerationTests: XCTestCase {
    typealias Generation = ChineseConstrainedGeneration
    typealias Fake = ChineseConstrainedGenerationTests
    typealias Engine = ChineseIncrementalGeneration<Fake.FakeModel>

    private func engine(beam: Int = 16, count: Int = 10, maximumLength: Int = 128,
                        model: Fake.FakeModel? = nil) throws -> Engine {
        try Engine(model: model ?? Fake.FakeModel(vocabularySize: Fake.texts.count), vocabulary: Fake.vocabulary,
                   lexicon: Fake.lexicon, prompt: [2], parameters: .init(beam: beam, count: count, maximumLength: maximumLength))
    }

    private func keys(_ text: String) throws -> ChinesePinyinKeys { try XCTUnwrap(ChinesePinyinKeys(text)) }

    /// All at once, on a new engine.
    private func fresh(_ text: String, beam: Int = 16, count: Int = 10) throws -> [Generation.Result] {
        try engine(beam: beam, count: count).update(keys(text))
    }

    func testAWideBeamFindsTheExactBestSentences() throws {
        for text in ["zhongwen", "xian", "zw", "changzhang", "shhao", "nihaozhongwen", "xianxian", "xianxianxian"] {
            let reference = try Generation.generate(model: Fake.FakeModel(vocabularySize: Fake.texts.count),
                vocabulary: Fake.vocabulary, lexicon: Fake.lexicon, keys: keys(text), prompt: [2], mode: .lm,
                parameters: .init(beam: 1000, count: 1000))
            // Log probabilities are kept in single precision.
            let found = try fresh(text, beam: 1000, count: 1000)
            XCTAssertEqual(Set(found.map(\.text)), Set(reference.map(\.text)), text)
            let scores = Dictionary(uniqueKeysWithValues: reference.map { ($0.text, $0.score) })
            for result in found { XCTAssertEqual(result.score, scores[result.text] ?? 0, accuracy: 1e-5, "\(text) \(result.text)") }
        }
    }

    func testKeyByKeyMatchesAllAtOnce() throws {
        for beam in [1, 2, 16] {
            for text in ["xianxianxian", "nihaozhongwen", "changzhangyinhang", "xi'anxian", "shhaozw"] {
                let typing = try engine(beam: beam)
                for end in 1...text.count {
                    let prefix = String(text.prefix(end))
                    guard ChinesePinyinKeys(prefix) != nil else { continue }
                    XCTAssertEqual(try typing.update(keys(prefix)), try fresh(prefix, beam: beam), "\(prefix) beam \(beam)")
                }
            }
        }
    }

    func testEachKeyCostsAtMostOneBatch() throws {
        let typing = try engine()
        var calls = typing.calls
        for end in 1..."nihaozhongwen".count {
            _ = try typing.update(keys(String("nihaozhongwen".prefix(end))))
            XCTAssertLessThanOrEqual(typing.calls - calls, 1, "key \(end)")
            calls = typing.calls
        }
    }

    func testBackspaceGoesBackWithoutTheModel() throws {
        let model = Fake.FakeModel(vocabularySize: Fake.texts.count)
        let typing = try engine(model: model)
        let short = try typing.update(keys("nihaozhong"))
        _ = try typing.update(keys("nihaozhongwen"))
        let calls = model.calls
        XCTAssertEqual(try typing.update(keys("nihaozhong")), short)
        XCTAssertEqual(model.calls, calls, "backspace")
        // Typing the same key again reuses what it had.
        XCTAssertEqual(try typing.update(keys("nihaozhongw")), try fresh("nihaozhongw"))
        XCTAssertEqual(model.calls, calls, "the same key again")
        // Another key from there runs only the last bucket again.
        XCTAssertEqual(try typing.update(keys("nihaozhongx")), try fresh("nihaozhongx"))
        XCTAssertGreaterThan(model.calls, calls)
    }

    func testAnEarlierChangeStartsOverFromThere() throws {
        let typing = try engine()
        _ = try typing.update(keys("xianxian"))
        XCTAssertEqual(try typing.update(keys("xi'anxian")), try fresh("xi'anxian"), "an apostrophe counts")
        XCTAssertEqual(try typing.update(keys("nihao")), try fresh("nihao"), "a new first key keeps only the prompt")
        XCTAssertEqual(try typing.update(keys("xianxian")), try fresh("xianxian"))
    }

    func testKeysNothingSpellsGiveNothingAndRecover() throws {
        let typing = try engine()
        XCTAssertEqual(try typing.update(keys("zhongq")), [])
        XCTAssertEqual(try typing.update(keys("zhongqwen")), [])
        XCTAssertEqual(try typing.update(keys("zhongwen")), try fresh("zhongwen"))
    }

    func testCancellationKeepsTheKeysFinished() throws {
        let model = Fake.FakeModel(vocabularySize: Fake.texts.count)
        let typing = try engine(model: model)
        var checks = 0
        XCTAssertThrowsError(try typing.update(keys("xianxianxian"), cancelled: { checks += 1; return checks > 5 })) {
            XCTAssertEqual($0 as? Generation.Failure, .cancelled)
        }
        let afterCancel = model.calls
        // Five keys are done; the rest costs what a fresh run spends past them.
        XCTAssertEqual(try typing.update(keys("xianxianxian")), try fresh("xianxianxian"))
        let finishing = model.calls - afterCancel
        let full = Fake.FakeModel(vocabularySize: Fake.texts.count)
        _ = try engine(model: full).update(keys("xianxianxian"))
        XCTAssertLessThan(finishing, full.calls)
        // A different word after the cancel still matches.
        XCTAssertThrowsError(try typing.update(keys("xianxiannihao"), cancelled: { true }))
        XCTAssertEqual(try typing.update(keys("xianxiannihao")), try fresh("xianxiannihao"))
    }

    func testTheLengthLimitCountsThePrompt() throws {
        XCTAssertEqual(try engine(maximumLength: 3).update(keys("zhongwen")).map(\.text), ["中文"])
        XCTAssertEqual(try engine(maximumLength: 2).update(keys("zhongwen")).map(\.text), ["中文"])
        XCTAssertThrowsError(try engine(maximumLength: 1)) { XCTAssertEqual($0 as? Generation.Failure, .prompt) }
    }

    func testMaximumSpanAndLetterTables() {
        // 银行 / 长长: yin + hang, chang + zhang.
        XCTAssertEqual(Fake.vocabulary.maximumSpan, 10)
        let z = Fake.vocabulary.byLetter[Int(UInt8(ascii: "z")) - 97]
        XCTAssertTrue(z.contains(Fake.id("中文")) && z.contains(Fake.id("长")) && z.contains(Fake.id("长长")))
        XCTAssertFalse(z.contains(Fake.id("你")))
        for (letter, tokens) in Fake.vocabulary.byLetter.enumerated() {
            for (position, token) in tokens.enumerated() {
                XCTAssertEqual(Fake.vocabulary.letterIndex[letter][Int(token)], Int32(position))
            }
        }
    }
}
