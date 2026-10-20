import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

nonisolated enum CandidateWidthVariant: String, Codable, Sendable {
    case halfWidthKatakana, fullWidthAlphanumeric
    var annotation: String {
        switch self {
        case .halfWidthKatakana: String(localized: "半角片假名")
        case .fullWidthAlphanumeric: String(localized: "全角英数字")
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
    // Native data and reading inputs are immutable. Ranking repeatedly inspects
    // these values; join/normalize once rather than on every feature/gate read.
    let ruby: String
    let reading: String
    private let readingContainsLatin: Bool
    // Ranking, learning and dedupe read lexical/scriptType per comparison.
    // Their inputs (candidate, source) are immutable; scan the data once.
    private let lexicalEvidence: Bool
    private let candidateScript: CandidateScript
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
    var userPreferenceConfidence = 0.0
    // Keep the learned dictionary fallback strong. A model comparison can use
    // a smaller prior when the preference comes from a different context.
    var modelPreferenceScoreLimit = CandidatePreferenceMemory.Policy.maximumChoiceBonus
    var personalPreferenceProtectsOrder: Bool {
        userPreferenceConfidence >= 0.65 && modelPreferenceScoreLimit == CandidatePreferenceMemory.Policy.maximumChoiceBonus
    }
    var interpretationGain = 0.0
    var syntheticSurface: Bool { !candidate.isLearningTarget && !candidate.data.isEmpty
        && text != candidate.data.map(\.word).joined() }
    var text: String { displaySurface ?? candidate.text }
    var surface: String { text }
    var fullConsumption: Bool { remainingComposition.isEmpty }
    var exactReading: Bool { !queryReading.isEmpty && reading == (scopeReading.isEmpty ? queryReading : scopeReading)
        && !readingContainsLatin }
    var isPrediction: Bool { predictionStatus }
    var engineScore: Double { Double(candidate.value) }
    var composingCount: ComposingCount { candidate.composingCount }
    var scriptType: CandidateScript { displaySurface.map(CandidateScript.classify) ?? candidateScript }
    var lexical: Bool { widthVariant == nil && lexicalEvidence }
    var learningEligible: Bool { candidate.isLearningTarget && lexical && source != .scriptVariant && displaySurface == nil }
    // Native learning requires real segmentation; surface memory also accepts
    // recalled pairs and script choices without inventing dictionary elements.
    var preferenceScope: String? {
        if source == .scriptVariant || source == .orthographicVariant { return "style" }
        return learningEligible || source == .rememberedConversion ? "conversion" : nil
    }
    var hasLearningEvidence: Bool { candidate.data.contains { $0.metadata.contains(.isLearned) } }
    var presentation: CandidatePresentation {
        .init(text: text, source: source, consumedInputCount: consumedInputCount, correction: correction,
            detailAnnotation: widthVariant.map { fullConsumption ? $0.annotation : String(localized: "\($0.annotation) · 前段") }
                ?? (source == .specialConversion ? String(localized: "格式转换") : source == .emoji ? String(localized: "表情")
                : source == .userDictionary ? "用户词典"
                : source == .rememberedConversion ? String(localized: "个人记忆")
                : !fullConsumption ? String(localized: "\(Self.hiraganaAnnotation(reading)) · 前段") : nil))
    }

    /// Presentations are rebuilt for every published list. A plain scalar shift
    /// matches ICU's Katakana-Hiragana transform for ア…ヴ; rarer forms (ヵヶヷ-ヺ
    /// and iteration marks) map differently there, so they keep the ICU path.
    private static func hiraganaAnnotation(_ reading: String) -> String {
        if reading.unicodeScalars.contains(where: { (0x30F5...0x30FA).contains($0.value) || (0x30FD...0x30FE).contains($0.value) }) {
            return reading.applyingTransform(.hiraganaToKatakana, reverse: true) ?? reading
        }
        return String(String.UnicodeScalarView(reading.unicodeScalars.map {
            (0x30A1...0x30F4).contains($0.value) ? UnicodeScalar($0.value - 0x60)! : $0
        }))
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
        let ruby = candidate.data.map(\.ruby).joined()
        let reading = RomajiConverter.katakana(readingOverride ?? (ruby.isEmpty
            ? correction?.suggestedReading ?? queryReading : ruby)).precomposedStringWithCanonicalMapping
        self.ruby = ruby; self.reading = reading
        self.readingContainsLatin = reading.unicodeScalars.contains {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
        self.consumedReadingCount = max(0, queryReading.count - remainingComposition.convertTarget.count)
        self.engineFullConsumption = engineFullConsumption ?? remainingComposition.isEmpty
        self.lexicalEvidence = source != .specialConversion && source != .emoji
            && (source == .rememberedConversion || ((source == .conversion || source == .userDictionary || source == .orthographicVariant)
                ? JapaneseCandidateEngine.hasConversionEvidence(candidate)
                : JapaneseCandidateEngine.hasDictionaryEvidence(candidate)))
        self.candidateScript = CandidateScript.classify(candidate.text)
    }
}
