import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

nonisolated enum CandidateWidthVariant: String, Codable, Sendable {
    case halfWidthKatakana, fullWidthAlphanumeric
    var annotation: String {
        switch self {
        case .halfWidthKatakana: "半角片假名"
        case .fullWidthAlphanumeric: "全角英数字"
        }
    }
}

/// Preserve the engine's original candidate, including ruby, data and consuming
/// count. The remainder is resolved against the exact request snapshot off-main.
nonisolated struct CandidateSnapshot: Sendable {
    let candidate: Candidate
    let revision: Int
    let source: CandidateSource
    let predictionStatus: Bool
    let remainingComposition: ComposingText
    let originalInputCount: Int
    let consumedInputCount: Int
    let correction: CorrectionSuggestion?
    let queryReading: String
    let engineRank: Int
    let readingOverride: String?
    let engineFullConsumption: Bool
    // Scope is expressed in kana units; the native count remains available for learning.
    var consumedReadingCount = 0
    var scopeReading = ""
    var explicitScope = false
    var displaySurface: String? = nil
    var widthVariant: CandidateWidthVariant? = nil
    var scopeFullConsumption: Bool { scopeReading.isEmpty ? fullConsumption : reading == scopeReading }
    var orthographyScore = 0.0
    var features = CandidateScoreFeatures()
    var userPreferenceScore = 0.0
    var interpretationGain = 0.0
    var syntheticSurface: Bool { !candidate.isLearningTarget && !candidate.data.isEmpty
        && text != candidate.data.map(\.word).joined() }
    var ruby: String { candidate.data.map(\.ruby).joined() }
    var reading: String { RomajiConverter.katakana(readingOverride ?? (ruby.isEmpty
        ? correction?.suggestedReading ?? queryReading : ruby)).precomposedStringWithCanonicalMapping }
    var text: String { displaySurface ?? candidate.text }
    var surface: String { text }
    var fullConsumption: Bool { remainingComposition.isEmpty }
    var exactReading: Bool { !queryReading.isEmpty && reading == (scopeReading.isEmpty ? queryReading : scopeReading)
        && !reading.unicodeScalars.contains(where: { $0.isASCII }) }
    var isPrediction: Bool { predictionStatus }
    var engineScore: Double { Double(candidate.value) }
    var composingCount: ComposingCount { candidate.composingCount }
    var scriptType: CandidateScript { CandidateScript.classify(text) }
    var lexical: Bool { widthVariant == nil && source != .specialConversion && source != .emoji && JapaneseCandidateEngine.hasDictionaryEvidence(candidate) }
    var learningEligible: Bool { candidate.isLearningTarget && lexical && source != .scriptVariant && displaySurface == nil }
    var hasLearningEvidence: Bool { candidate.data.contains { $0.metadata.contains(.isLearned) } }
    var presentation: CandidatePresentation {
        .init(text: text, source: source, consumedInputCount: consumedInputCount, correction: correction,
            detailAnnotation: widthVariant.map { $0.annotation + (fullConsumption ? "" : " · 前段") }
                ?? (source == .specialConversion ? "格式转换" : source == .emoji ? "表情"
                : source == .userDictionary ? "用户词典"
                : !fullConsumption ? (reading.applyingTransform(.hiraganaToKatakana, reverse: true) ?? reading) + " · 前段" : nil))
    }

    init(candidate: Candidate, revision: Int, source: CandidateSource, remainingComposition: ComposingText,
         originalInputCount: Int, consumedInputCount: Int, correction: CorrectionSuggestion? = nil,
         queryReading: String = "", engineRank: Int = 0, engineFullConsumption: Bool? = nil, readingOverride: String? = nil,
         predictionStatus: Bool? = nil) {
        self.candidate = candidate; self.revision = revision; self.source = source
        self.remainingComposition = remainingComposition; self.originalInputCount = originalInputCount
        self.consumedInputCount = consumedInputCount; self.correction = correction
        self.queryReading = queryReading; self.engineRank = engineRank; self.readingOverride = readingOverride
        self.predictionStatus = predictionStatus ?? (source == .prediction)
        self.consumedReadingCount = max(0, queryReading.count - remainingComposition.convertTarget.count)
        self.engineFullConsumption = engineFullConsumption ?? remainingComposition.isEmpty
    }
}
