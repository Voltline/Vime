import Foundation

/// Dictionary scores decide who is competing; neural evidence is a bounded
/// adjustment to that score, never a replacement for accepted user choices.
nonisolated enum CandidateCompetitionPolicy {
    struct Plan {
        let slots: [Int]
        let adjustmentLimit: Double
    }

    static func plan(_ values: [CandidateSnapshot], katakana: Bool, maximumCandidates: Int = 6) -> Plan {
        let literal = VimeLanguageModel.rerankingSlots(values, katakana: katakana)
        var preferredSpellings = Set<String>()
        let eligible = literal.filter { index in
            let value = values[index]
            let preferred = JapaneseLanguageResources.shared.preferredSurface(value.candidate)
            let family = value.reading + "\0" + preferred
            // Keep the dictionary's preferred spelling when it already leads
            // its alternative. Spend model calls on different words instead.
            // An explicit personal spelling preference remains eligible.
            if value.text == preferred { preferredSpellings.insert(family) }
            return value.text == preferred || value.userPreferenceScore > 0 || !preferredSpellings.contains(family)
        }
        guard maximumCandidates >= 2, eligible.count >= 2 else { return Plan(slots: [], adjustmentLimit: 0) }
        let first = values[eligible[0]], second = values[eligible[1]]
        let gap = baseScore(first) - baseScore(second)
        if gap >= 4 || (first.userPreferenceConfidence >= 0.65 && gap >= 1) {
            return Plan(slots: [], adjustmentLimit: 0)
        }
        // A few ranks of engine-order prior alone are not decisive lexical
        // evidence. Reserve the narrow adjustment for a larger combined gap.
        let close = gap <= 2.5
        let window = close ? 5.0 : 3.5
        let contenders = eligible.dropFirst(2).filter { baseScore(first) - baseScore(values[$0]) <= window }
        // Score the core pair first; explicitly learned competitors get the
        // next available budget before equally plausible unfamiliar words.
        let learned = contenders.filter { values[$0].userPreferenceScore > 0 }
        let others = contenders.filter { values[$0].userPreferenceScore <= 0 }
        let slots = Array((Array(eligible.prefix(2)) + learned + others).prefix(min(6, maximumCandidates)))
        return Plan(slots: slots, adjustmentLimit: first.userPreferenceConfidence >= 0.65 ? 0.5 : close ? 4 : 1.75)
    }

    static func baseScore(_ value: CandidateSnapshot) -> Double {
        value.features.total - value.features.languageModel - value.features.userLearning
            + CandidatePreferenceMemory.Policy.rankingBonus(score: value.userPreferenceScore,
                                                           confidence: value.userPreferenceConfidence)
    }

    static func applying(_ sums: [Double], slots: [Int], limit: Double,
                         to values: [CandidateSnapshot]) -> [CandidateSnapshot] {
        guard sums.count >= 2, sums.count <= slots.count, sums.allSatisfy(\.isFinite) else { return values }
        let scoredSlots = Array(slots.prefix(sums.count))
        let best = sums.max()!
        var adjusted = zip(scoredSlots, sums).map { index, sum in
            var value = values[index]
            value.features.userLearning = CandidatePreferenceMemory.Policy.rankingBonus(score: value.userPreferenceScore,
                                                                                       confidence: value.userPreferenceConfidence)
            value.features.languageModel = max(-limit, 0.8 * (sum - best))
            return (index: index, value: value)
        }
        let leader = scoredSlots.min()!
        adjusted.sort {
            if $0.index != $1.index, values[leader].userPreferenceConfidence >= 0.65 {
                if $0.index == leader { return true }
                if $1.index == leader { return false }
            }
            let a = $0.value.features.total, b = $1.value.features.total
            return a == b ? $0.index < $1.index : a > b
        }
        var result = values
        for (slot, item) in zip(scoredSlots.sorted(), adjusted) { result[slot] = item.value }
        return result
    }
}
