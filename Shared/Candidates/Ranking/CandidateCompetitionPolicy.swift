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
        // Only context-matched choices are authoritative. A familiar spelling
        // from another sentence must not disable semantic disambiguation.
        if eligible.first == 0, values[0].personalPreferenceProtectsOrder { return Plan(slots: []) }
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
            value.features.userLearning = CandidatePreferenceMemory.Policy.rankingBonus(
                score: min(value.userPreferenceScore, value.modelPreferenceScoreLimit),
                confidence: value.personalPreferenceProtectsOrder ? value.userPreferenceConfidence : 0)
            // Replace the presentation score with model evidence. The personal
            // prior above remains separate from the dictionary weight.
            value.features.languageModel = (sum - best) - (1 - dictionaryPriorWeight) * dictionary
            return (index: index, value: value)
        }
        let leader = scoredSlots.min()!
        adjusted.sort {
            if $0.index != $1.index, values[leader].personalPreferenceProtectsOrder {
                if $0.index == leader { return true }
                if $1.index == leader { return false }
            }
            let a = $0.value.features.total, b = $1.value.features.total
            return a == b ? $0.index < $1.index : a > b
        }
        let sortedSlots = scoredSlots.sorted()
        // A strong global habit should remain easy to select without vetoing
        // the context model's winner. Reserve at most one secondary position
        // among existing scored slots; never displace an unscored operation.
        if !values[leader].personalPreferenceProtectsOrder, values[leader].userPreferenceConfidence >= 0.65,
           let position = adjusted.firstIndex(where: { $0.index == leader }),
           let visible = sortedSlots.lastIndex(where: { $0 < CandidatePreferenceMemory.Policy.familiarCandidateVisibility }),
           visible > 0, position > visible {
            adjusted.insert(adjusted.remove(at: position), at: visible)
        }
        var result = values
        for (slot, item) in zip(sortedSlots, adjusted) { result[slot] = item.value }
        return result
    }
}
