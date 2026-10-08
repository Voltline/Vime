import Foundation

/// All presentation policy is expressed here, in score units. Engine order is
/// evidence too: raw values of sentence, prediction and fallback differ in scale.
nonisolated struct CandidateRankingWeights: Sendable {
    var engineOrder = 2.0
    var engineValue = 1.5
    var exactLexical = 8.0
    var fullConsumption = 3.0
    var predictionOverrun = 4.0
    var continuity = 0.8 // Bounded bonus; cannot overcome an incompatible reading.
    var mixedKana = 4.0
    var scriptAvailability = 2.0
    var selectedScript = 10.0 // Explicit ア mode is a user preference, not a slot.
    var typoCost = 2.0
    var alternateReadingCost = 2.0
    var interpretationEvidenceLimit = 8.0
    var correctionEvidence = 4.0 // Only applied after dictionary gain admission.
    var correctionGainLimit = 4.0
    var unresolvedScriptPenalty = 3.0
    var syntheticSurfacePenalty = 0.5
    var context = 0.25
    var contextLimit = 2.5
}

/// Admission is independent of presentation: a correction needs a meaningful
/// dictionary gain after paying for the edit. Shared by classic/topology/LM.
nonisolated enum CandidateCorrectionPolicy {
    static let channelWeight = 3.6
    static let minimumQuality = -5.0
    static let admissionMargin = 2.0
    static let minimumProminence: Float = 0.1
    static let maximumCachedReadings = 96
}

nonisolated struct CandidateScoreFeatures: Codable, Sendable {
    var engine = 0.0
    var exactReading = 0.0
    var fullConsumption = 0.0
    var script = 0.0
    var predictionOverrun = 0.0
    var interpretationEvidence = 0.0
    var continuity = 0.0
    // Learning is already in the engine value/order; never count it twice.
    var userLearning = 0.0
    var context = 0.0
    var typoCost = 0.0
    var total: Double { engine + exactReading + fullConsumption + script
        + predictionOverrun + interpretationEvidence + continuity + userLearning + context + typoCost }
}

nonisolated struct CandidateContinuity: Sendable {
    let surface: String
    let reading: String
    let input: String
}

