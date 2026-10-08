import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

nonisolated enum CandidateSource: String, Codable, Sendable {
    case conversion, prediction, scriptVariant, readingAlternative, typoCorrection
    // Compatibility for existing callers; diagnostics use the canonical source.
    static let kana = Self.scriptVariant
    static let correction = Self.typoCorrection
}

nonisolated enum CandidateScript: String, Codable, Sendable {
    case hiragana, katakana, mixedKana, japaneseMixed, latin, other
    static func classify(_ text: String) -> Self {
        let scalars = text.unicodeScalars
        let hira = scalars.contains { (0x3041...0x3096).contains($0.value) }
        let kata = scalars.contains { (0x30A1...0x30FA).contains($0.value) }
        let kanaOnly = scalars.allSatisfy { (0x3041...0x3096).contains($0.value)
            || (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC }
        if kanaOnly { return hira && kata ? .mixedKana : kata ? .katakana : .hiragana }
        if hira || kata { return .japaneseMixed }
        if scalars.allSatisfy({ $0.isASCII }) { return .latin }
        return .other
    }
}

nonisolated enum CorrectionKind: String, CaseIterable, Hashable, Sendable {
    case neighboringKey, missingLetter, extraLetter, transposition, phonetic
}

nonisolated struct CorrectionSuggestion: Equatable, Sendable {
    enum Unit: Equatable, Sendable { case romanInput, kanaReading }
    let originalReading: String
    let suggestedReading: String
    let correctedRomanInput: String?
    let kind: CorrectionKind
    let rangeOffset: Int
    let rangeLength: Int
    let rangeUnit: Unit
    let errorCost: Double
    var originalInput: String? = nil
    var lmScore: Double? = nil
    var convertedText: String? = nil
    var prominence: Double? = nil
    var method: String = "topologyOrPhonetic"
    var correctedInput: String { correctedRomanInput ?? suggestedReading }
    var correctedReading: String { suggestedReading }
}

/// UI equality includes all visible and accessible metadata, not just text.
nonisolated struct CandidatePresentation: Equatable, Sendable {
    let text: String
    let source: CandidateSource
    let consumedInputCount: Int
    let correction: CorrectionSuggestion?
    var annotation: String? { correction.map { $0.suggestedReading + " · 建议" } }
    var accessibilityLabel: String {
        guard let correction else { return "候选词：" + text }
        return "纠错候选：" + text + "，建议读音：" + correction.suggestedReading
            + "，原读音：" + correction.originalReading
    }
}

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
