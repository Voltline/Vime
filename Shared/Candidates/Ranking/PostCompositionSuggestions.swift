import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Store sendable fields instead of lowering a native prediction to String.
/// Reconstruct the upstream object only on the converter queue for learning.
nonisolated struct NativePostCompositionPrediction: Sendable {
    let base: Candidate
    let text: String
    let value: PValue
    let type: PostCompositionPredictionCandidate.PredictionType
    let isTerminal: Bool
    let expectedLeftContext: String
    var native: PostCompositionPredictionCandidate { .init(text: text, value: value, type: type) }
    var joined: Candidate { native.join(to: base) }
    var insertionText: String {
        if case .replacement(_, let replacement) = type { return replacement.map(\.word).joined() }
        return text
    }
    var replacedText: String {
        if case .replacement(let target, _) = type { return target.map(\.word).joined() }
        return ""
    }
    var isReplacement: Bool { if case .replacement = type { return true }; return false }
}

/// Scores are bounded evidence units. Engine lattice values and neural logP
/// cannot be added directly; use order within each generator, plus user evidence.
nonisolated enum PostCompositionSuggestionReranker {
    enum Policy {
        static let sourceEvidence = 3.0
        static let orderCost = 1.0
        static let maximumPresented = 10
    }
    static func merge(native: [NextWordSuggestion], neural: [NextWordSuggestion]) -> [NextWordSuggestion] {
        var pool: [String: NextWordSuggestion] = [:]
        for list in [native, neural] {
            for (rank, original) in list.enumerated() {
                var value = original
                value.score = Policy.sourceEvidence - Policy.orderCost * log1p(Double(rank)) + value.userScore
                // Same visible text can have different host operations. Never dedup
                // a replacement against an addition, or lose a native learning object.
                let key = value.text + "\0" + (value.nativePrediction?.replacedText ?? "")
                if let old = pool[key] {
                    if old.nativePrediction != nil {
                        var retained = old; retained.score = max(old.score, value.score); pool[key] = retained
                        continue
                    }
                    if value.nativePrediction == nil && old.score >= value.score { continue }
                    value.score = max(old.score, value.score)
                }
                pool[key] = value
            }
        }
        return Array(pool.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if ($0.nativePrediction != nil) != ($1.nativePrediction != nil) { return $0.nativePrediction != nil }
            if $0.text != $1.text { return $0.text < $1.text }
            return ($0.nativePrediction?.replacedText ?? "") < ($1.nativePrediction?.replacedText ?? "")
        }.prefix(Policy.maximumPresented))
    }
}
