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
    var prefixPenalty = 6.0 // Ordinary strip favors complete phrases; explicit range has no penalty.
    var orthographyLimit = 1.6 // Usage guidance is weaker than repeated user preference.
    var specialCandidate = 5.0 // Available above generic script, below strong exact lexical evidence.
    var emojiCandidate = 1.5 // Related emoji remain discoverable without displacing lexical words.
    var registeredWord = 2.0 // Explicit registration is stronger than generic fallback.
}

/// Admission is independent of presentation: a correction needs a meaningful
/// dictionary gain after paying for the edit. Shared by classic/topology/LM.
nonisolated enum CandidateCorrectionPolicy {
    /// Places choices that only the correction search found at their positions
    /// in `corrected`, keeping the relative order of `ordered` (which may be a
    /// model refinement of the list the search started from).
    static func inserting(_ corrected: [CandidateSnapshot], into ordered: [CandidateSnapshot]) -> [CandidateSnapshot] {
        let known = Set(ordered.map(CandidateIdentity.init))
        var result = ordered
        for (index, value) in corrected.enumerated() where !known.contains(CandidateIdentity(value)) {
            result.insert(value, at: min(index, result.count))
        }
        return result
    }
    static let channelWeight = 3.6
    static let minimumQuality = -5.0
    static let shortReadingMargin = 4.0 // Two kana have many accidental homophones.
    static let admissionMargin = 2.0
    static let additionalSoundEditMargin = 2.0 // Per extra sound edit, before reading-length normalization.
    static let wholeWordPriorityBonus = 3.0 // Verify an attested full reading before speculative phrase repairs.
    static let maximumAdmittedReadings = 2 // One useful single edit must not hide a stronger paired interpretation.
    /// Readings verified after the first admission. A stronger reading ranked
    /// just below it still competes (いきまる, then いきます); the rest of the
    /// list would only spend the time the first display is waiting for.
    static let queriesAfterAdmission = 3
    static let maximumPresentedCorrections = 4 // Two readings, each with lexical spelling and kana.
    static let minimumProminence: Float = 0.1
    static let maximumCachedReadings = 96
    static let windowedReadingThreshold = 8 // Longer readings are verified around the edit only.
    static let windowCandidatesPerReading = 2
    static let correctionDisplayRank = 1 // Best admitted correction is never below the second slot.
}

nonisolated struct CandidateScoreFeatures: Codable, Sendable {
    var engine = 0.0
    var exactReading = 0.0
    var fullConsumption = 0.0
    var script = 0.0
    var predictionOverrun = 0.0
    var interpretationEvidence = 0.0
    var continuity = 0.0
    // AzooKey learning stays in engine evidence; this is Vime selection frequency.
    var userLearning = 0.0
    var context = 0.0
    var typoCost = 0.0
    var orthography = 0.0
    var segmentation = 0.0
    var source = 0.0
    var languageModel = 0.0
    var total: Double { engine + exactReading + fullConsumption + script
        + predictionOverrun + interpretationEvidence + continuity + userLearning + context + typoCost + orthography + segmentation + source + languageModel }
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
                // Digits and symbols such as 12:30 are already final text.
                if value.queryReading.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) {
                    f.script -= weights.unresolvedScriptPenalty
                }
            }
            if value.source == .specialConversion || value.source == .emoji {
                f.engine = -weights.engineOrder * log1p(Double(value.engineRank))
                f.source = value.source == .specialConversion ? weights.specialCandidate : weights.emojiCandidate
            }
            if value.source == .userDictionary { f.source = weights.registeredWord }
            // Recalled pairs have no lattice score or native rank. Start them
            // conservatively; accepted user evidence supplies their promotion.
            if value.source == .rememberedConversion { f.engine = -weights.engineOrder * log1p(10) }
            let interpretedExact = value.source == .readingAlternative && value.lexical && value.fullConsumption
            if value.scopeFullConsumption && value.lexical && (value.exactReading || interpretedExact) {
                f.exactReading = weights.exactLexical
            }
            if value.scopeFullConsumption { f.fullConsumption = weights.fullConsumption }
            // Do not reward a prefix by discarding an unresolved Roman suffix;
            // completed-word prediction must keep its established evidence.
            if !value.fullConsumption && !value.explicitScope && value.queryReading.unicodeScalars.contains(where: { $0.isASCII }) {
                f.exactReading = 0
                f.fullConsumption = 0
            }
            if !value.fullConsumption && !value.explicitScope { f.segmentation = -weights.prefixPenalty }
            f.orthography = max(-weights.orthographyLimit, min(weights.orthographyLimit, value.orthographyScore))
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
            f.userLearning = CandidatePreferenceMemory.Policy.rankingBonus(
                score: katakana ? min(CandidatePreferenceMemory.Policy.maximumBonus, value.userPreferenceScore) : value.userPreferenceScore,
                confidence: katakana ? 0 : value.userPreferenceConfidence)
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
                (candidate.lexical ? 8 : 0)
                    + (candidate.displaySurface == nil && candidate.source != .rememberedConversion ? 4 : 0)
                    + (candidate.exactReading ? 2 : 0)
                    + (candidate.source == .scriptVariant ? 2 : candidate.source == .rememberedConversion ? 0 : 1)
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
    let correctionEditCount: Int?
    let correctionSoundEdits: [CorrectionSoundEdit]?
    let convertedText: String?
    let lmScore: Double?
    let channelCost: Double?
    let prominence: Double?
    let composingCount: String
    let exactReading: Bool
    let fullConsumption: Bool
    let engineFullConsumption: Bool
    let consumedReadingCount: Int
    let scopeReading: String
    let learned: Bool
    let scriptType: CandidateScript
    let learningEligible: Bool
    let widthVariant: CandidateWidthVariant?
    let revision: Int
    let scores: CandidateScoreFeatures
    let finalScore: Double
    let finalRank: Int
    init(_ value: CandidateSnapshot, rank: Int) {
        surface = value.text; ruby = value.reading; source = value.source
        engineScore = value.engineScore; engineRank = value.engineRank; queryReading = value.queryReading
        originalInput = value.correction?.originalInput; correctedInput = value.correction?.correctedInput
        correctedReading = value.correction?.correctedReading; correctionMethod = value.correction?.method
        correctionEditCount = value.correction?.editCount; correctionSoundEdits = value.correction?.soundEdits
        convertedText = value.correction?.convertedText
        lmScore = value.correction?.lmScore; channelCost = value.correction?.errorCost; prominence = value.correction?.prominence
        composingCount = String(describing: value.composingCount)
        exactReading = value.exactReading; fullConsumption = value.fullConsumption
        consumedReadingCount = value.consumedReadingCount; scopeReading = value.scopeReading
        engineFullConsumption = value.engineFullConsumption; learned = value.hasLearningEvidence
        scriptType = value.scriptType; learningEligible = value.learningEligible; widthVariant = value.widthVariant
        revision = value.revision; scores = value.features; finalScore = scores.total; finalRank = rank
    }
}
