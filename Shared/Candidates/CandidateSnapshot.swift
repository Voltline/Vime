import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Preserve the engine's original candidate, including ruby, data and consuming
/// count. The remainder is resolved against the exact request snapshot off-main.
nonisolated struct CandidateSnapshot: Sendable {
    let candidate: Candidate
    let revision: Int
    let source: CandidateSource
    let remainingComposition: ComposingText
    let originalInputCount: Int
    let consumedInputCount: Int
    let correction: CorrectionSuggestion?
    let queryReading: String
    let engineRank: Int
    let readingOverride: String?
    let engineFullConsumption: Bool
    var features = CandidateScoreFeatures()
    var userPreferenceScore = 0.0
    var interpretationGain = 0.0
    var syntheticSurface: Bool { !candidate.isLearningTarget && !candidate.data.isEmpty
        && text != candidate.data.map(\.word).joined() }
    var ruby: String { candidate.data.map(\.ruby).joined() }
    var reading: String { RomajiConverter.katakana(readingOverride ?? (ruby.isEmpty
        ? correction?.suggestedReading ?? queryReading : ruby)).precomposedStringWithCanonicalMapping }
    var text: String { candidate.text }
    var surface: String { text }
    var fullConsumption: Bool { remainingComposition.isEmpty }
    var exactReading: Bool { !queryReading.isEmpty && reading == queryReading
        && !reading.unicodeScalars.contains(where: { $0.isASCII }) }
    var isPrediction: Bool { source == .prediction }
    var engineScore: Double { Double(candidate.value) }
    var composingCount: ComposingCount { candidate.composingCount }
    var scriptType: CandidateScript { CandidateScript.classify(text) }
    var lexical: Bool { JapaneseCandidateEngine.hasDictionaryEvidence(candidate) }
    var learningEligible: Bool { candidate.isLearningTarget && lexical && source != .scriptVariant }
    var hasLearningEvidence: Bool { candidate.data.contains { $0.metadata.contains(.isLearned) } }
    var presentation: CandidatePresentation {
        .init(text: text, source: source, consumedInputCount: consumedInputCount, correction: correction)
    }

    init(candidate: Candidate, revision: Int, source: CandidateSource, remainingComposition: ComposingText,
         originalInputCount: Int, consumedInputCount: Int, correction: CorrectionSuggestion? = nil,
         queryReading: String = "", engineRank: Int = 0, engineFullConsumption: Bool? = nil, readingOverride: String? = nil) {
        self.candidate = candidate; self.revision = revision; self.source = source
        self.remainingComposition = remainingComposition; self.originalInputCount = originalInputCount
        self.consumedInputCount = consumedInputCount; self.correction = correction
        self.queryReading = queryReading; self.engineRank = engineRank; self.readingOverride = readingOverride
        self.engineFullConsumption = engineFullConsumption ?? remainingComposition.isEmpty
    }
}
