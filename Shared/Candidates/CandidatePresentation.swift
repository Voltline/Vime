import Foundation

nonisolated enum CandidateSource: String, Codable, Sendable {
    case conversion, prediction, scriptVariant, readingAlternative, typoCorrection, userHistory, contextPrediction
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

/// Offsets refer to the original kana reading, even for disjoint changes.
nonisolated struct CorrectionSoundEdit: Equatable, Codable, Sendable {
    let offset: Int
    let original: String
    let replacement: String
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
    var soundEdits: [CorrectionSoundEdit] = []
    var editCount: Int { max(1, soundEdits.count) }
    var correctedInput: String { correctedRomanInput ?? suggestedReading }
    var correctedReading: String { suggestedReading }
}

/// UI equality includes all visible and accessible metadata, not just text.
nonisolated struct CandidatePresentation: Equatable, Sendable {
    let text: String
    let source: CandidateSource
    let consumedInputCount: Int
    let correction: CorrectionSuggestion?
    var selectionToken: CandidateSelectionToken? = nil
    var detailAnnotation: String? = nil
    var annotation: String? { detailAnnotation ?? correction.map { $0.suggestedReading + " · 建议" } }
    var accessibilityLabel: String {
        guard let correction else { return "候选词：" + text + (annotation.map { "，" + $0 } ?? "") }
        return "纠错候选：" + text + "，建议读音：" + correction.suggestedReading
            + "，原读音：" + correction.originalReading
    }
}
