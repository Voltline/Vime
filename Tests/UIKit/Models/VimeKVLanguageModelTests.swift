import XCTest
import CoreML
@testable import Vime

/// The zh-v1 KV-cache package against the stateless package it ships with:
/// step-by-step logits match a full forward pass within the tolerance VimeML
/// published for the pair.
final class VimeKVLanguageModelTests: XCTestCase {
    private var bundle: Bundle { Bundle(for: Self.self) }

    private func models() throws -> (kv: VimeKVLanguageModel, stateless: VimeLanguageModel) {
        let stateless = try VimeLanguageModel(bundle: bundle, variant: .zhV1)
        return (try VimeKVLanguageModel(bundle: bundle, tokenizer: stateless.tokenizer), stateless)
    }

    private func row(_ logits: MLMultiArray, _ index: Int) -> [Float] {
        let pointer = logits.dataPointer.assumingMemoryBound(to: Float.self).advanced(by: index * logits.strides[1].intValue)
        let stride = logits.strides[2].intValue
        return (0..<logits.shape[2].intValue).map { pointer[$0 * stride] }
    }

    private func assertClose(_ value: [Float], _ reference: [Float], tolerance: VimeKVLanguageModel.Tolerance,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value.count, reference.count, message, file: file, line: line)
        let outside = zip(value, reference).filter { !tolerance.accepts($0, reference: $1) }.count
        let worst = zip(value, reference).map { abs($0 - $1) }.max() ?? 0
        XCTAssertEqual(outside, 0, "\(message): \(outside) logits outside tolerance, worst \(worst)", file: file, line: line)
        XCTAssertEqual(value.indices.max { value[$0] < value[$1] }, reference.indices.max { reference[$0] < reference[$1] },
                       "\(message): argmax", file: file, line: line)
    }

    func testLoadsThePublishedPackage() throws {
        let (kv, stateless) = try models()
        XCTAssertEqual(kv.modelVersion, stateless.modelVersion + "-kv")
        XCTAssertEqual(kv.tolerance, VimeKVLanguageModel.Tolerance(atol: 3e-4, rtol: 3e-4))
        XCTAssertEqual(kv.vocabularySize, 12288)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try VimeKVLanguageModel(bundle: try XCTUnwrap(Bundle(path: empty.path))))
    }

    /// The cache buffers start zeroed, and positions a call did not write stay
    /// so: the package reads them before masking, and NaN there would reach
    /// every output.
    func testCacheBuffersStartZeroed() throws {
        // Leave NaN in freed memory first, the way earlier arrays could.
        for _ in 0..<4 {
            let junk = try MLMultiArray(shape: [9, 1, 6, 128, 64], dataType: .float32)
            junk.dataPointer.initializeMemory(as: Float.self, repeating: .nan, count: junk.count)
        }
        let zeroed = try VimeKVLanguageModel.zeroed([9, 1, 6, 128, 64])
        XCTAssertTrue(UnsafeBufferPointer(start: zeroed.dataPointer.assumingMemoryBound(to: Float.self), count: zeroed.count)
            .allSatisfy { $0 == 0 })

        let (kv, _) = try models()
        func untouched(after length: Int) -> Bool {
            [kv.keys, kv.values].allSatisfy { array in
                let strides = array.strides.map(\.intValue)
                let base = array.dataPointer.assumingMemoryBound(to: Float.self)
                return (0..<9).allSatisfy { layer in (0..<6).allSatisfy { head in (length..<128).allSatisfy { position in
                    (0..<64).allSatisfy { base[layer * strides[0] + head * strides[2] + position * strides[3] + $0 * strides[4]] == 0 }
                } } }
            }
        }
        XCTAssertTrue(untouched(after: 0))
        let step = try kv.forward([2, 7, 9])
        _ = try kv.forward([11], after: step.cache)
        XCTAssertTrue(untouched(after: 4))
        XCTAssertTrue(step.logits.allSatisfy(\.isFinite))
    }

    func testStepByStepLogitsMatchAFullForwardPass() throws {
        let (kv, stateless) = try models()
        for text in ["今天天气很好，我们去公园散步吧。", "输入法", "他说：“明天见！”"] {
            let ids = [Int32(2)] + (try kv.tokenizer.encode(text))
            let full = try stateless.predict(ids)
            var step = try kv.forward([ids[0]])
            assertClose(step.logits, row(full, 0), tolerance: kv.tolerance, "\(text) BOS")
            for index in 1..<ids.count {
                step = try kv.forward([ids[index]], after: step.cache)
                assertClose(step.logits, row(full, index), tolerance: kv.tolerance, "\(text) token \(index)")
            }
            XCTAssertEqual(step.cache.length, ids.count)
        }
    }

    func testAPromptChunkThenSingleTokensMatch() throws {
        let (kv, stateless) = try models()
        let ids = [Int32(2)] + (try kv.tokenizer.encode("我们明天下午三点在会议室开会"))
        let full = try stateless.predict(ids)
        let split = ids.count / 2
        var step = try kv.forward(Array(ids[..<split]))
        assertClose(step.logits, row(full, split - 1), tolerance: kv.tolerance, "chunk")
        for index in split..<ids.count {
            step = try kv.forward([ids[index]], after: step.cache)
            assertClose(step.logits, row(full, index), tolerance: kv.tolerance, "token \(index)")
        }
    }

    func testBranchesKeepTheirOwnRows() throws {
        let (kv, stateless) = try models()
        let prompt = [Int32(2)] + (try kv.tokenizer.encode("今天"))
        let a = try kv.tokenizer.encode("天气很好"), b = try kv.tokenizer.encode("下午开会")
        let parent = try kv.forward(prompt)
        // The parent's new rows go in once, for its first child; its other children copy nothing.
        let copied = kv.copiedRows
        var left = try kv.forward([a[0]], after: parent.cache)
        XCTAssertEqual(kv.copiedRows - copied, prompt.count)
        let afterFirst = kv.copiedRows
        var right = try kv.forward([b[0]], after: parent.cache)
        XCTAssertEqual(kv.copiedRows, afterFirst, "the parent's rows are already in place")
        // Interleave the branches; each must still see only its own tokens.
        for index in 1..<min(a.count, b.count) {
            left = try kv.forward([a[index]], after: left.cache)
            right = try kv.forward([b[index]], after: right.cache)
        }
        let count = min(a.count, b.count)
        let leftFull = try stateless.predict(prompt + a.prefix(count))
        let rightFull = try stateless.predict(prompt + b.prefix(count))
        assertClose(left.logits, row(leftFull, prompt.count + count - 1), tolerance: kv.tolerance, "left")
        assertClose(right.logits, row(rightFull, prompt.count + count - 1), tolerance: kv.tolerance, "right")
        // Going back to the shared parent copies nothing: its rows never left.
        let before = kv.copiedRows
        let again = try kv.forward([a[0]], after: parent.cache)
        XCTAssertEqual(kv.copiedRows, before)
        assertClose(again.logits, row(leftFull, prompt.count), tolerance: kv.tolerance, "parent reused")
        XCTAssertEqual(parent.cache.ownBytes, prompt.count * 2 * VimeKVLanguageModel.rowFloats * 4)
        XCTAssertEqual(again.cache.ownBytes, 2 * VimeKVLanguageModel.rowFloats * 4, "a child stores only its own position")
    }

    func testRejectsWhatDoesNotFit() throws {
        let (kv, _) = try models()
        XCTAssertThrowsError(try kv.forward([]))
        XCTAssertThrowsError(try kv.forward([12288]))
        XCTAssertThrowsError(try kv.forward([Int32](repeating: 7, count: 129)))
        let full = try kv.forward([Int32](repeating: 7, count: 128))
        XCTAssertThrowsError(try kv.forward([7], after: full.cache))
    }
}
