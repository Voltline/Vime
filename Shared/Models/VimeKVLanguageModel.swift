import Foundation
import CoreML

/// What the zh-v1 KV packages share: the cache layout, the hypothesis
/// caches the incremental search keeps, and the published tolerance. The
/// kvbatch-v3 package (`VimeKVBatchLanguageModel`) is the only one bundled.
nonisolated enum VimeKVLanguageModel {
    struct Tolerance: Decodable, Equatable {
        let atol: Double
        let rtol: Double
        /// Whether `value` matches `reference` within the published tolerance.
        func accepts(_ value: Float, reference: Float) -> Bool {
            abs(Double(value) - Double(reference)) <= atol + rtol * abs(Double(reference))
        }
    }

    static let layers = 9, heads = 6, headDimension = 64
    static let contextLength = VimeLanguageModel.contextLength
    /// Floats one position takes in the key cache (and again in the value cache).
    static let rowFloats = layers * heads * headDimension

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

    /// A float32 array of zeros; `MLMultiArray(shape:dataType:)` leaves its
    /// memory as it found it. Slots past what a cache holds are still read
    /// before they are masked, and junk that happens to be NaN would reach
    /// every output.
    static func zeroed(_ shape: [NSNumber]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        array.dataPointer.initializeMemory(as: Float.self, repeating: 0, count: array.count)
        return array
    }
}
