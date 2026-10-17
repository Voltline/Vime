import Foundation

/// Compare complete readings using model evidence and personal preference.
/// Dictionary presentation scores select the initial pool and break model ties;
/// treating their arbitrary units as another likelihood hurt diagnostic quality.
nonisolated enum CandidateCompetitionPolicy {
    static let dictionaryPriorWeight = 0.0

    struct Plan {
        let slots: [Int]
    }

    static func plan(_ values: [CandidateSnapshot], katakana: Bool, maximumCandidates: Int = 8) -> Plan {
        let eligible = VimeLanguageModel.rerankingSlots(values, katakana: katakana)
        guard maximumCandidates >= 2, eligible.count >= 2 else { return Plan(slots: []) }
        // A confirmed personal leader is authoritative; do not spend the
        // publication window rediscovering an order we will keep anyway.
        if eligible.first == 0, values[0].userPreferenceConfidence >= 0.65 { return Plan(slots: []) }
        // Preserve the leading pair for incremental scoring; learned choices
        // then get budget before unfamiliar alternatives. The cap bounds work,
        // rather than excluding candidates on an uncalibrated score margin.
        let rest = Array(eligible.dropFirst(2))
        let learned = rest.filter { values[$0].userPreferenceScore > 0 }
        let others = rest.filter { values[$0].userPreferenceScore <= 0 }
        return Plan(slots: Array((Array(eligible.prefix(2)) + learned + others).prefix(maximumCandidates)))
    }

    static func applying(_ sums: [Double], slots: [Int],
                         to values: [CandidateSnapshot]) -> [CandidateSnapshot] {
        guard sums.count >= 2, sums.count <= slots.count, sums.allSatisfy(\.isFinite),
              Set(slots).count == slots.count, slots.allSatisfy({ values.indices.contains($0) }) else { return values }
        let scoredSlots = Array(slots.prefix(sums.count))
        let best = sums.max()!
        var adjusted = zip(scoredSlots, sums).map { index, sum in
            var value = values[index]
            let dictionary = value.features.total - value.features.languageModel - value.features.userLearning
            value.features.userLearning = CandidatePreferenceMemory.Policy.rankingBonus(score: value.userPreferenceScore,
                                                                                       confidence: value.userPreferenceConfidence)
            // Replace the presentation score with model evidence. Personal
            // learning remains in full units, outside the dictionary weight.
            value.features.languageModel = (sum - best) - (1 - dictionaryPriorWeight) * dictionary
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