nonisolated struct CandidateReranker {
    var weights = CandidateRankingWeights()

    func rank(_ pool: [CandidateSnapshot], input: String, katakana: Bool,
              previous: CandidateContinuity?, context: (CandidateSnapshot) -> Double = { _ in 0 }) -> [CandidateSnapshot] {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.candidateReranking, since: started) }
        let standardKatakana = Dictionary(grouping: pool.filter { $0.lexical && $0.scriptType == .katakana }, by: \.text)
            .mapValues { Set($0.map(\.reading)) }
        let scored = pool.filter { !$0.text.isEmpty }.map { original -> CandidateSnapshot in
            var value = original
            var f = CandidateScoreFeatures()
            // Saturate normalized lattice value so presentation-only fixed scores
            // cannot dominate a real sentence; retain upstream order as evidence.
            let normalized = value.engineScore / Double(max(3, value.reading.count))
            f.engine = -weights.engineOrder * log1p(Double(value.engineRank))
                + weights.engineValue * atan(normalized)
            if value.source == .scriptVariant {
                f.engine = 0
                f.script = weights.scriptAvailability
                if value.queryReading.unicodeScalars.contains(where: { $0.isASCII }) {
                    f.script -= weights.unresolvedScriptPenalty
                }
            }
            let interpretedExact = value.source == .readingAlternative && value.lexical && value.fullConsumption
            if value.fullConsumption && value.lexical && (value.exactReading || interpretedExact) {
                f.exactReading = weights.exactLexical
            }
            if value.fullConsumption { f.fullConsumption = weights.fullConsumption }
            if value.source == .readingAlternative {
                f.typoCost = -weights.alternateReadingCost
                f.interpretationEvidence = max(-weights.interpretationEvidenceLimit,
                    min(weights.interpretationEvidenceLimit, value.interpretationGain))
            }
            if let correction = value.correction {
                f.typoCost = -weights.typoCost * correction.errorCost
                f.interpretationEvidence = weights.correctionEvidence
                    + min(weights.correctionGainLimit, max(0, value.interpretationGain))
                if value.syntheticSurface { f.script -= weights.syntheticSurfacePenalty }
            }
            // Completed reading extensions differ from unfinished Roman prediction.
            if value.isPrediction && !value.queryReading.unicodeScalars.contains(where: { $0.isASCII })
                && !value.exactReading { f.predictionOverrun = -weights.predictionOverrun }
            if value.scriptType == .mixedKana,
               standardKatakana[RomajiConverter.katakana(value.text)]?.contains(value.reading) == true {
                // Only kana-only homographs with an attested all-katakana spelling.
                // Kanji + hiragana / katakana + kanji never receives this penalty.
                f.script -= weights.mixedKana
            }
            if katakana && value.fullConsumption && value.text == value.queryReading {
                f.script += weights.selectedScript
            }
            if let previous, previous.surface == value.text,
               input.count > previous.input.count, input.hasPrefix(previous.input),
               previous.reading == value.reading,
               value.lexical && (value.exactReading || value.isPrediction) {
                f.continuity = weights.continuity
            }
            f.context = max(-weights.contextLimit, min(weights.contextLimit, context(value) * weights.context))
            value.features = f
            return value
        }
        // Deduplicate before sorting: preserve real engine objects over generated
        // kana with equal surface and consumption. Corrections cannot erase exact
        // literal evidence. Partial/full selections remain distinct.
        var unique: [CandidateIdentity: CandidateSnapshot] = [:]
        for value in scored {
            let key = CandidateIdentity(value)
            guard let old = unique[key] else { unique[key] = value; continue }
            let quality: (CandidateSnapshot) -> Int = { candidate in
                (candidate.lexical ? 8 : 0) + (candidate.exactReading ? 2 : 0)
                    + (candidate.source == .scriptVariant ? 2 : 1)
            }
            if quality(value) > quality(old) || (quality(value) == quality(old) && value.features.total > old.features.total) {
                unique[key] = value
            }
        }
        return unique.values.sorted {
            if $0.features.total != $1.features.total { return $0.features.total > $1.features.total }
            if $0.engineRank != $1.engineRank { return $0.engineRank < $1.engineRank }
            if $0.text != $1.text { return $0.text < $1.text }
            if $0.consumedInputCount != $1.consumedInputCount { return $0.consumedInputCount > $1.consumedInputCount }
            return $0.source.rawValue < $1.source.rawValue
        }
    }
}

nonisolated struct CandidateIdentity: Hashable {
    let text: String
    let consumedInputCount: Int
    init(_ value: CandidateSnapshot) { text = value.text.precomposedStringWithCanonicalMapping; consumedInputCount = value.consumedInputCount }
}

/// Opt-in diagnostics are held by the worker's engine, never log host text by
/// default. Tests can serialize raw and final rows for each revision.
nonisolated struct CandidateDiagnostic: Codable, Sendable {
    let surface: String
    let ruby: String
    let source: CandidateSource
    let engineScore: Double
    let engineRank: Int
    let queryReading: String
    let originalInput: String?
    let correctedInput: String?
    let correctedReading: String?
    let correctionMethod: String?
    let convertedText: String?
    let lmScore: Double?
    let channelCost: Double?
    let prominence: Double?
    let composingCount: String
    let exactReading: Bool
    let fullConsumption: Bool
    let engineFullConsumption: Bool
    let learned: Bool
    let scriptType: CandidateScript
    let learningEligible: Bool
    let revision: Int
    let scores: CandidateScoreFeatures
    let finalScore: Double
    let finalRank: Int
    init(_ value: CandidateSnapshot, rank: Int) {
        surface = value.text; ruby = value.reading; source = value.source
        engineScore = value.engineScore; engineRank = value.engineRank; queryReading = value.queryReading
        originalInput = value.correction?.originalInput; correctedInput = value.correction?.correctedInput
        correctedReading = value.correction?.correctedReading; correctionMethod = value.correction?.method
        convertedText = value.correction?.convertedText
        lmScore = value.correction?.lmScore; channelCost = value.correction?.errorCost; prominence = value.correction?.prominence
        composingCount = String(describing: value.composingCount)
        exactReading = value.exactReading; fullConsumption = value.fullConsumption
        engineFullConsumption = value.engineFullConsumption; learned = value.hasLearningEvidence
        scriptType = value.scriptType; learningEligible = value.learningEligible
        revision = value.revision; scores = value.features; finalScore = scores.total; finalRank = rank
    }
}
