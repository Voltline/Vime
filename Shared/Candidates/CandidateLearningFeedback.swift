import Foundation

/// Input-method feedback, independent of touch ownership and marked-text state.
nonisolated struct CandidateLearningFeedback: Sendable {
    enum Kind: String, Sendable { case explicitCandidate, conversionConfirmation, nextWord }
    enum Policy {
        static let retentionSeconds = 1.5
        static let anchorCharacters = 64
        static let maximumRecentEvents = 128
        static func weight(kind: Kind, rank: Int) -> Double {
            switch kind {
            case .explicitCandidate, .nextWord: return rank > 0 ? 1.0 : 0.7
            case .conversionConfirmation: return rank > 0 ? 0.7 : 0.35
            }
        }
    }
    let id: UUID
    let kind: Kind
    let rank: Int
    let context: String
    let selectedAt: Date
    var weight: Double { Policy.weight(kind: kind, rank: rank) }
}

/// Nil/redacted text is not a receipt. Identity and right context prevent a
/// matching left suffix in another field/caret position from accepting feedback.
nonisolated struct KeyboardLearningContext: Equatable, Sendable {
    let document: String
    let before: String?
    let after: String?
    var hasSelection = false
}

@MainActor
struct PendingCandidateFeedback {
    let event: CandidateLearningFeedback
    let anchor: KeyboardLearningContext
    let text: String
    var remaining: Int
    var followingText = ""
    var receiptVerified = false

    func matches(_ context: KeyboardLearningContext?) -> Bool {
        guard let context, context.document == anchor.document,
              context.after == anchor.after, !context.hasSelection,
              let before = context.before, let original = anchor.before else { return false }
        let expected = String((String(original.suffix(CandidateLearningFeedback.Policy.anchorCharacters))
            + String(text.prefix(remaining)) + followingText).suffix(CandidateLearningFeedback.Policy.anchorCharacters))
        // An empty anchor must match an actually empty prefix, not every string.
        return expected.isEmpty ? before.isEmpty : before.hasSuffix(expected)
    }
}
