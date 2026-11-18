import XCTest
import CoreML
@testable import Vime

/// The zh-v1 batched KV package (kvbatch-v3: the prompt as a prefix shared by
/// every row, scores for the allowed ids only): VimeML's 16-row fixture, and
/// rows that grow over several calls, against a full pass of the `logits`
/// function (no prefix, no cache).
final class VimeKVBatchLanguageModelTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: Self.self) }

    private struct Row: Decodable {
        let own_ids: [Int32]
        let token: Int32
    }

    private func load<T>(_ name: String, _ ext: String, as type: T.Type) throws -> [T] {
        try Data(contentsOf: try XCTUnwrap(bundle.url(forResource: name, withExtension: ext)))
            .withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }

    /// The prompt, the rows (own tokens after it, then one more), the
    /// allowed ids, and the package's log probabilities of them.
    private func fixture() throws -> (prompt: [Int32], rows: [Row], allowed: [Int32], logProbabilities: [[Float]]) {
        let lines = try String(contentsOf: try XCTUnwrap(bundle.url(forResource: "KVBatchV3Fixture-step", withExtension: "jsonl")),
                               encoding: .utf8).split(separator: "\n")
        let rows = try lines.map { try JSONDecoder().decode(Row.self, from: Data($0.utf8)) }
        let prompt = try load("KVBatchV3Fixture-step-prompt", "i32", as: Int32.self)
        let allowed = try load("KVBatchV3Fixture-step-allowed", "i32", as: Int32.self)
        let floats = try load("KVBatchV3Fixture-step-scored", "f32", as: Float.self)
        XCTAssertEqual(floats.count, rows.count * allowed.count)
        return (prompt, rows, allowed, (0..<rows.count).map { Array(floats[$0 * allowed.count..<($0 + 1) * allowed.count]) })
    }

    private func assertClose(_ value: [Float], _ reference: [Float], tolerance: VimeKVLanguageModel.Tolerance,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value.count, reference.count, message, file: file, line: line)
        let outside = zip(value, reference).filter { !tolerance.accepts($0, reference: $1) }.count
        let worst = zip(value, reference).map { abs($0 - $1) }.max() ?? 0
        XCTAssertEqual(outside, 0, "\(message): \(outside) values outside tolerance, worst \(worst); \(value.prefix(3)) vs \(reference.prefix(3))", file: file, line: line)
    }

    /// A full pass of `ids` through the `logits` function of another
    /// instance (so it adds no calls to the one under test): the log
    /// probabilities of `allowed` after them.
    private func reference(_ full: VimeKVBatchLanguageModel, _ ids: [Int32], _ allowed: [Int32]) throws -> [Float] {
        try ChineseConstrainedGeneration.logProbabilities(try full.logits(ids), of: allowed)
    }

    private func tokenizer() throws -> VimeSentenceTokenizer {
        try ChineseLanguageModel(bundle: bundle).tokenizer
    }

    func testLoadsThePublishedPackage() throws {
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        XCTAssertEqual(batch.maximumBatch, 16)
        XCTAssertEqual(batch.tolerance, VimeKVLanguageModel.Tolerance(atol: 3e-4, rtol: 3e-4))
    }

    /// VimeML's fixture: the prompt in one call (the prefix), each row's own
    /// tokens after it, then the 16 rows' next tokens in one call.
    func testMatchesVimeMLFixture() throws {
        let (promptIDs, rows, allowed, logProbabilities) = try fixture()
        XCTAssertEqual(rows.count, 16)
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        let prompt = try batch.prompt(promptIDs, allowed: allowed).cache
        let own = try rows.map { row -> VimeKVLanguageModel.Cache in
            var cache = prompt
            for token in row.own_ids { cache = try batch.scores([(cache, token)], allowed: allowed)[0].cache }
            return cache
        }
        let before = batch.predictions
        let all = try batch.scores(zip(own, rows).map { ($0, $1.token) }, allowed: allowed)
        XCTAssertEqual(batch.predictions - before, 1)
        for (index, result) in all.enumerated() {
            assertClose(result.logProbabilities, logProbabilities[index], tolerance: batch.tolerance, "row \(index) batch 16")
            XCTAssertEqual(result.cache.length, promptIDs.count + rows[index].own_ids.count + 1)
        }
        // Fewer rows at once, in another order: the same values.
        let subset = [5, 0, 11]
        let results = try batch.scores(subset.map { (own[$0], rows[$0].token) }, allowed: allowed)
        for (index, result) in zip(subset, results) {
            assertClose(result.logProbabilities, logProbabilities[index], tolerance: batch.tolerance, "row \(index) batch 3")
        }
        XCTAssertEqual(batch.usesOutputBackings[16], true)
        XCTAssertEqual(batch.loadedFunctions, [.scored])
    }

    /// Caches from two prompts cannot share a call: the prefix is one.
    func testRejectsCachesFromDifferentPrompts() throws {
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        let one = try batch.prompt([2, 973], allowed: [3]).cache
        let two = try batch.prompt([2, 1992], allowed: [3]).cache
        XCTAssertThrowsError(try batch.scores([(one, 7), (two, 7)], allowed: [3]))
        // The older prompt still works on its own: its prefix is rebuilt.
        XCTAssertNoThrow(try batch.scores([(one, 7)], allowed: [3]))
    }

    /// Rows keep growing across calls and branch, with another allowed list
    /// each call; each matches a full pass.
    func testRowsGrowAndBranch() throws {
        let full = try VimeKVBatchLanguageModel(bundle: bundle), tokenizer = try tokenizer()
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        let texts = ["今天天气很好我们去公园", "中文输入法很好用", "我想吃饭了", "明天下午三点开会"]
        let ids = try texts.map { [Int32(2)] + (try tokenizer.encode($0)) }
        let first = (0..<300).map { Int32($0 * 40) }
        let start = try batch.prompt([2], allowed: first)
        assertClose(start.logProbabilities, try reference(full, [2], first), tolerance: batch.tolerance, "prompt")
        var live: [(cache: VimeKVLanguageModel.Cache, ids: [Int32])] = ids.map { _ in (start.cache, [2]) }
        let steps = ids.map(\.count).min()! - 1
        for step in 1...steps {
            let allowed = (0..<(step % 2 == 0 ? 1024 : 77)).map { Int32(($0 * 11 + step) % 12288) }
            var items: [(cache: VimeKVLanguageModel.Cache, token: Int32)] = []
            var next: [[Int32]] = []
            for (index, hypothesis) in live.enumerated() {
                let text = ids[index % ids.count]
                items.append((hypothesis.cache, text[step])); next.append(hypothesis.ids + [text[step]])
            }
            if step == 2 {
                for (index, hypothesis) in live.prefix(4).enumerated() {
                    let token = ids[(index + 1) % ids.count][1]
                    items.append((hypothesis.cache, token)); next.append(hypothesis.ids + [token])
                }
            }
            let results = try batch.scores(items, allowed: allowed)
            live = zip(results, next).map { ($0.cache, $1) }
            for (index, (result, sequence)) in zip(results, next).enumerated() {
                assertClose(result.logProbabilities, try reference(full, sequence, allowed),
                            tolerance: batch.tolerance, "step \(step) row \(index)")
            }
        }
        XCTAssertEqual(batch.predictions, steps + 1)
    }

    /// A long prompt in one call, and its cache, match a full pass.
    func testPromptInOneCall() throws {
        let full = try VimeKVBatchLanguageModel(bundle: bundle), tokenizer = try tokenizer()
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        let ids = [Int32(2)] + (try tokenizer.encode("今天天气很好我们去公园散步吧，中文输入法很好用"))
        let allowed = (0..<1024).map { Int32($0 * 12) }
        let prompt = try batch.prompt(ids, allowed: allowed)
        XCTAssertEqual(prompt.cache.length, ids.count)
        assertClose(prompt.logProbabilities, try reference(full, ids, allowed), tolerance: batch.tolerance, "prompt")
        let token = try tokenizer.encode("的")[0]
        let child = try batch.scores([(prompt.cache, token)], allowed: allowed)[0]
        assertClose(child.logProbabilities, try reference(full, ids + [token], allowed), tolerance: batch.tolerance, "child")
        XCTAssertEqual(batch.predictions, 2)
    }

    /// `score` gives, at every position, what a full pass of `logits` up to
    /// there gives for the next token.
    func testScoreAgreesWithTheLogitsFunction() throws {
        let batch = try VimeKVBatchLanguageModel(bundle: bundle), tokenizer = try tokenizer()
        for text in ["今天天气很好", "晚上一起吃饭吗，好的我七点到"] {
            let ids = [Int32(2)] + (try tokenizer.encode(text))
            let scores = try batch.scores(after: try batch.prefix([]), rows: [ids])[0]
            XCTAssertEqual(scores.count, ids.count - 1)
            for end in 1..<ids.count {
                let expected = try ChineseConstrainedGeneration.logProbabilities(try batch.logits(Array(ids[..<end])),
                                                                                of: [ids[end]])[0]
                XCTAssertTrue(batch.tolerance.accepts(scores[end - 1], reference: expected),
                              "\(text) token \(end): \(scores[end - 1]) vs \(expected)")
            }
        }
        XCTAssertEqual(batch.loadedFunctions, [.score, .logits])
    }

    func testRejectsWhatDoesNotFit() throws {
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        let prompt = try batch.prompt([2], allowed: [3]).cache
        XCTAssertThrowsError(try batch.scores([(prompt, 7)], allowed: []))
        XCTAssertThrowsError(try batch.scores([(prompt, 7)], allowed: [12288]))
        XCTAssertThrowsError(try batch.scores([(prompt, 7)], allowed: [Int32](repeating: 3, count: 1025)))
        XCTAssertThrowsError(try batch.prompt([], allowed: [3]))
        XCTAssertThrowsError(try batch.prompt([Int32](repeating: 7, count: 129), allowed: [3]))
    }
}
