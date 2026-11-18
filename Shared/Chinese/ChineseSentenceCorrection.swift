import Foundation

/// One typing slip anywhere in a sentence, found by the model.
///
/// Rime's speller fixes slips inside a syllable it can still read; one that
/// crosses syllables, drops or adds a letter, or swaps two keys leaves Rime a
/// sentence of the wrong words. After a pause, the model scores the shown
/// first sentence token by token; the letters under its two weakest tokens
/// are where a slip most likely is. Spellings one edit away there, converted
/// by Rime, compete with that sentence: each kind of edit pays its penalty,
/// and a correction shows second when it wins, first only when it wins by
/// `leadMargin`, so clean typing keeps its sentence.
///
/// Parameters come from a private benchmark of typed WeChat messages, tuned
/// on a third of its sentences and checked once on the rest.
nonisolated enum ChineseSentenceCorrection {
    typealias Edit = PinyinSpellingCorrection.Edit

    /// Development switch (App Group defaults); on unless set to false.
    static let developmentSwitchKey = "vime.development.chineseSentenceCorrection"
    static var isEnabled: Bool {
        UserDefaults(suiteName: KeyboardPreferences.appGroup)?.object(forKey: developmentSwitchKey) as? Bool ?? true
    }

    /// Inputs this long, in letters, are searched.
    static let letters = 4...48
    /// What each kind of slip costs, in log probability.
    static let penalties: [Edit: Double] = [.swap: 3.0, .neighbour: 1.0, .drop: 0.0, .insert: 3.0]
    /// A correction goes first only when it beats the sentence by this much.
    static let leadMargin = 6.0
    /// It shows second when it beats the sentence by more than this.
    static let showMargin = 3.0
    /// Each place down Rime's list for a corrected spelling costs this much.
    static let placePenalty = 0.1
    /// The sentence's weakest tokens whose letters are searched.
    static let weakestTokens = 2
    /// Letters searched on each side of a weak token's.
    static let slack = 1
    /// Rime's first conversions weighed for each corrected spelling.
    static let perSpelling = 2
    /// Rime candidates looked at for each spelling, before `perSpelling` usable ones.
    static let lookupLimit = 8
    static let spellingLimit = 64

    /// Whether `input` is searched at all: plain letters of a searched length.
    static func wants(_ input: String) -> Bool {
        letters.contains(input.count) && input.allSatisfy { ("a"..."z").contains($0) }
    }

    /// The letters of `input` worth searching: around the `weakestTokens`
    /// tokens of `text` (with their log probabilities, in order), by the
    /// letters each character spells. Nil when `text` does not line up with
    /// the letters, so everything is searched.
    static func windows(tokens: [(text: String, logProbability: Double)], text: String, input: String,
                        lexicon: ChinesePinyinLexicon) -> [ClosedRange<Int>]? {
        guard let spans = PinyinSpellingCorrection.letterSpans(of: text, in: input, lexicon: lexicon),
              tokens.reduce(0, { $0 + $1.text.unicodeScalars.count }) == spans.count
        else { return nil }
        var character = 0
        let placed = tokens.compactMap { token -> (range: ClosedRange<Int>, logProbability: Double)? in
            let count = token.text.unicodeScalars.count
            defer { character += count }
            guard count > 0 else { return nil }
            let covered = spans[character..<character + count]
            return (covered.first!.lowerBound...covered.last!.upperBound, token.logProbability)
        }
        guard !placed.isEmpty else { return nil }
        return placed.enumerated().sorted {
            $0.element.logProbability != $1.element.logProbability
                ? $0.element.logProbability < $1.element.logProbability : $0.offset < $1.offset
        }.prefix(weakestTokens).map { ($0.element.range.lowerBound - slack)...($0.element.range.upperBound + slack) }
    }

    /// Spellings one edit from `input` whose edit falls in `windows` (all
    /// of them when nil): where the spelling first differs from the input.
    static func spellings(for input: String, windows: [ClosedRange<Int>]?) -> [(spelling: String, edit: Edit)] {
        let typed = Array(input)
        return PinyinSpellingCorrection.sentenceSpellings(for: input).filter { item in
            guard let windows else { return true }
            let letters = Array(item.spelling)
            var at = 0
            while at < min(typed.count, letters.count), typed[at] == letters[at] { at += 1 }
            return windows.contains { $0.contains(at) }
        }.prefix(spellingLimit).map { $0 }
    }

    struct Option: Sendable, Equatable {
        let spelling: String
        let edit: Edit
        /// Place among the spelling's usable conversions.
        let rank: Int
        let candidate: RimeCandidate
        var penalty: Double { (penalties[edit] ?? 0) + placePenalty * Double(rank) }
    }

    /// What Rime made of each spelling, as options against `literal`: the
    /// first `perSpelling` whole conversions with Chinese characters, once
    /// each, never `literal` itself, and only what `allows` lets through.
    static func options(_ found: [(spelling: String, candidates: [RimeCandidate])],
                        edits: [String: Edit], literal: String, allows: (String) -> Bool) -> [Option] {
        var seen: Set<String> = [literal]
        var options: [Option] = []
        for (spelling, candidates) in found {
            guard let edit = edits[spelling] else { continue }
            let usable = candidates.filter {
                $0.coversInput && $0.genuine.unicodeScalars.contains { $0.properties.isIdeographic }
            }.prefix(perSpelling)
            for (rank, candidate) in usable.enumerated()
            where seen.insert(candidate.genuine).inserted && allows(candidate.genuine) && allows(candidate.text) {
                options.append(Option(spelling: spelling, edit: edit, rank: rank, candidate: candidate))
            }
        }
        return options
    }

    /// The score below which an option cannot show: scoring can stop there.
    static func floor(literal: Double, option: Option) -> Double { literal + option.penalty + showMargin }

    struct Decision: Sendable, Equatable {
        let option: Option
        /// Shown first, ahead of the sentence as typed.
        let leads: Bool
    }

    /// The best option against the sentence as typed (`literal`, its
    /// score), when it beats it after its penalty; nil otherwise.
    static func decide(literal: Double, options: [Option], scores: [Double]) -> Decision? {
        guard literal.isFinite, options.count == scores.count else { return nil }
        let best = zip(options, scores).filter { $0.1.isFinite }
            .map { (option: $0.0, gain: $0.1 - $0.0.penalty - literal) }
            .enumerated().max { $0.element.gain != $1.element.gain ? $0.element.gain < $1.element.gain : $0.offset > $1.offset }?
            .element
        guard let best, best.gain > showMargin else { return nil }
        return Decision(option: best.option, leads: best.gain > leadMargin)
    }
}
