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

    /// Batched `scored` (16 rows, then a 3-row subset in another order) matches
    /// full-sequence `logits` on the bundled `zh-v2-20m` package.
    func testMatchesVimeMLFixture() throws {
        let (promptIDs, rows, allowed, _) = try fixture()
        XCTAssertEqual(rows.count, 16)
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        let full = try VimeKVBatchLanguageModel(bundle: bundle)
        let prompt = try batch.prompt(promptIDs, allowed: allowed).cache
        let own = try rows.map { row -> VimeKVLanguageModel.Cache in
            var cache = prompt
            for token in row.own_ids { cache = try batch.scores([(cache, token)], allowed: allowed)[0].cache }
            return cache
        }
        let expected = try rows.map { row in
            try reference(full, promptIDs + row.own_ids + [row.token], allowed)
        }
        let before = batch.predictions
        let all = try batch.scores(zip(own, rows).map { ($0, $1.token) }, allowed: allowed)
        XCTAssertEqual(batch.predictions - before, 1)
        for (index, result) in all.enumerated() {
            assertClose(result.logProbabilities, expected[index], tolerance: batch.tolerance, "row \(index) batch 16")
            XCTAssertEqual(result.cache.length, promptIDs.count + rows[index].own_ids.count + 1)
        }
        // Fewer rows at once, in another order: the same values.
        let subset = [5, 0, 11]
        let results = try batch.scores(subset.map { (own[$0], rows[$0].token) }, allowed: allowed)
        for (index, result) in zip(subset, results) {
            assertClose(result.logProbabilities, expected[index], tolerance: batch.tolerance, "row \(index) batch 3")
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

    /// A prefix built from the last one (the same tokens, fewer, more, or
    /// another ending) scores as a prefix built afresh, and runs only the
    /// tokens it does not share.
    func testPrefixReusesTheLastOne() throws {
        let tokenizer = try tokenizer()
        let reusing = try VimeKVBatchLanguageModel(bundle: bundle)
        let fresh = try VimeKVBatchLanguageModel(bundle: bundle)
        fresh.reusesPrefixes = false
        let rows = try ["我们去公园", "开会讨论"].map { [Int32(2)] + (try tokenizer.encode($0)) }.map { Array($0.dropFirst()) }
        func ids(_ text: String) throws -> [Int32] { [Int32(2)] + (try tokenizer.encode(text)) }
        let contexts = try ["明天下午三点", "明天下午三点", "明天下午三点在公司", "明天", "明天上午九点半在家里", "今天晚上"].map(ids)
        var expectedRuns = 0
        var last: [Int32] = []
        for context in contexts {
            var shared = 0
            while shared < min(last.count, context.count), last[shared] == context[shared] { shared += 1 }
            expectedRuns += context.count - shared
            last = context
            let before = reusing.prefixTokensRun
            let reused = try reusing.scores(after: try reusing.prefix(context), rows: rows)
            let expected = try fresh.scores(after: try fresh.prefix(context), rows: rows)
            XCTAssertEqual(reusing.prefixTokensRun - before, context.count - shared, "\(context)")
            for (a, b) in zip(reused, expected) {
                assertClose(a, b, tolerance: reusing.tolerance, "context \(context)")
            }
        }
        XCTAssertEqual(reusing.prefixTokensRun, expectedRuns)
        XCTAssertEqual(reusing.prefixesReused, 2) // the repeat, and the shorter one
        XCTAssertEqual(reusing.loadedFunctions, [.prefix, .score])
        XCTAssertEqual(fresh.prefixTokensRun, contexts.map(\.count).reduce(0, +))
    }

    /// Dropping from a long context to a much shorter shared prefix slices the
    /// cached KV down without rerunning the model, and `forgetPrefix` clears it.
    func testPrefixTrimsLongCacheWhenContextShrinks() throws {
        let tokenizer = try tokenizer()
        let reusing = try VimeKVBatchLanguageModel(bundle: bundle)
        let fresh = try VimeKVBatchLanguageModel(bundle: bundle)
        fresh.reusesPrefixes = false
        let rows = try ["我们去公园", "开会讨论"].map { try tokenizer.encode($0) }
        func ids(_ text: String) throws -> [Int32] { [Int32(2)] + (try tokenizer.encode(text)) }

        let long = try ids("明天下午三点在公司会议室讨论下一个季度的工作计划和人员安排，然后再一起去附近的公园散步")
        let short = Array(long.prefix(2))
        XCTAssertGreaterThan(long.count - short.count, 16)

        _ = try reusing.prefix(long)
        let beforeShrink = reusing.prefixTokensRun
        let trimmed = try reusing.prefix(short)
        XCTAssertEqual(reusing.prefixTokensRun, beforeShrink)
        XCTAssertEqual(trimmed.length, short.count)
        XCTAssertEqual(trimmed.capacity, short.count)

        let reusedScores = try reusing.scores(after: trimmed, rows: rows)
        let freshScores = try fresh.scores(after: try fresh.prefix(short), rows: rows)
        for (a, b) in zip(reusedScores, freshScores) {
            assertClose(a, b, tolerance: reusing.tolerance, "trimmed prefix")
        }

        // Branching early from a long prefix also trims before running the tail.
        _ = try reusing.prefix(long)
        let branched = try ids("明天早晨九点出发")
        let branchPrefix = try reusing.prefix(branched)
        XCTAssertEqual(branchPrefix.capacity, branched.count)
        let branchScores = try reusing.scores(after: branchPrefix, rows: rows)
        let freshBranchScores = try fresh.scores(after: try fresh.prefix(branched), rows: rows)
        for (a, b) in zip(branchScores, freshBranchScores) {
            assertClose(a, b, tolerance: reusing.tolerance, "early branch")
        }

        // Forgetting the cached prefix forces the next identical call to rerun.
        reusing.forgetPrefix()
        let beforeRerun = reusing.prefixTokensRun
        _ = try reusing.prefix(branched)
        XCTAssertEqual(reusing.prefixTokensRun - beforeRerun, branched.count)
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

    func testReleaseTransientBuffersReclaimsMemoryAndRecoversCleanly() throws {
        let batch = try VimeKVBatchLanguageModel(bundle: bundle)
        let root = try batch.prompt([2, 10, 20], allowed: [3, 7]).cache
        let first = try batch.scores([(root, 7)], allowed: [3, 8])
        XCTAssertGreaterThan(batch.bufferBytes, 0)

        batch.releaseTransientBuffers()
        XCTAssertEqual(batch.bufferBytes, 0)

        let rootAgain = try batch.prompt([2, 10, 20], allowed: [3, 7]).cache
        let second = try batch.scores([(rootAgain, 7)], allowed: [3, 8])
        assertClose(first[0].logProbabilities, second[0].logProbabilities, tolerance: batch.tolerance, "after release")
    }
}
