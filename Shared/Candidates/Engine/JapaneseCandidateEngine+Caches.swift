import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// Request-scoped and cross-request lookup structures used by the engine.
nonisolated extension JapaneseCandidateEngine {
    /// Native results for one exact input under the current dictionary and
    /// learning state. Typing at the end usually keeps the first clause intact,
    /// so its prefix query repeats across keystrokes.
    struct NativeResultCache {
        struct Key: Hashable {
            let pieces: [InputPiece]
            let styles: [InputStyle]
            init(_ text: ComposingText) { pieces = text.input.map(\.piece); styles = text.input.map(\.inputStyle) }
        }
        private var values: [Key: [Candidate]] = [:]
        private var order: [Key] = []
        let capacity: Int
        init(capacity: Int) { self.capacity = capacity }
        func results(for text: ComposingText) -> [Candidate]? { values[Key(text)] }
        mutating func insert(_ results: [Candidate], for text: ComposingText) {
            let key = Key(text)
            if values.updateValue(results, forKey: key) == nil {
                order.append(key)
                if order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
            }
        }
        mutating func removeAll() { values.removeAll(keepingCapacity: false); order.removeAll(keepingCapacity: false) }
    }

    /// `Array.firstIndex(of:)` for repeated lookups. Candidate is Equatable but
    /// not Hashable; bucket by text and keep the first fully equal element.
    struct FirstIndex {
        private var buckets: [String: [(candidate: Candidate, index: Int)]] = [:]
        init(_ candidates: [Candidate]) {
            for (index, candidate) in candidates.enumerated() {
                if buckets[candidate.text]?.contains(where: { $0.candidate == candidate }) == true { continue }
                buckets[candidate.text, default: []].append((candidate, index))
            }
        }
        subscript(_ candidate: Candidate) -> Int? {
            buckets[candidate.text]?.first { $0.candidate == candidate }?.index
        }
    }
}
