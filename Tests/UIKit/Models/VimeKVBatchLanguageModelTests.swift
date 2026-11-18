import XCTest
import CoreML
@testable import Vime

/// The zh-v1 batched KV package (kvbatch-v3: the prompt as a prefix shared by
/// every row, scores for the allowed ids only): VimeML's 16-row fixture, and
/// rows that grow over several calls, against the stateless package.
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

    /// The stateless package's log probabilities of `allowed` after `ids`.
    private func reference(_ stateless: VimeLanguageModel, _ ids: [Int32], _ allowed: [Int32]) throws -> [Float] {
        let full = try stateless.predict(ids)
        let pointer = full.dataPointer.assumingMemoryBound(to: Float.self)
            .advanced(by: (ids.count - 1) * full.strides[1].intValue)
        let logits = (0..<12288).map { pointer[$0 * full.strides[2].intValue] }
        return try ChineseConstrainedGeneration.logProbabilities(logits, of: allowed)
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
    /// each call; each matches a full pass of the stateless package.
    func testRowsGrowAndBranch() throws {
        let stateless = try VimeLanguageModel(bundle: bundle, variant: .zhV1)
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        let texts = ["今天天气很好我们去公园", "中文输入法很好用", "我想吃饭了", "明天下午三点开会"]
        let ids = try texts.map { [Int32(2)] + (try stateless.tokenizer.encode($0)) }
        let first = (0..<300).map { Int32($0 * 40) }
        let start = try batch.prompt([2], allowed: first)
        assertClose(start.logProbabilities, try reference(stateless, [2], first), tolerance: batch.tolerance, "prompt")
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
                assertClose(result.logProbabilities, try reference(stateless, sequence, allowed),
                            tolerance: batch.tolerance, "step \(step) row \(index)")
            }
        }
        XCTAssertEqual(batch.predictions, steps + 1)
    }

    /// A long prompt in one call, and its cache, match the stateless package.
    func testPromptInOneCall() throws {
        let stateless = try VimeLanguageModel(bundle: bundle, variant: .zhV1)
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        let ids = [Int32(2)] + (try stateless.tokenizer.encode("今天天气很好我们去公园散步吧，中文输入法很好用"))
        let allowed = (0..<1024).map { Int32($0 * 12) }
        let prompt = try batch.prompt(ids, allowed: allowed)
        XCTAssertEqual(prompt.cache.length, ids.count)
        assertClose(prompt.logProbabilities, try reference(stateless, ids, allowed), tolerance: batch.tolerance, "prompt")
        let token = try stateless.tokenizer.encode("的")[0]
        let child = try batch.scores([(prompt.cache, token)], allowed: allowed)[0]
        assertClose(child.logProbabilities, try reference(stateless, ids + [token], allowed), tolerance: batch.tolerance, "child")
        XCTAssertEqual(batch.predictions, 2)
    }

    /// The `logits` function with no prefix and no own cache gives what the
    /// stateless package gives, before the stateless one can go.
    func testLogitsFunctionMatchesTheStatelessPackage() throws {
        let stateless = try VimeLanguageModel(bundle: bundle, variant: .zhV1)
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        for text in ["今天天气很好", "晚上一起吃饭吗，好的我七点到"] {
            let ids = [Int32(2)] + (try stateless.tokenizer.encode(text))
            let full = try stateless.predict(ids)
            let pointer = full.dataPointer.assumingMemoryBound(to: Float.self)
                .advanced(by: (ids.count - 1) * full.strides[1].intValue)
            let reference = (0..<12288).map { pointer[$0 * full.strides[2].intValue] }
            assertClose(try batch.logits(ids), reference, tolerance: batch.tolerance, text)
        }
        XCTAssertEqual(batch.loadedFunctions, [.logits])
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
