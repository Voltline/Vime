import Foundation

/// The order the Chinese candidates show in, from every source at once.
///
/// Each source reads only what is left of the composition after the text
/// chosen from its start: Rime's candidates, readings that keep typed words
/// as typed (ChineseMixedInput), spelling corrections and the user's
/// phrases. This decides where each one goes, so the same sources always
/// show the same way, however and whenever they came in.
nonisolated enum ChineseCandidateList {
    /// What a shown candidate is, as an index into its source.
    enum Slot: Equatable, Sendable {
        case rime(Int), correction(Int), generated(Int), phrase(Int), mixed(Int), special(Int), contact(Int)
    }

    /// Where the readings keeping typed words go.
    enum MixedPlacement: Equatable, Sendable {
        /// Nowhere.
        case none
        /// All of them first: capitals are no pinyin.
        case leadAll
        /// The first one first, the others third and on: Rime stopped short
        /// of the input at letters no pinyin takes.
        case leadFirst
        /// Only the first, first: Rime read the whole input by taking a word
        /// for abbreviations, and the model prefers keeping the word.
        case overRime
    }

    /// The display order: Rime's candidates in `order` (indices into
    /// `rime`, the texts shown), with the corrections, readings and phrases
    /// placed among them.
    static func slots(rime: [String], order: [Int], corrections: [String], correctionLeads: Bool,
                      mixed: Int, placement: MixedPlacement, phrases: [String], specials: [String] = [],
                      contacts: [String] = [], generated: [String] = [], generatedLeads: Bool = false) -> [Slot] {
        var slots = order.map(Slot.rime)
        if !generated.isEmpty, let lead = order.first {
            // A generated sentence moves up instead of duplicating a lower Rime candidate.
            let moved = Set(generated)
            slots.removeAll { if case .rime(let index) = $0 { index != lead && moved.contains(rime[index]) } else { false } }
            let shown = generated.indices.filter { generated[$0] != rime[lead] }
            if generatedLeads, !correctionLeads, shown.first == 0 {
                slots.insert(.generated(0), at: 0)
                slots.insert(contentsOf: shown.dropFirst().map(Slot.generated), at: min(2, slots.count))
            } else {
                slots.insert(contentsOf: shown.map(Slot.generated), at: min(1, slots.count))
            }
        }
        if !corrections.isEmpty, let lead = order.first {
            // A correction moves its phrase up instead of showing it twice.
            let moved = Set(corrections)
            slots.removeAll {
                switch $0 {
                case .rime(let index): index != lead && moved.contains(rime[index])
                case .generated(let index): correctionLeads && moved.contains(generated[index])
                default: false
                }
            }
            let shownGenerated = Set(slots.compactMap {
                if case .generated(let index) = $0 { generated[index] } else { nil }
            })
            let shown = corrections.indices.filter {
                corrections[$0] != rime[lead] && !shownGenerated.contains(corrections[$0])
            }
            if correctionLeads, shown.first == 0 {
                slots.insert(.correction(0), at: 0)
                slots.insert(contentsOf: shown.dropFirst().map(Slot.correction), at: min(2, slots.count))
            } else {
                slots.insert(contentsOf: shown.map(Slot.correction), at: min(1, slots.count))
            }
        }
        if mixed > 0 {
            switch placement {
            case .none: break
            case .leadAll:
                slots.insert(contentsOf: (0..<mixed).map(Slot.mixed), at: 0)
            case .overRime:
                slots.insert(.mixed(0), at: 0)
            case .leadFirst where corrections.isEmpty:
                slots.insert(.mixed(0), at: 0)
                slots.insert(contentsOf: (1..<mixed).map(Slot.mixed), at: min(2, slots.count))
            case .leadFirst:
                // A typo (wixiang), not a word: its correction keeps its place.
                let after = slots.lastIndex { if case .correction = $0 { true } else { false } } ?? 0
                slots.insert(contentsOf: (0..<mixed).map(Slot.mixed), at: min(after + 1, slots.count))
            }
        }
        if !phrases.isEmpty {
            let texts = Set(phrases)
            slots.removeAll { if case .rime(let index) = $0 { texts.contains(rime[index]) } else { false } }
            slots.insert(contentsOf: phrases.indices.map(Slot.phrase), at: 0)
        }
        if !specials.isEmpty {
            slots.insert(contentsOf: specials.indices.map(Slot.special), at: min(1, slots.count))
        }
        if !contacts.isEmpty {
            let existing: Set<String> = Set(slots.compactMap { slot in
                switch slot {
                case .rime(let i): rime[i]
                case .phrase(let i): phrases[i]
                case .correction(let i): corrections[i]
                case .generated(let i): generated[i]
                case .special(let i): specials[i]
                case .mixed, .contact: nil
                }
            })
            let fresh = contacts.indices.filter { !existing.contains(contacts[$0]) }
            if !fresh.isEmpty {
                slots.insert(contentsOf: fresh.map(Slot.contact), at: min(2, slots.count))
            }
        }
        return slots
    }

    /// Where the readings keeping typed words go, once the round's sources
    /// are in: `rimeShort` when Rime's first candidate stops short of the
    /// input (or there is none); `best` and `rival` the model's scores of the
    /// best reading and of Rime's first, when it weighed them.
    static func placement(readings: Int, capitals: Bool, rimeShort: Bool, best: Double?, rival: Double?) -> MixedPlacement {
        guard readings > 0 else { return .none }
        if capitals { return .leadAll }
        if rimeShort { return .leadFirst }
        guard let best, let rival, best > rival else { return .none }
        return .overRime
    }
}
