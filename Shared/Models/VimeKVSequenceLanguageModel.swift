import Foundation
import CoreML

/// The zh-v1 sequence-scoring KV package (kv_sequence): the batched KV
/// package with a head that returns, for every input position, the log
/// probability of a given next token (`targets`), normalized over the whole
/// vocabulary. Same vimeml-tiny-zh-v1 checkpoint and INT8 weights; VimeML
/// checked it against the stateless package.
///
/// Scoring known continuations of one prefix needs no step per token: the
/// prefix (all but its last token) runs once, then each call takes up to 16
/// continuations as rows of [last prefix token] + continuation[:-1] with the
/// continuation as targets, every row on the prefix's cache. Rows shorter
/// than the longest are padded on the right, and the padding is ignored.
///
/// Masked cache slots are still read, so every buffer starts zeroed.
/// Confined to the model queue, like `VimeLanguageModel`.
nonisolated final class VimeKVSequenceLanguageModel {
    typealias Tolerance = VimeKVLanguageModel.Tolerance
    private struct Manifest: Decodable {
        struct Sequence: Decodable {
            let resource: String
            let compiled_files_sha256: [String: String]
            let cache_dtype: String
            let batch_range: [Int]
            let compute_units: String
            let head: String
            let alignment_tolerance: Tolerance
        }
        let format: String
        let tokenizer_sha256: String
        let kv_sequence: Sequence
    }

    static let manifestResource = "VimeLMManifestZhV1KVSequence"
    static let manifestFormat = "vime_ios_lm_zh_v1_kv_sequence"
    static let layers = VimeKVLanguageModel.layers, heads = VimeKVLanguageModel.heads
    static let headDimension = VimeKVLanguageModel.headDimension
    static let contextLength = VimeKVLanguageModel.contextLength
    let vocabularySize = VimeLanguageModel.Variant.zhV1.vocabulary
    let maximumBatch: Int
    let tolerance: Tolerance
    private let model: MLModel

    /// For tests and measurements.
    private(set) var predictions = 0

    init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .cpuOnly) throws {
        guard let manifestURL = bundle.url(forResource: Self.manifestResource, withExtension: "json")
        else { throw VimeLanguageModel.Failure.resources }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let sequence = manifest.kv_sequence
        guard manifest.format == Self.manifestFormat, sequence.cache_dtype == "float32", sequence.head == "sequence",
              sequence.compute_units == "CPU_ONLY", sequence.batch_range.count == 2, sequence.batch_range[0] == 1,
              sequence.batch_range[1] >= 1, !sequence.compiled_files_sha256.isEmpty,
              sequence.compiled_files_sha256.keys.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") })
        else { throw VimeLanguageModel.Failure.integrity }
        let name = (sequence.resource as NSString).deletingPathExtension
        guard let modelURL = bundle.url(forResource: name, withExtension: "mlmodelc")
        else { throw VimeLanguageModel.Failure.resources }
        maximumBatch = sequence.batch_range[1]
        tolerance = sequence.alignment_tolerance
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    /// The log probability of each token of each continuation after `prefix`
    /// (BOS first, at least one token) and the tokens before it.
    func continuationScores(prefix: [Int32], continuations: [[Int32]]) throws -> [[Float]] {
        let valid = { (token: Int32) in token >= 0 && Int(token) < self.vocabularySize }
        guard !prefix.isEmpty, prefix.allSatisfy(valid), !continuations.isEmpty,
              continuations.allSatisfy({ !$0.isEmpty && $0.allSatisfy(valid) }),
              prefix.count - 1 + continuations.map(\.count).max()! <= Self.contextLength
        else { throw VimeLanguageModel.Failure.tensor }
        let cached = prefix.count - 1
        // The prefix's keys and values, (9, 6, cached, 64) each; none for BOS alone.
        let prefill = cached > 0 ? try run(ids: [Array(prefix.dropLast())], targets: [Array(prefix.dropFirst())],
                                          position: 0, cache: nil).new : nil
        var scores: [[Float]] = []
        for start in stride(from: 0, to: continuations.count, by: maximumBatch) {
            let chunk = Array(continuations[start..<min(start + maximumBatch, continuations.count)])
            let ids = chunk.map { [prefix.last!] + $0.dropLast() }
            let output = try run(ids: ids, targets: chunk, position: cached, cache: prefill)
            scores += output.logProbabilities
        }
        return scores
    }

    /// The log probability of every token after the first of each sequence
    /// (BOS first, two tokens or more), given the tokens before it. Sequences
    /// go in sorted groups of up to 16; each group's common prefix runs once
    /// (its tokens scored by that same call) and the rest of every row in one
    /// more call, so neighbours one slip apart share nearly everything.
    /// `cancelled` is asked before each group.
    func tokenScores(_ sequences: [[Int32]], cancelled: () -> Bool = { false }) throws -> [[Float]] {
        guard !sequences.isEmpty, sequences.allSatisfy({ $0.count >= 2 && $0.count <= Self.contextLength }),
              sequences.allSatisfy({ $0.allSatisfy { $0 >= 0 && Int($0) < vocabularySize } })
        else { throw VimeLanguageModel.Failure.tensor }
        let order = sequences.indices.sorted { sequences[$0].lexicographicallyPrecedes(sequences[$1]) }
        var result = [[Float]](repeating: [], count: sequences.count)
        for start in stride(from: 0, to: order.count, by: maximumBatch) {
            guard !cancelled() else { throw VimeLanguageModel.Failure.cancelled }
            let group = order[start..<min(start + maximumBatch, order.count)].map { sequences[$0] }
            // The longest common prefix that leaves every row a token to score.
            var shared = 1
            let shortest = group.map(\.count).min()!
            while shared < shortest - 1, group.allSatisfy({ $0[shared] == group[0][shared] }) { shared += 1 }
            let prefix = Array(group[0][..<shared])
            var head: [Float] = []
            var prefill: (keys: [Float], values: [Float])?
            if shared > 1 {
                let output = try run(ids: [Array(prefix.dropLast())], targets: [Array(prefix.dropFirst())], position: 0, cache: nil)
                head = output.logProbabilities[0]
                prefill = output.new
            }
            let output = try run(ids: group.map { [prefix.last!] + $0[shared..<($0.count - 1)] },
                                 targets: group.map { Array($0[shared...]) }, position: shared - 1, cache: prefill)
            for (offset, tail) in output.logProbabilities.enumerated() { result[order[start + offset]] = head + tail }
        }
        return result
    }

    /// One call: rows of `ids` (padded right to the longest) after `position`
    /// cached slots shared by every row (`cache`, or nothing at position 0).
    /// Returns each row's target log probabilities, unpadded, and the new keys
    /// and values of row 0.
    private func run(ids: [[Int32]], targets: [[Int32]], position: Int, cache: (keys: [Float], values: [Float])?) throws
        -> (logProbabilities: [[Float]], new: (keys: [Float], values: [Float])) {
        let rows = ids.count, length = ids.map(\.count).max()!
        let shape = [NSNumber(value: rows), NSNumber(value: length)]
        let idArray = try MLMultiArray(shape: shape, dataType: .int32)
        let targetArray = try MLMultiArray(shape: shape, dataType: .int32)
        let idPointer = idArray.dataPointer.assumingMemoryBound(to: Int32.self)
        let targetPointer = targetArray.dataPointer.assumingMemoryBound(to: Int32.self)
        let idStride = idArray.strides[0].intValue, targetStride = targetArray.strides[0].intValue
        for row in 0..<rows {
            for column in 0..<length {
                idPointer[row * idStride + column] = column < ids[row].count ? ids[row][column] : 0
                targetPointer[row * targetStride + column] = column < targets[row].count ? targets[row][column] : 0
            }
        }
        let positions = try MLMultiArray(shape: [NSNumber(value: rows)], dataType: .int32)
        let positionPointer = positions.dataPointer.assumingMemoryBound(to: Int32.self)
        for row in 0..<rows { positionPointer[row] = Int32(position) }
        // Every row reads the same slots: copied into each row, zeroed when empty.
        let slots = max(position, 1)
        let cacheShape = [Self.layers, rows, Self.heads, slots, Self.headDimension].map { NSNumber(value: $0) }
        let keyCache = try VimeKVLanguageModel.zeroed(cacheShape)
        let valueCache = try VimeKVLanguageModel.zeroed(cacheShape)
        if let cache {
            let perHead = position * Self.headDimension
            for (array, source) in [(keyCache, cache.keys), (valueCache, cache.values)] {
                let strides = array.strides.map(\.intValue)
                let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
                source.withUnsafeBufferPointer { from in
                    for layer in 0..<Self.layers {
                        for head in 0..<Self.heads {
                            let origin = from.baseAddress!.advanced(by: (layer * Self.heads + head) * perHead)
                            for row in 0..<rows {
                                pointer.advanced(by: layer * strides[0] + row * strides[1] + head * strides[2])
                                    .update(from: origin, count: perHead)
                            }
                        }
                    }
                }
            }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": idArray, "position": positions, "key_cache": keyCache, "value_cache": valueCache,
            "targets": targetArray])
        return try autoreleasepool {
            let output = try model.prediction(from: features)
            predictions += 1
            guard let logProbabilities = output.featureValue(for: "target_logprobs")?.multiArrayValue,
                  let newKeys = output.featureValue(for: "new_key")?.multiArrayValue,
                  let newValues = output.featureValue(for: "new_value")?.multiArrayValue,
                  logProbabilities.dataType == .float32, newKeys.dataType == .float32, newValues.dataType == .float32,
                  logProbabilities.shape.map(\.intValue) == [rows, length],
                  newKeys.shape.map(\.intValue) == [Self.layers, rows, Self.heads, length, Self.headDimension],
                  newValues.shape == newKeys.shape
            else { throw VimeLanguageModel.Failure.tensor }
            let strides = logProbabilities.strides.map(\.intValue)
            let scores: [[Float]] = logProbabilities.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                (0..<rows).map { row in (0..<targets[row].count).map { buffer[row * strides[0] + $0 * strides[1]] } }
            }
            guard scores.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { throw VimeLanguageModel.Failure.tensor }
            return (scores, (Self.firstRow(newKeys, length: ids[0].count), Self.firstRow(newValues, length: ids[0].count)))
        }
    }

    /// Row 0 of a (9, B, 6, T, 64) output, its first `length` slots, as (9, 6, length, 64).
    private static func firstRow(_ array: MLMultiArray, length: Int) -> [Float] {
        let strides = array.strides.map(\.intValue)
        return array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            var result: [Float] = []
            result.reserveCapacity(layers * heads * length * headDimension)
            for layer in 0..<layers {
                for head in 0..<heads {
                    for slot in 0..<length {
                        let base = layer * strides[0] + head * strides[2] + slot * strides[3]
                        for d in 0..<headDimension { result.append(buffer[base + d * strides[4]]) }
                    }
                }
            }
            return result
        }
    }
}
