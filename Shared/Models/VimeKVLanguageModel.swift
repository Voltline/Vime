import Foundation
import CoreML

/// The zh-v1 chunked KV-cache package, for generation only.
///
/// Same checkpoint, tokenizer and INT8 weights as the stateless package that
/// `VimeLanguageModel(variant: .zhV1)` loads for reranking; VimeML checked the
/// two against each other (the tolerances are in the client manifest). The
/// prompt goes through the model once; after that every hypothesis feeds one
/// new token on top of its parent's cache.
///
/// The package is batch 1 and takes the whole cache (9 × 6 × 128 × 64 floats
/// for keys and again for values, 3.5 MB each) as input on every call. So a
/// hypothesis keeps only the rows it filled itself, shared with its parent
/// through `Cache`; before a call, only the rows that differ from what the one
/// input buffer already holds are copied in, and after it only the new
/// positions are copied out. Expanding the children of one parent one after
/// the other copies nothing in.
///
/// Confined to the model queue, like `VimeLanguageModel`.
nonisolated final class VimeKVLanguageModel {
    struct Tolerance: Decodable, Equatable {
        let atol: Double
        let rtol: Double
        /// Whether `value` matches `reference` within the published tolerance.
        func accepts(_ value: Float, reference: Float) -> Bool {
            abs(Double(value) - Double(reference)) <= atol + rtol * abs(Double(reference))
        }
    }
    private struct Manifest: Decodable {
        struct KV: Decodable {
            let resource: String
            let compiled_files_sha256: [String: String]
            let cache_shape: [Int]
            let cache_dtype: String
            let alignment_tolerance: Tolerance
        }
        let format: String
        let architecture: String?
        let model_version: String?
        let special_ids: [String: Int]?
        let compute_units: String?
        let vocab_size: Int
        let context_length: Int
        let kv: KV?
    }

    static let layers = 9, heads = 6, headDimension = 64
    static let contextLength = VimeLanguageModel.contextLength
    static let manifestResource = VimeLanguageModel.Variant.zhV1.manifestResource
    /// Floats one position takes in the key cache (and again in the value cache).
    static let rowFloats = layers * heads * headDimension
    let vocabularySize = VimeLanguageModel.Variant.zhV1.vocabulary
    let tokenizer: VimeSentenceTokenizer
    let tolerance: Tolerance
    let modelVersion: String
    private let model: MLModel

    /// What one hypothesis has in the cache: its parent's positions, then
    /// `count` more from `start`. Immutable, so children share their parent.
    final class Cache {
        let parent: Cache?
        let start: Int
        let count: Int
        /// Keys then values for each position: 2 × `rowFloats` floats apiece.
        let rows: [Float]
        /// Unique among all caches, so buffers can tell whose rows they hold.
        let id: UInt64
        var length: Int { start + count }
        /// Model queue only.
        nonisolated(unsafe) private static var lastID: UInt64 = 0
        init(parent: Cache?, start: Int, count: Int, rows: [Float]) {
            Self.lastID += 1
            self.parent = parent; self.start = start; self.count = count; self.rows = rows; self.id = Self.lastID
        }
        /// The node that wrote each position, oldest first.
        func chain() -> [Cache] {
            var chain: [Cache] = []
            var node: Cache? = self
            while let current = node { chain.append(current); node = current.parent }
            return chain.reversed()
        }
        /// Bytes this hypothesis adds on top of its parent.
        var ownBytes: Int { rows.count * MemoryLayout<Float>.size }
    }

    /// The input cache. Positions past the hypothesis are still read by the
    /// package before it masks them, so they start zeroed: junk that happens
    /// to be NaN would reach every output.
    private(set) var keys: MLMultiArray
    private(set) var values: MLMultiArray
    private let position: MLMultiArray
    /// Preallocated outputs; nil once Core ML refused them.
    private var outputKeys: MLMultiArray?
    var usesOutputBackings: Bool { outputKeys != nil }
    private var outputValues: MLMultiArray?
    /// Which `Cache` wrote each position of the input buffers.
    private var bufferOwners = [UInt64](repeating: 0, count: VimeKVLanguageModel.contextLength)
    /// Rows copied into the input buffers so far (for tests and measurements).
    private(set) var copiedRows = 0
    private(set) var predictions = 0
    /// Seconds spent in Core ML and in copying rows, for measurement.
    private(set) var predictionSeconds = 0.0
    private(set) var copySeconds = 0.0

    init(bundle: Bundle = .main, tokenizer: VimeSentenceTokenizer? = nil, computeUnits: MLComputeUnits = .cpuOnly) throws {
        let variant = VimeLanguageModel.Variant.zhV1
        guard let manifestURL = bundle.url(forResource: Self.manifestResource, withExtension: "json"),
              let tokenizerURL = bundle.url(forResource: variant.tokenizerResource, withExtension: "model")
        else { throw VimeLanguageModel.Failure.resources }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard let kv = manifest.kv,
              manifest.format == variant.format, manifest.architecture == variant.architecture,
              manifest.compute_units == "CPU_ONLY",
              manifest.special_ids == ["pad": 0, "unk": 1, "bos": 2, "eos": 3],
              manifest.vocab_size == variant.vocabulary, manifest.context_length == Self.contextLength,
              let version = manifest.model_version, !version.isEmpty,
              kv.cache_dtype == "float32",
              kv.cache_shape == [Self.layers, 1, Self.heads, Self.contextLength, Self.headDimension],
              !kv.compiled_files_sha256.isEmpty,
              kv.compiled_files_sha256.keys.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") })
        else { throw VimeLanguageModel.Failure.integrity }
        guard let modelURL = bundle.url(forResource: kv.resource, withExtension: "mlmodelc")
        else { throw VimeLanguageModel.Failure.resources }
        modelVersion = version + "-kv"
        tolerance = kv.alignment_tolerance
        self.tokenizer = try tokenizer ?? VimeSentenceTokenizer(url: tokenizerURL, vocabulary: variant.vocabulary)
        // FP32 compute with INT8 weights, as the stateless package: CPU only.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let shape = kv.cache_shape.map { NSNumber(value: $0) }
        keys = try Self.zeroed(shape)
        values = try Self.zeroed(shape)
        position = try MLMultiArray(shape: [1], dataType: .int32)
        position.dataPointer.assumingMemoryBound(to: Int32.self)[0] = 0
        outputKeys = try? Self.zeroed(shape)
        outputValues = try? Self.zeroed(shape)
    }

    /// A float32 array of zeros; `MLMultiArray(shape:dataType:)` leaves its
    /// memory as it found it.
    static func zeroed(_ shape: [NSNumber]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        array.dataPointer.initializeMemory(as: Float.self, repeating: 0, count: array.count)
        return array
    }

    /// Runs `ids` after `cache` (nil: from the start) and returns the logits
    /// after the last of them, unnormalized, with the cache that covers them.
    /// `cache` stays valid, so one parent can be extended many times.
    func forward(_ ids: [Int32], after cache: Cache? = nil) throws -> (logits: [Float], cache: Cache) {
        let start = cache?.length ?? 0
        guard !ids.isEmpty, start + ids.count <= Self.contextLength,
              ids.allSatisfy({ $0 >= 0 && $0 < vocabularySize }) else { throw VimeLanguageModel.Failure.tensor }
        let loading = ProcessInfo.processInfo.systemUptime
        load(cache)
        copySeconds += ProcessInfo.processInfo.systemUptime - loading
        let input = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        let pointer = input.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
        for (index, id) in ids.enumerated() { pointer[index] = id }
        position.dataPointer.bindMemory(to: Int32.self, capacity: 1)[0] = Int32(start)
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": input, "position": position, "key_cache": keys, "value_cache": values])
        return try autoreleasepool {
            let predicting = ProcessInfo.processInfo.systemUptime
            let output = try predict(features)
            predictionSeconds += ProcessInfo.processInfo.systemUptime - predicting
            predictions += 1
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
                  let newKeys = output.featureValue(for: "new_key_cache")?.multiArrayValue,
                  let newValues = output.featureValue(for: "new_value_cache")?.multiArrayValue,
                  logits.dataType == .float32, newKeys.dataType == .float32, newValues.dataType == .float32,
                  logits.shape.map(\.intValue) == [1, ids.count, vocabularySize],
                  newKeys.shape == keys.shape, newValues.shape == values.shape
            else { throw VimeLanguageModel.Failure.tensor }
            let row = ids.count - 1
            let base = logits.dataPointer.assumingMemoryBound(to: Float.self).advanced(by: row * logits.strides[1].intValue)
            let stride = logits.strides[2].intValue
            let last = stride == 1 ? Array(UnsafeBufferPointer(start: base, count: vocabularySize))
                : (0..<vocabularySize).map { base[$0 * stride] }
            guard last.allSatisfy(\.isFinite) else { throw VimeLanguageModel.Failure.tensor }
            var rows = [Float](repeating: 0, count: ids.count * 2 * Self.rowFloats)
            rows.withUnsafeMutableBufferPointer { buffer in
                for offset in 0..<ids.count {
                    let target = buffer.baseAddress!.advanced(by: offset * 2 * Self.rowFloats)
                    Self.copyRow(from: newKeys, position: start + offset, to: target)
                    Self.copyRow(from: newValues, position: start + offset, to: target.advanced(by: Self.rowFloats))
                }
            }
            return (last, Cache(parent: cache, start: start, count: ids.count, rows: rows))
        }
    }

    /// Prediction into the preallocated outputs, or Core ML's own when it
    /// refuses them (they are then not offered again).
    private func predict(_ features: MLFeatureProvider) throws -> MLFeatureProvider {
        if let outputKeys, let outputValues {
            let options = MLPredictionOptions()
            options.outputBackings = ["new_key_cache": outputKeys, "new_value_cache": outputValues]
            if let output = try? model.prediction(from: features, options: options) { return output }
            self.outputKeys = nil; self.outputValues = nil
        }
        return try model.prediction(from: features)
    }

    /// Makes the input buffers hold `cache`'s positions, copying only the
    /// positions another hypothesis wrote there.
    private func load(_ cache: Cache?) {
        for segment in cache?.chain() ?? [] {
            for offset in 0..<segment.count where bufferOwners[segment.start + offset] != segment.id {
                segment.rows.withUnsafeBufferPointer { buffer in
                    let source = buffer.baseAddress!.advanced(by: offset * 2 * Self.rowFloats)
                    Self.copyRow(from: source, to: keys, position: segment.start + offset)
                    Self.copyRow(from: source.advanced(by: Self.rowFloats), to: values, position: segment.start + offset)
                }
                bufferOwners[segment.start + offset] = segment.id
                copiedRows += 1
            }
        }
    }

    /// One position of every layer and head, in (layer, head, dimension) order.
    static func copyRow(from array: MLMultiArray, position: Int, to target: UnsafeMutablePointer<Float>) {
        let strides = array.strides.map(\.intValue)
        let base = array.dataPointer.assumingMemoryBound(to: Float.self)
        for layer in 0..<layers {
            for head in 0..<heads {
                let source = base.advanced(by: layer * strides[0] + head * strides[2] + position * strides[3])
                let destination = target.advanced(by: (layer * heads + head) * headDimension)
                if strides[4] == 1 { destination.update(from: source, count: headDimension) }
                else { for d in 0..<headDimension { destination[d] = source[d * strides[4]] } }
            }
        }
    }

    static func copyRow(from source: UnsafePointer<Float>, to array: MLMultiArray, position: Int) {
        let strides = array.strides.map(\.intValue)
        let base = array.dataPointer.assumingMemoryBound(to: Float.self)
        for layer in 0..<layers {
            for head in 0..<heads {
                let destination = base.advanced(by: layer * strides[0] + head * strides[2] + position * strides[3])
                let row = source.advanced(by: (layer * heads + head) * headDimension)
                if strides[4] == 1 { destination.update(from: row, count: headDimension) }
                else { for d in 0..<headDimension { destination[d * strides[4]] = row[d] } }
            }
        }
    }
}
