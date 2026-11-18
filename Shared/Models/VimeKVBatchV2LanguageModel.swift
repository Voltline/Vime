import Foundation
import CoreML
import Accelerate

/// The fallback for kvbatch-v3 until v3 is measured on devices.
///
/// The zh-v1 batched KV package (kvbatch-v2, "Batched KV v2" on VimeML's
/// model page): one package for the prompt and for the beam steps, so the
/// chunk package is not needed. It is the same vimeml-tiny-zh-v1 checkpoint
/// and INT8 weights as the stateless and chunk packages — only the package
/// changed; VimeML checked it against the stateless one.
///
/// A call takes up to 16 rows, each one or more new tokens on top of its own
/// cache (keys and values as (9, B, 6, S, 64), S = the longest row, at least
/// 1), and a list of token ids shared by every row. It returns only the log
/// probabilities of those ids after each row (`allowed_logits − logsumexp`),
/// so no softmax runs here, and the new tokens' keys and values
/// ((9, B, 6, T, 64)), which this class writes into its own buffers and into
/// the new `Cache`. The prompt is one call with B = 1.
///
/// The buffers grow to the rows and slots calls need. Each slot remembers
/// which `Cache` wrote it, so a hypothesis placed in a row that already holds
/// its ancestors copies only the slots that differ. The arrays handed to
/// Core ML are views of the buffers with their strides; outputs go into
/// arrays kept for each batch size. Slots a row does not use are still read
/// by the package before it masks them, so every buffer starts zeroed: junk
/// that happens to be NaN would spread to every output.
///
/// Confined to the model queue, like `VimeLanguageModel`.
nonisolated final class VimeKVBatchV2LanguageModel {
    typealias Cache = VimeKVLanguageModel.Cache
    typealias Tolerance = VimeKVLanguageModel.Tolerance
    private struct Manifest: Decodable {
        struct Batch: Decodable {
            let resource: String
            let compiled_files_sha256: [String: String]
            let cache_dtype: String
            let batch_range: [Int]
            let compute_units: String
            let alignment_tolerance: Tolerance
        }
        let format: String
        let tokenizer_sha256: String
        let kv_batch_v2: Batch
    }

    static let manifestResource = "VimeLMManifestZhV1KVBatchV2"
    static let manifestFormat = "vime_ios_lm_zh_v1_kv_batch_v2"
    /// Most allowed ids in one call.
    static let maximumAllowed = 1024
    static let layers = VimeKVLanguageModel.layers, heads = VimeKVLanguageModel.heads
    static let headDimension = VimeKVLanguageModel.headDimension
    static let rowFloats = VimeKVLanguageModel.rowFloats
    static let contextLength = VimeKVLanguageModel.contextLength
    let vocabularySize = VimeLanguageModel.Variant.zhV1.vocabulary
    let maximumBatch: Int
    let tolerance: Tolerance
    private let model: MLModel

    /// Keys and values, (9, rows, 6, slots, 64) each.
    private var keys: UnsafeMutablePointer<Float>?
    private var values: UnsafeMutablePointer<Float>?
    private var rows = 0, slots = 0
    /// Which `Cache` wrote each slot of each row (0: nobody).
    private var owners: [[UInt64]] = []
    /// Per batch size: inputs and preallocated outputs; outputs nil once Core ML refused them.
    private struct Arrays {
        let ids: MLMultiArray, positions: MLMultiArray
        var sums: MLMultiArray?, newKeys: MLMultiArray?, newValues: MLMultiArray?
    }
    private var arrays: [Int: Arrays] = [:]
    /// The allowed ids and their logits, viewed as [K] and [B, K] each call.
    private let allowedIDs: UnsafeMutablePointer<Int32>
    private let allowedLogits: UnsafeMutablePointer<Float>
    /// Whether Core ML takes the [B, K] view of `allowedLogits` as an output.
    private var allowedBackings = true

    /// For tests and measurements.
    private(set) var predictions = 0
    private(set) var rowsPredicted = 0
    private(set) var copiedSlots = 0
    /// Seconds per stage: placing rows (copying slots), building inputs,
    /// Core ML, reading the log probabilities, writing the new keys and values.
    private(set) var copySeconds = 0.0
    private(set) var inputSeconds = 0.0
    private(set) var predictionSeconds = 0.0
    private(set) var outputSeconds = 0.0
    private(set) var writeSeconds = 0.0

    init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .cpuOnly) throws {
        guard let manifestURL = bundle.url(forResource: Self.manifestResource, withExtension: "json")
        else { throw VimeLanguageModel.Failure.resources }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let batch = manifest.kv_batch_v2
        guard manifest.format == Self.manifestFormat, batch.cache_dtype == "float32",
              batch.compute_units == "CPU_ONLY", batch.batch_range.count == 2, batch.batch_range[0] == 1,
              batch.batch_range[1] >= 1, !batch.compiled_files_sha256.isEmpty,
              batch.compiled_files_sha256.keys.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") })
        else { throw VimeLanguageModel.Failure.integrity }
        let name = (batch.resource as NSString).deletingPathExtension
        guard let modelURL = bundle.url(forResource: name, withExtension: "mlmodelc")
        else { throw VimeLanguageModel.Failure.resources }
        maximumBatch = batch.batch_range[1]
        tolerance = batch.alignment_tolerance
        allowedIDs = .allocate(capacity: Self.maximumAllowed)
        allowedLogits = .allocate(capacity: maximumBatch * Self.maximumAllowed)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    deinit { keys?.deallocate(); values?.deallocate(); allowedIDs.deallocate(); allowedLogits.deallocate() }

    /// Bytes the cache buffers take.
    var bufferBytes: Int { 2 * Self.layers * rows * Self.heads * slots * Self.headDimension * 4 }

    /// Runs one token after each cache (nil: at the start) and returns the
    /// log probabilities of `allowed` (at most `maximumAllowed` ids) after
    /// it, with the cache that covers it. The caches stay valid.
    func scores(_ items: [(cache: Cache?, token: Int32)], allowed: [Int32]) throws -> [(logProbabilities: [Float], cache: Cache)] {
        try checked(allowed)
        guard !items.isEmpty, items.count <= maximumBatch,
              items.allSatisfy({ ($0.cache?.length ?? 0) < Self.contextLength && $0.token >= 0 && $0.token < vocabularySize })
        else { throw VimeLanguageModel.Failure.tensor }
        return try step(items, allowed: allowed)
    }

    private func checked(_ allowed: [Int32]) throws {
        guard !allowed.isEmpty, allowed.count <= Self.maximumAllowed,
              allowed.allSatisfy({ $0 >= 0 && Int($0) < vocabularySize })
        else { throw VimeLanguageModel.Failure.tensor }
    }

    /// The whole prompt in one call (B = 1): the log probabilities of
    /// `allowed` after it, and its cache.
    func prompt(_ tokens: [Int32], allowed: [Int32]) throws -> (logProbabilities: [Float], cache: Cache) {
        guard !tokens.isEmpty, tokens.count <= Self.contextLength,
              tokens.allSatisfy({ $0 >= 0 && Int($0) < vocabularySize })
        else { throw VimeLanguageModel.Failure.tensor }
        try checked(allowed)
        var clock = ProcessInfo.processInfo.systemUptime
        func lap(_ total: inout Double) {
            let now = ProcessInfo.processInfo.systemUptime; total += now - clock; clock = now
        }
        let count = tokens.count
        let ids = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
        let idPointer = ids.dataPointer.assumingMemoryBound(to: Int32.self)
        for (index, token) in tokens.enumerated() { idPointer[index] = token }
        let position = try MLMultiArray(shape: [1], dataType: .int32)
        position.dataPointer.assumingMemoryBound(to: Int32.self)[0] = 0
        // Nothing is cached yet: one slot, ignored, but zeroed (a fresh
        // MLMultiArray may hold NaN junk, which would reach every output).
        let empty = try VimeKVLanguageModel.zeroed([9, 1, 6, 1, 64])
        let allowedArray = try allowedView(allowed)
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": ids, "position": position, "key_cache": empty, "value_cache": empty, "allowed": allowedArray])
        lap(&inputSeconds)
        return try autoreleasepool {
            let output = try model.prediction(from: features)
            lap(&predictionSeconds)
            predictions += 1; rowsPredicted += 1
            guard let sums = output.featureValue(for: "logsumexp")?.multiArrayValue,
                  let logits = output.featureValue(for: "allowed_logits")?.multiArrayValue,
                  let newKeys = output.featureValue(for: "new_key")?.multiArrayValue,
                  let newValues = output.featureValue(for: "new_value")?.multiArrayValue,
                  sums.dataType == .float32, logits.dataType == .float32,
                  newKeys.dataType == .float32, newValues.dataType == .float32,
                  sums.shape.map(\.intValue) == [1], logits.shape.map(\.intValue) == [1, allowed.count],
                  newKeys.shape.map(\.intValue) == [Self.layers, 1, Self.heads, count, Self.headDimension],
                  newValues.shape == newKeys.shape
            else { throw VimeLanguageModel.Failure.tensor }
            let scores = Self.logProbabilities(sums: sums, logits: logits, rows: [0], allowed: allowed.count)[0]
            lap(&outputSeconds)
            let rows = [Float](unsafeUninitializedCapacity: 2 * Self.rowFloats * count) { buffer, initialized in
                for slot in 0..<count {
                    let target = buffer.baseAddress!.advanced(by: slot * 2 * Self.rowFloats)
                    Self.copyNew(newKeys, row: 0, slot: slot, to: target)
                    Self.copyNew(newValues, row: 0, slot: slot, to: target.advanced(by: Self.rowFloats))
                }
                initialized = 2 * Self.rowFloats * count
            }
            lap(&writeSeconds)
            return (scores, Cache(parent: nil, start: 0, count: count, rows: rows))
        }
    }

    /// The allowed ids as a [K] view of their buffer.
    private func allowedView(_ allowed: [Int32]) throws -> MLMultiArray {
        allowed.withUnsafeBufferPointer { allowedIDs.update(from: $0.baseAddress!, count: allowed.count) }
        return try MLMultiArray(dataPointer: allowedIDs, shape: [NSNumber(value: allowed.count)], dataType: .int32,
                                strides: [1])
    }

    /// `allowed_logits − logsumexp` for each row asked for.
    private static func logProbabilities(sums: MLMultiArray, logits: MLMultiArray, rows: [Int], allowed: Int) -> [[Float]] {
        let sumStride = sums.strides[0].intValue
        let rowStride = logits.strides[0].intValue, stride = logits.strides[1].intValue
        let normalizers: [Float] = sums.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            rows.map { buffer[$0 * sumStride] }
        }
        return logits.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            zip(rows, normalizers).map { row, normalizer in
                let base = buffer.baseAddress!.advanced(by: row * rowStride)
                return [Float](unsafeUninitializedCapacity: allowed) { target, initialized in
                    if stride == 1 {
                        var shift = -normalizer
                        vDSP_vsadd(base, 1, &shift, target.baseAddress!, 1, vDSP_Length(allowed))
                    } else {
                        for index in 0..<allowed { target[index] = base[index * stride] - normalizer }
                    }
                    initialized = allowed
                }
            }
        }
    }

    private func step(_ items: [(cache: Cache?, token: Int32)], allowed: [Int32]) throws
        -> [(logProbabilities: [Float], cache: Cache)] {
        let count = items.count
        let needed = items.map { $0.cache?.length ?? 0 }.max()! + 1
        if needed > slots || count > rows {
            // Slots in steps of 8, with room to grow; rows as the calls need them.
            let newSlots = needed > slots ? min(Self.contextLength, max((needed + 7) / 8 * 8, slots + slots / 2)) : slots
            reserve(rows: max(rows, count), slots: newSlots)
        }
        var clock = ProcessInfo.processInfo.systemUptime
        func lap(_ total: inout Double) {
            let now = ProcessInfo.processInfo.systemUptime; total += now - clock; clock = now
        }
        let placed = assign(items.map(\.cache))
        lap(&copySeconds)

        if arrays[count] == nil {
            let rows = NSNumber(value: count)
            let newShape: [NSNumber] = [9, rows, 6, 1, 64]
            arrays[count] = Arrays(
                ids: try MLMultiArray(shape: [rows, 1], dataType: .int32),
                positions: try MLMultiArray(shape: [rows], dataType: .int32),
                sums: try? MLMultiArray(shape: [rows], dataType: .float32),
                newKeys: try? MLMultiArray(shape: newShape, dataType: .float32),
                newValues: try? MLMultiArray(shape: newShape, dataType: .float32))
        }
        let set = arrays[count]!
        let idPointer = set.ids.dataPointer.assumingMemoryBound(to: Int32.self)
        let positionPointer = set.positions.dataPointer.assumingMemoryBound(to: Int32.self)
        for (item, row) in placed.enumerated() {
            idPointer[row] = items[item].token
            positionPointer[row] = Int32(items[item].cache?.length ?? 0)
        }
        // The package reads S = the longest row, at least 1; the buffers keep
        // one slot more for the new token.
        let viewSlots = max(needed - 1, 1)
        let shape = [Self.layers, count, Self.heads, viewSlots, Self.headDimension].map { NSNumber(value: $0) }
        let strides = [rows * Self.heads * slots * Self.headDimension, Self.heads * slots * Self.headDimension,
                       slots * Self.headDimension, Self.headDimension, 1].map { NSNumber(value: $0) }
        let keyView = try MLMultiArray(dataPointer: keys!, shape: shape, dataType: .float32, strides: strides)
        let valueView = try MLMultiArray(dataPointer: values!, shape: shape, dataType: .float32, strides: strides)
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": set.ids, "position": set.positions, "key_cache": keyView, "value_cache": valueView,
            "allowed": try allowedView(allowed)])
        lap(&inputSeconds)

        return try autoreleasepool {
            let output = try predict(features, count: count, allowed: allowed.count)
            lap(&predictionSeconds)
            predictions += 1; rowsPredicted += count
            guard let newKeys = output.featureValue(for: "new_key")?.multiArrayValue,
                  let newValues = output.featureValue(for: "new_value")?.multiArrayValue,
                  let sums = output.featureValue(for: "logsumexp")?.multiArrayValue,
                  let logits = output.featureValue(for: "allowed_logits")?.multiArrayValue,
                  newKeys.dataType == .float32, newValues.dataType == .float32,
                  sums.dataType == .float32, logits.dataType == .float32,
                  newKeys.shape.map(\.intValue) == [Self.layers, count, Self.heads, 1, Self.headDimension],
                  newValues.shape == newKeys.shape,
                  sums.shape.map(\.intValue) == [count], logits.shape.map(\.intValue) == [count, allowed.count]
            else { throw VimeLanguageModel.Failure.tensor }
            let rowScores = Self.logProbabilities(sums: sums, logits: logits, rows: placed, allowed: allowed.count)
            lap(&outputSeconds)
            var results: [(logProbabilities: [Float], cache: Cache)] = []
            results.reserveCapacity(count)
            for (index, item) in items.enumerated() {
                let row = placed[index]
                let own = [Float](unsafeUninitializedCapacity: 2 * Self.rowFloats) { buffer, initialized in
                    Self.copyNew(newKeys, row: row, slot: 0, to: buffer.baseAddress!)
                    Self.copyNew(newValues, row: row, slot: 0, to: buffer.baseAddress!.advanced(by: Self.rowFloats))
                    initialized = 2 * Self.rowFloats
                }
                let cache = Cache(parent: item.cache, start: item.cache?.length ?? 0, count: 1, rows: own)
                // The new slot is in place for this row's children.
                own.withUnsafeBufferPointer { write($0.baseAddress!, row: row, slot: cache.start) }
                owners[row][cache.start] = cache.id
                results.append((rowScores[index], cache))
            }
            lap(&writeSeconds)
            return results
        }
    }

    /// Prediction into the preallocated outputs, or Core ML's own when it
    /// refuses them (they are then not offered again for that batch size).
    private func predict(_ features: MLFeatureProvider, count: Int, allowed: Int) throws -> MLFeatureProvider {
        if allowedBackings, let sums = arrays[count]?.sums, let newKeys = arrays[count]?.newKeys,
           let newValues = arrays[count]?.newValues {
            let options = MLPredictionOptions()
            let scores = try MLMultiArray(dataPointer: allowedLogits, shape: [NSNumber(value: count), NSNumber(value: allowed)],
                                          dataType: .float32, strides: [NSNumber(value: allowed), 1])
            options.outputBackings = ["logsumexp": sums, "allowed_logits": scores, "new_key": newKeys, "new_value": newValues]
            if let output = try? model.prediction(from: features, options: options) { return output }
            allowedBackings = false
            arrays[count]?.sums = nil; arrays[count]?.newKeys = nil; arrays[count]?.newValues = nil
        }
        return try model.prediction(from: features)
    }

    /// Whether outputs go into the preallocated arrays, for each batch size used so far.
    var usesOutputBackings: [Int: Bool] { arrays.mapValues { $0.sums != nil && allowedBackings } }

    /// Replaces the buffers with empty ones of this size; rows are reloaded as needed.
    private func reserve(rows newRows: Int, slots newSlots: Int) {
        keys?.deallocate(); values?.deallocate()
        let floats = Self.layers * newRows * Self.heads * newSlots * Self.headDimension
        keys = .allocate(capacity: floats); keys!.initialize(repeating: 0, count: floats)
        values = .allocate(capacity: floats); values!.initialize(repeating: 0, count: floats)
        rows = newRows; slots = newSlots
        owners = Array(repeating: Array(repeating: 0, count: newSlots), count: newRows)
    }

    /// Picks a row among the first `caches.count` for each cache, preferring
    /// rows that already hold the most of its ancestors, and copies in the slots
    /// that differ. Returns the row of each cache.
    private func assign(_ caches: [Cache?]) -> [Int] {
        let count = caches.count
        let chains = caches.map { $0?.chain() ?? [] }
        let wanted: [[UInt64]] = chains.map { chain in
            var ids: [UInt64] = []
            for node in chain { ids.append(contentsOf: repeatElement(node.id, count: node.count)) }
            return ids
        }
        func shared(_ item: Int, _ row: Int) -> Int {
            var matched = 0
            owners[row].withUnsafeBufferPointer { owned in
                for (slot, id) in wanted[item].enumerated() where owned[slot] == id { matched += 1 }
            }
            return matched
        }
        var placed = [Int](repeating: -1, count: count)
        var free = Set(0..<count)
        // Longest caches first: they have the most to lose.
        for item in (0..<count).sorted(by: { wanted[$0].count > wanted[$1].count }) {
            let row = free.max { a, b in
                let x = shared(item, a), y = shared(item, b)
                return x != y ? x < y : a > b
            }!
            free.remove(row)
            placed[item] = row
            for node in chains[item] {
                for offset in 0..<node.count where owners[row][node.start + offset] != node.id {
                    node.rows.withUnsafeBufferPointer {
                        write($0.baseAddress!.advanced(by: offset * 2 * Self.rowFloats), row: row, slot: node.start + offset)
                    }
                    owners[row][node.start + offset] = node.id
                    copiedSlots += 1
                }
            }
        }
        return placed
    }

    /// One slot of one row: keys then values, (layer, head, dimension) each.
    private func write(_ source: UnsafePointer<Float>, row: Int, slot: Int) {
        let layerStride = rows * Self.heads * slots * Self.headDimension
        let rowStride = Self.heads * slots * Self.headDimension
        let headStride = slots * Self.headDimension
        for layer in 0..<Self.layers {
            for head in 0..<Self.heads {
                let offset = layer * layerStride + row * rowStride + head * headStride + slot * Self.headDimension
                let from = (layer * Self.heads + head) * Self.headDimension
                keys!.advanced(by: offset).update(from: source.advanced(by: from), count: Self.headDimension)
                values!.advanced(by: offset).update(from: source.advanced(by: Self.rowFloats + from), count: Self.headDimension)
            }
        }
    }

    /// Slot `slot` of row `row` of a (9, B, 6, T, 64) output, in (layer, head, dimension) order.
    private static func copyNew(_ array: MLMultiArray, row: Int, slot: Int, to target: UnsafeMutablePointer<Float>) {
        let strides = array.strides.map(\.intValue)
        let slotStride = strides[3], step = strides[4]
        array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            let base = buffer.baseAddress!
            for layer in 0..<layers {
                for head in 0..<heads {
                    let source = base.advanced(by: layer * strides[0] + row * strides[1] + head * strides[2] + slot * slotStride)
                    let destination = target.advanced(by: (layer * heads + head) * headDimension)
                    if step == 1 { destination.update(from: source, count: headDimension) }
                    else { for d in 0..<headDimension { destination[d] = source[d * step] } }
                }
            }
        }
    }
}
