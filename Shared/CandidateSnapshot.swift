import KanaKanjiConverterModuleWithDefaultDictionary

nonisolated enum CandidateSource: Sendable { case conversion, prediction, kana }

/// Preserve the engine's original candidate, including ruby, data and consuming
/// count. The remainder is resolved against the exact request snapshot off-main.
nonisolated struct CandidateSnapshot: Sendable {
    let candidate: Candidate
    let revision: Int
    let source: CandidateSource
    let remainingComposition: ComposingText
    var text: String { candidate.text }
}
