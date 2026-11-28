import Foundation
import CoreML
import Accelerate
import os

/// The batched KV package (kvbatch-v4, VimeML's merged INT8 package, bundled
/// for both zh-v1 and zh-v2): checked by VimeML against its FP32 reference.
/// `ChineseLanguageModel` holds the one instance reranking, sentence correction
/// and generation share. One package holds four functions, each loaded as its
/// own `MLModel` the first time it is needed:
///
/// - `scored`: rows of new tokens, each on its own cache, after a prefix
///   every row shares, returning the log probabilities of a list of allowed
///   ids after each row (`allowed_logits − logsumexp`) and the new tokens'
///   keys and values. The prompt is one call with no prefix; its keys and
///   values then become the prefix.
/// - `score`: rows of tokens after the shared prefix and nothing else,
///   returning the log probability of each row's next token at every
///   position (`target_logprobs`). It keeps no keys or values, which is all
///   whole-sentence scoring needs.
/// - `logits`: the full logits after each row; only `logits(_:)` uses it,
///   to check the package against VimeML's references.
///
/// The prefix is passed once and read by every row, so no call copies it
/// into its rows. Keys and values are (9, B, 6, S, 64) for the rows' own
/// caches and (9, 1, 6, P, 64) for the prefix. Slots past what a row (or
/// the prefix) holds are still read before they are masked, so every buffer
/// starts zeroed: junk that happens to be NaN would spread to every output.
///
/// The rows' own buffers grow to the rows and slots calls need. Each slot
/// remembers which `Cache` wrote it, so a hypothesis placed in a row that
/// already holds its ancestors copies only the slots that differ. The
/// arrays handed to Core ML are views of the buffers with their strides.
///
/// Confined to the model queue, like `VimeLanguageModel`.
nonisolated final class VimeKVBatchLanguageModel {
    typealias Cache = VimeKVLanguageModel.Cache
    typealias Tolerance = VimeKVLanguageModel.Tolerance
    private struct Manifest: Decodable {
        struct Variant: Decodable {
            let name: String
            let kv: String
            let compute: String
        }
        struct FunctionSpec: Decodable {
            let batch_range: [Int]
        }
        struct Batch: Decodable {
            let resource: String
            let variant: Variant
            let compiled_files_sha256: [String: String]
            let functions: [String: FunctionSpec]
            let alignment_tolerance: Tolerance
        }
        let format: String
        let tokenizer_sha256: String
        let kv_batch_v4: Batch
    }

    enum Function: String, CaseIterable { case logits, scored, score, prefix }

    enum Variant: String, CaseIterable, Sendable {
        case v1
        case v2
        case jaV6

        var manifestResource: String {
            switch self {
            case .v1: "VimeLMManifestZhKVBatchV4-fp32kv"
            case .v2: "VimeLMManifestZhV2KVBatchV4-fp32kv"
            case .jaV6: "VimeLMManifestJaKVBatchV4-fp32kv"
            }
        }

        var manifestFormat: String {
            switch self {
            case .v1, .v2: "vime_ios_lm_zh_kv_batch_v4"
            case .jaV6: "vime_ios_lm_ja_kv_batch_v4"
            }
        }

        var releaseName: String {
            switch self {
            case .v1: "vimeml-tiny-zh-v1"
            case .v2: "vimeml-zh-v2-20m"
            case .jaV6: "vimeml-ja-v6-20m"
            }
        }
    }

    /// Keys and values shared by every row of a call, (9, 1, 6, P, 64) each,
    /// of which the first `length` slots are real.
    struct Prefix {
        let length: Int
        fileprivate let keys: MLMultiArray
        fileprivate let values: MLMultiArray
        var capacity: Int { keys.shape[3].intValue }
    }

    static let manifestResource = Variant.v1.manifestResource
    static let manifestFormat = "vime_ios_lm_zh_kv_batch_v4"
    /// Most allowed ids in one call.
    static let maximumAllowed = 1024
    static let layers = VimeKVLanguageModel.layers, heads = VimeKVLanguageModel.heads
    static let headDimension = VimeKVLanguageModel.headDimension
    static let rowFloats = VimeKVLanguageModel.rowFloats
    static let contextLength = VimeKVLanguageModel.contextLength
    /// About what each token of each row adds to a `score` call's peak
    /// footprint (VimeML measured 57–74 KiB for 16 rows of 16 to 64 tokens).
    static let bytesPerRowToken = 74 << 10
    /// Row tokens in one call when the footprint limit is unknown (16 × 16,
    /// what VimeML recommends per call; about 18.5 MiB at the peak).
    static let defaultRowTokens = 256
    let vocabularySize = ChineseLanguageModel.vocabulary
    /// The release and package, for diagnostics.
    let modelVersion: String
    let maximumBatch: Int
    let tolerance: Tolerance
    private let modelURL: URL
    private let computeUnits: MLComputeUnits
    private var models: [Function: MLModel] = [:]

    /// Row tokens one `score` call may take; nil: from the memory left.
    var rowTokenLimit: Int?

    /// Keys and values of the rows' own caches, (9, rows, 6, slots, 64) each.
    private var keys: UnsafeMutablePointer<Float>?
    private var values: UnsafeMutablePointer<Float>?
    private var rows = 0, slots = 0
    /// Which `Cache` wrote each own slot of each row (0: nobody).
    private var owners: [[UInt64]] = []
    /// The prefix built for the last root cache the steps ran after.
    private var current: (root: UInt64, prefix: Prefix)?
    private var emptyPrefix: Prefix?
    /// The tokens of the last prefix `prefix(_:)` built, and the prefix: the
    /// context before the caret rarely changes from key to key, and when it
    /// does it mostly grows, so the next prefix reuses what it shares with
    /// this one and runs only the tokens after.
    private var kept: (tokens: [Int32], prefix: Prefix)?
    /// Whether `prefix(_:)` reuses the last prefix; off only to measure.
    var reusesPrefixes = true
    /// Hints every function is loaded with; set before the first load.
    var optimizationHints = MLOptimizationHints()
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
    /// `prefix(_:)` and `scores(after:rows:)`: seconds, tokens the prefix
    /// calls ran, prefixes reused whole, and the row tokens `score` ran
    /// (padding included) against those that count.
    private(set) var prefixSeconds = 0.0
    private(set) var scoreSeconds = 0.0
    private(set) var prefixTokensRun = 0
    private(set) var prefixesReused = 0
    private(set) var scoreTokensRun = 0
    private(set) var scoreTokensUsed = 0
    /// The functions loaded so far.
    var loadedFunctions: Set<Function> { Set(models.keys) }

    init(bundle: Bundle = .main, variant: Variant = .v1, computeUnits: MLComputeUnits = .cpuOnly) throws {
        guard let manifestURL = bundle.url(forResource: variant.manifestResource, withExtension: "json")
        else { throw VimeLanguageModel.Failure.resources }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let batch = manifest.kv_batch_v4
        let batchedFunctions: [Function] = [.logits, .scored, .score]
        guard manifest.format == variant.manifestFormat,
              batch.variant.name == "fp32kv", batch.variant.kv == "fp32", batch.variant.compute == "fp32",
              Set(batch.functions.keys) == Set(Function.allCases.map(\.rawValue)),
              let scoreRange = batch.functions[Function.score.rawValue]?.batch_range,
              scoreRange.count == 2, scoreRange[0] == 1, scoreRange[1] >= 1,
              batchedFunctions.allSatisfy({ batch.functions[$0.rawValue]?.batch_range == scoreRange }),
              batch.functions[Function.prefix.rawValue]?.batch_range == [1, 1],
              !batch.compiled_files_sha256.isEmpty,
              batch.compiled_files_sha256.keys.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") })
        else { throw VimeLanguageModel.Failure.integrity }
        let name = (batch.resource as NSString).deletingPathExtension
        guard let modelURL = bundle.url(forResource: name, withExtension: "mlmodelc")
        else { throw VimeLanguageModel.Failure.resources }
        self.modelURL = modelURL
        modelVersion = "\(variant.releaseName)-kvbatch-v4-" + batch.variant.name
        self.computeUnits = computeUnits
        maximumBatch = scoreRange[1]
        tolerance = batch.alignment_tolerance
        allowedIDs = .allocate(capacity: Self.maximumAllowed)
        allowedLogits = .allocate(capacity: maximumBatch * Self.maximumAllowed)
    }

    deinit { keys?.deallocate(); values?.deallocate(); allowedIDs.deallocate(); allowedLogits.deallocate() }

    private func model(_ function: Function) throws -> MLModel {
        if let model = models[function] { return model }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        configuration.functionName = function.rawValue
        configuration.optimizationHints = optimizationHints
        let model = try autoreleasepool { try MLModel(contentsOf: modelURL, configuration: configuration) }
        models[function] = model
        return model
    }

    /// Loads `function` now rather than on its first call (about 600 ms on
    /// an iPhone 16 Pro Max), so a cold load holds no request.
    func preload(_ function: Function) throws { _ = try model(function) }

    /// Bytes the own-cache buffers take.
    var bufferBytes: Int { 2 * Self.layers * rows * Self.heads * slots * Self.headDimension * 4 }

    // MARK: Whole sequences (`score`)

    /// Row tokens one `score` call may take: `rowTokenLimit`, or what a
    /// quarter of the memory the process has left before its limit holds
    /// (2 to 24 MiB), or `defaultRowTokens` when that is unknown.
    func rowTokens() -> Int {
        if let rowTokenLimit { return max(1, rowTokenLimit) }
        let available = Int(os_proc_available_memory())
        guard available > 0 else { return Self.defaultRowTokens }
        let budget = min(24 << 20, max(2 << 20, available / 4))
        return max(1, min(maximumBatch * 16, budget / Self.bytesPerRowToken))
    }

    /// Extra trailing slots tolerated when reusing a longer cached prefix
    /// before slicing it down to keep masked attention and memory tight.
    private static let prefixSlack = 16

    /// `tokens` (BOS first) run once, as the prefix for `scores(after:rows:)`;
    /// nothing runs for none. What they share with the last prefix built is
    /// not run again: a prefix of it is reused as it is (the slots past its
    /// length are masked, or sliced down if many slots would go unused), and
    /// only the tokens after what they share run, after it.
    func prefix(_ tokens: [Int32]) throws -> Prefix {
        guard !tokens.isEmpty else { return try empty() }
        guard tokens.count < Self.contextLength, tokens.allSatisfy({ $0 >= 0 && Int($0) < vocabularySize })
        else { throw VimeLanguageModel.Failure.tensor }
        let started = ProcessInfo.processInfo.systemUptime
        defer { prefixSeconds += ProcessInfo.processInfo.systemUptime - started }
        var shared = 0
        if reusesPrefixes, let kept {
            let limit = min(kept.tokens.count, tokens.count)
            while shared < limit, kept.tokens[shared] == tokens[shared] { shared += 1 }
            if shared == tokens.count {
                prefixesReused += 1
                if kept.prefix.keys.shape[3].intValue <= shared + Self.prefixSlack {
                    return Prefix(length: shared, keys: kept.prefix.keys, values: kept.prefix.values)
                }
                let trimmed = try autoreleasepool {
                    Prefix(length: shared, keys: try Self.sliced(kept.prefix.keys, count: shared),
                           values: try Self.sliced(kept.prefix.values, count: shared))
                }
                self.kept = (tokens, trimmed)
                return trimmed
            }
        }
        let prefix: Prefix = try autoreleasepool {
            guard shared > 0, let kept else {
                let output = try prefixCall(tokens)
                prefixTokensRun += tokens.count
                return Prefix(length: tokens.count, keys: output.newKeys, values: output.newValues)
            }
            let base: Prefix
            if kept.prefix.keys.shape[3].intValue <= shared + Self.prefixSlack {
                base = Prefix(length: shared, keys: kept.prefix.keys, values: kept.prefix.values)
            } else {
                base = Prefix(length: shared, keys: try Self.sliced(kept.prefix.keys, count: shared),
                              values: try Self.sliced(kept.prefix.values, count: shared))
            }
            let rest = Array(tokens[shared...])
            let output = try prefixCall(rest, after: base)
            prefixTokensRun += rest.count
            return Prefix(length: tokens.count, keys: try Self.joined(base.keys, shared, output.newKeys),
                          values: try Self.joined(base.values, shared, output.newValues))
        }
        if reusesPrefixes { kept = (tokens, prefix) }
        return prefix
    }

    /// The first `count` slots of `source`, (9, 1, 6, ·, 64).
    private static func sliced(_ source: MLMultiArray, count: Int) throws -> MLMultiArray {
        try copied([(source, count)], total: count)
    }

    /// The first `count` slots of `head` then every slot of `tail`, both
    /// (9, 1, 6, ·, 64): one prefix array.
    private static func joined(_ head: MLMultiArray, _ count: Int, _ tail: MLMultiArray) throws -> MLMultiArray {
        let added = tail.shape[3].intValue
        return try copied([(head, count), (tail, added)], total: count + added)
    }

    /// Concatenates the first `slots` along axis 3 from each (9, 1, 6, ·, 64) part.
    private static func copied(_ parts: [(MLMultiArray, Int)], total: Int) throws -> MLMultiArray {
        let shape = [layers, 1, heads, total, headDimension].map { NSNumber(value: $0) }
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        let target = array.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = array.strides.map(\.intValue)
        var from = 0
        for (source, slots) in parts {
            let sourceStrides = source.strides.map(\.intValue)
            source.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                let base = buffer.baseAddress!
                for layer in 0..<layers {
                    for head in 0..<heads {
                        let input = base.advanced(by: layer * sourceStrides[0] + head * sourceStrides[2])
                        let output = target.advanced(by: layer * strides[0] + head * strides[2] + from * strides[3])
                        if sourceStrides[4] == 1, sourceStrides[3] == headDimension, strides[3] == headDimension {
                            output.update(from: input, count: slots * headDimension)
                        } else {
                            for slot in 0..<slots {
                                for d in 0..<headDimension {
                                    output[slot * strides[3] + d * strides[4]] = input[slot * sourceStrides[3] + d * sourceStrides[4]]
                                }
                            }
                        }
                    }
                }
            }
            from += slots
        }
        return array
    }

    /// Forgets the prefix kept for the next call (memory pressure, or to measure).
    func forgetPrefix() { kept = nil }

    /// Releases transient KV/prefix/per-batch buffers while keeping loaded
    /// `MLModel` instances warm. Reclaims up to ~54 MiB after generation or on
    /// keyboard hide / memory pressure.
    func releaseTransientBuffers() {
        kept = nil
        current = nil
        keys?.deallocate(); keys = nil
        values?.deallocate(); values = nil
        rows = 0; slots = 0
        owners.removeAll(keepingCapacity: false)
        arrays.removeAll(keepingCapacity: false)
    }

    /// The log probability of every token after the first of each row
    /// (two tokens or more), after `prefix` and the tokens before it in the
    /// row. Rows go longest first, as many to a call as `rowTokens()` lets
    /// through (one at least, `maximumBatch` at most). `cancelled` is asked
    /// before each call.
    func scores(after prefix: Prefix, rows: [[Int32]], cancelled: () -> Bool = { false }) throws -> [[Float]] {
        guard !rows.isEmpty,
              rows.allSatisfy({ $0.count >= 2 && prefix.length + $0.count - 1 <= Self.contextLength }),
              rows.allSatisfy({ $0.allSatisfy { $0 >= 0 && Int($0) < vocabularySize } })
        else { throw VimeLanguageModel.Failure.tensor }
        let started = ProcessInfo.processInfo.systemUptime
        defer { scoreSeconds += ProcessInfo.processInfo.systemUptime - started }
        let order = rows.indices.sorted { rows[$0].count > rows[$1].count }
        let limit = rowTokens()
        var result = [[Float]](repeating: [], count: rows.count)
        var first = 0
        while first < order.count {
            guard !cancelled() else { throw VimeLanguageModel.Failure.cancelled }
            let length = rows[order[first]].count - 1
            let count = max(1, min(maximumBatch, order.count - first, limit / length))
            let slice = order[first..<first + count].map { rows[$0] }
            let scores = try autoreleasepool { try scoreCall(slice, length: length, prefix: prefix) }
            scoreTokensRun += count * length
            scoreTokensUsed += slice.reduce(0) { $0 + $1.count - 1 }
            for (offset, values) in scores.enumerated() { result[order[first + offset]] = values }
            first += count
        }
        return result
    }

    private func scoreCall(_ rows: [[Int32]], length: Int, prefix: Prefix) throws -> [[Float]] {
        let count = rows.count
        let shape = [NSNumber(value: count), NSNumber(value: length)]
        let ids = try MLMultiArray(shape: shape, dataType: .int32)
        let targets = try MLMultiArray(shape: shape, dataType: .int32)
        let idPointer = ids.dataPointer.assumingMemoryBound(to: Int32.self)
        let targetPointer = targets.dataPointer.assumingMemoryBound(to: Int32.self)
        let idRowStride = ids.strides[0].intValue, idColStride = ids.strides[1].intValue
        let targetRowStride = targets.strides[0].intValue, targetColStride = targets.strides[1].intValue
        for (row, tokens) in rows.enumerated() {
            for column in 0..<length {
                // Right padding: any id, ignored.
                idPointer[row * idRowStride + column * idColStride] = column < tokens.count - 1 ? tokens[column] : 0
                targetPointer[row * targetRowStride + column * targetColStride] = column < tokens.count - 1 ? tokens[column + 1] : 0
            }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": ids, "targets": targets, "prefix_length": try Self.scalar(prefix.length),
            "prefix_key": prefix.keys, "prefix_value": prefix.values])
        let output = try model(.score).prediction(from: features)
        predictions += 1; rowsPredicted += count
        guard let logProbabilities = output.featureValue(for: "target_logprobs")?.multiArrayValue,
              logProbabilities.dataType == .float32, logProbabilities.shape.map(\.intValue) == [count, length]
        else { throw VimeLanguageModel.Failure.tensor }
        let strides = logProbabilities.strides.map(\.intValue)
        let scores: [[Float]] = logProbabilities.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            rows.enumerated().map { row, tokens in
                (0..<tokens.count - 1).map { buffer[row * strides[0] + $0 * strides[1]] }
            }
        }
        guard scores.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { throw VimeLanguageModel.Failure.tensor }
        return scores
    }

    // MARK: Full logits (`logits`)

    /// The logits after `tokens` (BOS first), unnormalized, with no prefix
    /// and no own cache: the logits of its last position.
    func logits(_ tokens: [Int32]) throws -> [Float] {
        guard !tokens.isEmpty, tokens.count <= Self.contextLength,
              tokens.allSatisfy({ $0 >= 0 && Int($0) < vocabularySize })
        else { throw VimeLanguageModel.Failure.tensor }
        return try autoreleasepool {
            let ids = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
            let idPointer = ids.dataPointer.assumingMemoryBound(to: Int32.self)
            let idStride = ids.strides[1].intValue
            for (index, token) in tokens.enumerated() { idPointer[index * idStride] = token }
            let none = try empty()
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": ids, "position": try Self.scalar(0), "key_cache": none.keys, "value_cache": none.values,
                "prefix_length": try Self.scalar(0), "prefix_key": none.keys, "prefix_value": none.values])
            let output = try model(.logits).prediction(from: features)
            predictions += 1; rowsPredicted += 1
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue, logits.dataType == .float32,
                  logits.shape.map(\.intValue) == [1, vocabularySize]
            else { throw VimeLanguageModel.Failure.tensor }
            let stride = logits.strides[1].intValue
            return logits.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                (0..<vocabularySize).map { buffer[$0 * stride] }
            }
        }
    }

    // MARK: Steps (`scored`)

    /// Runs one token after each cache (nil: at the start) and returns the
    /// log probabilities of `allowed` (at most `maximumAllowed` ids) after
    /// it, with the cache that covers it. Every cache must come from the same
    /// prompt (or all be nil); the caches stay valid.
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
    /// `allowed` after it, and its cache, whose keys and values are then the
    /// prefix of every step after it.
    func prompt(_ tokens: [Int32], allowed: [Int32]) throws -> (logProbabilities: [Float], cache: Cache) {
        guard !tokens.isEmpty, tokens.count <= Self.contextLength,
              tokens.allSatisfy({ $0 >= 0 && Int($0) < vocabularySize })
        else { throw VimeLanguageModel.Failure.tensor }
        try checked(allowed)
        return try autoreleasepool {
            let output = try promptCall(tokens, allowed: allowed)
            let count = tokens.count
            let rows = [Float](unsafeUninitializedCapacity: 2 * Self.rowFloats * count) { buffer, initialized in
                for slot in 0..<count {
                    let target = buffer.baseAddress!.advanced(by: slot * 2 * Self.rowFloats)
                    Self.copyNew(output.newKeys, row: 0, slot: slot, to: target)
                    Self.copyNew(output.newValues, row: 0, slot: slot, to: target.advanced(by: Self.rowFloats))
                }
                initialized = 2 * Self.rowFloats * count
            }
            let cache = Cache(parent: nil, start: 0, count: count, rows: rows)
            current = (cache.id, Prefix(length: count, keys: output.newKeys, values: output.newValues))
            return (output.logProbabilities, cache)
        }
    }

    /// Runs `tokens` after a shared `base` prefix (built via `prefix(_:)`):
    /// returns the log probabilities of `allowed` after `base + tokens`, and
    /// sets the combined KV as the active prefix for subsequent `scores` steps.
    func prompt(_ tokens: [Int32], after base: Prefix, allowed: [Int32]) throws -> (logProbabilities: [Float], cache: Cache) {
        guard base.length > 0 else { return try prompt(tokens, allowed: allowed) }
        guard !tokens.isEmpty, base.length + tokens.count <= Self.contextLength,
              tokens.allSatisfy({ $0 >= 0 && Int($0) < vocabularySize })
        else { throw VimeLanguageModel.Failure.tensor }
        try checked(allowed)
        return try autoreleasepool {
            let output = try promptCall(tokens, allowed: allowed, after: base)
            let total = base.length + tokens.count
            let fullKeys = try Self.joined(base.keys, base.length, output.newKeys)
            let fullValues = try Self.joined(base.values, base.length, output.newValues)
            let cache = Cache(parent: nil, start: 0, count: total, rows: [])
            current = (cache.id, Prefix(length: total, keys: fullKeys, values: fullValues))
            return (output.logProbabilities, cache)
        }
    }

    /// `tokens` after `base` (nothing by default) through the head-free `prefix`
    /// function: returns only their keys and values, (9, 1, 6, T, 64) each.
    private func prefixCall(_ tokens: [Int32], after base: Prefix? = nil) throws
        -> (newKeys: MLMultiArray, newValues: MLMultiArray) {
        var clock = ProcessInfo.processInfo.systemUptime
        func lap(_ total: inout Double) {
            let now = ProcessInfo.processInfo.systemUptime; total += now - clock; clock = now
        }
        let count = tokens.count
        let ids = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
        let idPointer = ids.dataPointer.assumingMemoryBound(to: Int32.self)
        let idStride = ids.strides[1].intValue
        for (index, token) in tokens.enumerated() { idPointer[index * idStride] = token }
        let prefix = try base ?? empty()
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": ids, "prefix_length": try Self.scalar(prefix.length),
            "prefix_key": prefix.keys, "prefix_value": prefix.values])
        lap(&inputSeconds)
        let output = try model(.prefix).prediction(from: features)
        lap(&predictionSeconds)
        predictions += 1; rowsPredicted += 1
        guard let newKeys = output.featureValue(for: "new_key")?.multiArrayValue,
              let newValues = output.featureValue(for: "new_value")?.multiArrayValue,
              newKeys.dataType == .float32, newValues.dataType == .float32,
              newKeys.shape.map(\.intValue) == [Self.layers, 1, Self.heads, count, Self.headDimension],
              newValues.shape == newKeys.shape
        else { throw VimeLanguageModel.Failure.tensor }
        lap(&outputSeconds)
        return (newKeys, newValues)
    }

    /// `tokens` after `base` (nothing by default): the log probabilities of
    /// `allowed` after them, and their keys and values, (9, 1, 6, T, 64) each.
    private func promptCall(_ tokens: [Int32], allowed: [Int32], after base: Prefix? = nil) throws
        -> (logProbabilities: [Float], newKeys: MLMultiArray, newValues: MLMultiArray) {
        var clock = ProcessInfo.processInfo.systemUptime
        func lap(_ total: inout Double) {
            let now = ProcessInfo.processInfo.systemUptime; total += now - clock; clock = now
        }
        let count = tokens.count
        let ids = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
        let idPointer = ids.dataPointer.assumingMemoryBound(to: Int32.self)
        let idStride = ids.strides[1].intValue
        for (index, token) in tokens.enumerated() { idPointer[index * idStride] = token }
        // No own cache (and no prefix unless `base`): one slot of each, ignored, but zeroed.
        let none = try empty()
        let prefix = base ?? none
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": ids, "position": try Self.scalar(0), "key_cache": none.keys, "value_cache": none.values,
            "prefix_length": try Self.scalar(prefix.length), "prefix_key": prefix.keys, "prefix_value": prefix.values,
            "allowed": try allowedView(allowed)])
        lap(&inputSeconds)
        let output = try model(.scored).prediction(from: features)
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
        return (scores, newKeys, newValues)
    }

    /// One zeroed slot (9, 1, 6, 1, 64), for an empty prefix or own cache.
    private func empty() throws -> Prefix {
        if let emptyPrefix { return emptyPrefix }
        let shape: [NSNumber] = [NSNumber(value: Self.layers), 1, NSNumber(value: Self.heads), 1,
                                 NSNumber(value: Self.headDimension)]
        let prefix = Prefix(length: 0, keys: try VimeKVLanguageModel.zeroed(shape), values: try VimeKVLanguageModel.zeroed(shape))
        emptyPrefix = prefix
        return prefix
    }

    /// The prefix of the steps after `root`: kept from its prompt, or
    /// rebuilt from its rows.
    private func prefix(for root: Cache?) throws -> Prefix {
        guard let root else { return try empty() }
        if let current, current.root == root.id { return current.prefix }
        guard root.rows.count == 2 * Self.rowFloats * root.count else { throw VimeLanguageModel.Failure.tensor }
        let shape = [Self.layers, 1, Self.heads, root.count, Self.headDimension].map { NSNumber(value: $0) }
        let keys = try VimeKVLanguageModel.zeroed(shape), values = try VimeKVLanguageModel.zeroed(shape)
        for (array, half) in [(keys, 0), (values, Self.rowFloats)] {
            let strides = array.strides.map(\.intValue)
            let step = strides[4]
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            root.rows.withUnsafeBufferPointer { source in
                for slot in 0..<root.count {
                    for layer in 0..<Self.layers {
                        for head in 0..<Self.heads {
                            let target = pointer.advanced(by: layer * strides[0] + head * strides[2] + slot * strides[3])
                            let from = source.baseAddress!.advanced(by: slot * 2 * Self.rowFloats + half
                                                                    + (layer * Self.heads + head) * Self.headDimension)
                            if step == 1 { target.update(from: from, count: Self.headDimension) }
                            else { for d in 0..<Self.headDimension { target[d * step] = from[d] } }
                        }
                    }
                }
            }
        }
        let prefix = Prefix(length: root.count, keys: keys, values: values)
        current = (root.id, prefix)
        return prefix
    }

    private static func scalar(_ value: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1], dataType: .int32)
        array.dataPointer.assumingMemoryBound(to: Int32.self)[0] = Int32(value)
        return array
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
        // The prompt every cache grows from is the prefix; the rest is each row's own.
        let chains = items.map { $0.cache?.chain() ?? [] }
        let root = chains[0].first
        guard chains.allSatisfy({ $0.first === root }) else { throw VimeLanguageModel.Failure.tensor }
        let base = root?.count ?? 0
        let prefix = try prefix(for: root)
        let own = items.map { ($0.cache?.length ?? 0) - base }
        let needed = own.max()! + 1
        if needed > slots || count > rows {
            // Slots in steps of 8, with room to grow; rows as the calls need them.
            let newSlots = needed > slots ? min(Self.contextLength, max((needed + 7) / 8 * 8, slots + slots / 2)) : slots
            reserve(rows: max(rows, count), slots: newSlots)
        }
        var clock = ProcessInfo.processInfo.systemUptime
        func lap(_ total: inout Double) {
            let now = ProcessInfo.processInfo.systemUptime; total += now - clock; clock = now
        }
        let placed = assign(chains.map { Array($0.dropFirst()) }, base: base)
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
        let idStride = set.ids.strides[0].intValue
        let positionStride = set.positions.strides[0].intValue
        for (item, row) in placed.enumerated() {
            idPointer[row * idStride] = items[item].token
            positionPointer[row * positionStride] = Int32(own[item])
        }
        // The package reads S = the longest own cache, at least 1; the
        // buffers keep one slot more for the new token.
        let viewSlots = max(needed - 1, 1)
        let shape = [Self.layers, count, Self.heads, viewSlots, Self.headDimension].map { NSNumber(value: $0) }
        let strides = [rows * Self.heads * slots * Self.headDimension, Self.heads * slots * Self.headDimension,
                       slots * Self.headDimension, Self.headDimension, 1].map { NSNumber(value: $0) }

        return try autoreleasepool {
            let keyView = try MLMultiArray(dataPointer: keys!, shape: shape, dataType: .float32, strides: strides)
            let valueView = try MLMultiArray(dataPointer: values!, shape: shape, dataType: .float32, strides: strides)
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": set.ids, "position": set.positions, "key_cache": keyView, "value_cache": valueView,
                "prefix_length": try Self.scalar(prefix.length), "prefix_key": prefix.keys, "prefix_value": prefix.values,
                "allowed": try allowedView(allowed)])
            lap(&inputSeconds)
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
                let rowFloats = [Float](unsafeUninitializedCapacity: 2 * Self.rowFloats) { buffer, initialized in
                    Self.copyNew(newKeys, row: row, slot: 0, to: buffer.baseAddress!)
                    Self.copyNew(newValues, row: row, slot: 0, to: buffer.baseAddress!.advanced(by: Self.rowFloats))
                    initialized = 2 * Self.rowFloats
                }
                let cache = Cache(parent: item.cache, start: item.cache?.length ?? 0, count: 1, rows: rowFloats)
                // The new slot is in place for this row's children.
                rowFloats.withUnsafeBufferPointer { write($0.baseAddress!, row: row, slot: own[index]) }
                owners[row][own[index]] = cache.id
                results.append((rowScores[index], cache))
            }
            lap(&writeSeconds)
            return results
        }
    }

    /// Prediction into the preallocated outputs, or Core ML's own when it
    /// refuses them (they are then not offered again for that batch size).
    private func predict(_ features: MLFeatureProvider, count: Int, allowed: Int) throws -> MLFeatureProvider {
        let model = try model(.scored)
        if allowedBackings, let sums = arrays[count]?.sums, let newKeys = arrays[count]?.newKeys,
           let newValues = arrays[count]?.newValues {
            let options = MLPredictionOptions()
            let scores = try MLMultiArray(dataPointer: allowedLogits, shape: [NSNumber(value: count), NSNumber(value: allowed)],
                                          dataType: .float32, strides: [NSNumber(value: allowed), 1])
            options.outputBackings = ["logsumexp": sums, "allowed_logits": scores, "new_key": newKeys, "new_value": newValues]
            if let output = try? model.prediction(from: features, options: options) { return output }
            allowedBackings = false
            for key in arrays.keys {
                arrays[key]?.sums = nil
                arrays[key]?.newKeys = nil
                arrays[key]?.newValues = nil
            }
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

    /// Picks a row among the first `chains.count` for each chain of own
    /// caches (positions from `base` on), preferring rows that already hold
    /// the most of it, and copies in the slots that differ. Returns the row
    /// of each chain.
    private func assign(_ chains: [[Cache]], base: Int) -> [Int] {
        let count = chains.count
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
                for offset in 0..<node.count where owners[row][node.start - base + offset] != node.id {
                    node.rows.withUnsafeBufferPointer {
                        write($0.baseAddress!.advanced(by: offset * 2 * Self.rowFloats), row: row,
                              slot: node.start - base + offset)
                    }
                    owners[row][node.start - base + offset] = node.id
                    copiedSlots += 1
                }
            }
        }
        return placed
    }

    /// One own slot of one row: keys then values, (layer, head, dimension) each.
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
