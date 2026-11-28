import Foundation

/// Jamo-level Korean typo corrector covering neighbor-key substitution,
/// adjacent transposition, single-jamo insertion, and single-jamo omission.
///
/// Operates directly against the memory-mapped `KoreanLexicon` with strict
/// precision guards so valid Korean input is not disturbed by noisy suggestions.
nonisolated enum KoreanErrorCorrector {
    struct Correction: Equatable, Sendable {
        let surface: String
        let cost: Int
        let freq: UInt16
    }

    /// Minimum lexicon frequency for a typo correction candidate.
    static let minCorrectionFreq: UInt16 = 14000
    /// Minimum jamo length before typo corrections are offered.
    static let minJamoLength = 3
    /// Maximum jamo length to keep edit search strictly sub-millisecond.
    static let maxJamoLength = 16

    /// High-frequency jamo considered for single-jamo omission recovery.
    private static let commonOmittedJamo: [Character] = [
        "ㅏ", "ㅓ", "ㅗ", "ㅜ", "ㅡ", "ㅣ", "ㅐ", "ㅔ",
        "ㅇ", "ㄴ", "ㄹ", "ㄱ", "ㅅ", "ㄷ", "ㅁ", "ㅂ", "ㅈ", "ㅎ"
    ]

    /// Returns ranked typo corrections for `composedText` (whose decomposed jamo is `jamos`),
    /// or `[]` when the input is already a valid Korean word or valid `noun + particle`.
    static func corrections(
        for composedText: String,
        jamos: [Character],
        lexicon: KoreanLexicon,
        blocklist: LearningExclusionList = PredictionBlocklist.korean,
        limit: Int = 3
    ) -> [Correction] {
        guard limit > 0, jamos.count >= minJamoLength, jamos.count <= maxJamoLength else { return [] }
        let jamoString = String(jamos)

        // Precision guard: never offer typo corrections for valid known words or valid noun+particle forms.
        if let exact = lexicon.exactMatch(jamo: jamoString), exact.freq >= 4000 {
            return []
        }
        if lexicon.isValidNounWithParticle(composedText) {
            return []
        }

        // If the input already has strong lexicon prefix completions (user is mid-word),
        // only offer corrections when the current text contains a standalone/malformed jamo
        // or has no valid prefix match at all.
        let hasStandaloneJamo = composedText.unicodeScalars.contains { HangulComposer.isCompatibilityJamo($0) }
        let hasPrefix = lexicon.hasPrefix(jamoPrefix: jamoString)
        if hasPrefix && !hasStandaloneJamo {
            return []
        }

        var bestBySurface: [String: Correction] = [:]

        func consider(_ candidateJamo: String, cost: Int) {
            guard let entry = lexicon.exactMatch(jamo: candidateJamo),
                  entry.freq >= minCorrectionFreq,
                  entry.surface != composedText,
                  !blocklist.matches(entry.surface) else { return }
            let candidate = Correction(surface: entry.surface, cost: cost, freq: entry.freq)
            if let existing = bestBySurface[entry.surface] {
                if candidate.cost < existing.cost || (candidate.cost == existing.cost && candidate.freq > existing.freq) {
                    bestBySurface[entry.surface] = candidate
                }
            } else {
                bestBySurface[entry.surface] = candidate
            }
        }

        // 1. Adjacent transposition (cost 1): e.g., ㅎㄴㅏㄱㅜㄱ -> ㅎㅏㄴㄱㅜㄱ (한국)
        for i in 0..<(jamos.count - 1) where jamos[i] != jamos[i + 1] {
            var mutated = jamos
            mutated.swapAt(i, i + 1)
            consider(String(mutated), cost: 1)
        }

        // 2. Physical neighbor-key substitution (cost 1): e.g., ㅎㅓㄴㄱㅜㄱ -> ㅎㅏㄴㄱㅜㄱ
        for i in 0..<jamos.count {
            guard let neighbors = KoreanLayout.neighbors[jamos[i]] else { continue }
            var mutated = jamos
            for neighbor in neighbors {
                mutated[i] = neighbor
                consider(String(mutated), cost: 1)
            }
        }

        // 3. Single-jamo insertion / extra keystroke (cost 2): e.g., ㅎㅏㅏㄴㄱㅜㄱ -> ㅎㅏㄴㄱㅜㄱ
        if jamos.count >= minJamoLength + 1 {
            for i in 0..<jamos.count {
                var mutated = jamos
                mutated.remove(at: i)
                consider(String(mutated), cost: 2)
            }
        }

        // 4. Single-jamo omission (cost 2): targeted positions when no cost-1 hit yet or few hits.
        if bestBySurface.count < limit {
            for i in 0...jamos.count {
                for jamo in commonOmittedJamo {
                    var mutated = jamos
                    mutated.insert(jamo, at: i)
                    consider(String(mutated), cost: 2)
                }
            }
        }

        return bestBySurface.values.sorted { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
            if lhs.freq != rhs.freq { return lhs.freq > rhs.freq }
            return lhs.surface < rhs.surface
        }.prefix(limit).map { $0 }
    }
}
