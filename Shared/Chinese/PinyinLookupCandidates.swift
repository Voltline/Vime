import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Places words found by their Mandarin reading (PinyinKanjiLookup) among the
/// Japanese engine's candidates for the same letters.
///
/// The rule, in order:
///
/// 1. The letters **cannot be romaji** when they contain q, x, v (or ü), "zh",
///    a pinyin final "uang", "iang" or "iong", or a letter the romaji converter
///    left unconverted before the end of the composition (jingji → じんgじ).
///    Then every match is tier A.
/// 2. Otherwise the letters read as kana, and the engine decides. When it has
///    a **single dictionary word for the whole reading** (exact, or a prediction
///    extending it while the last syllable is still incomplete), the user may
///    well be typing Japanese, so every match is tier B: kencha → 献茶.
/// 3. With no such word, a match is tier A when the letters contain "ian"
///    (a pinyin final that Japanese spells only across a syllable boundary, as
///    in 事案) or when every character was typed in pinyin and the last syllable
///    is complete: jiancha, jiansatsu, tushuguan, yinyue. Other mixes of romaji
///    and pinyin stay tier B, since the letters are plausible Japanese.
///
/// Tier A goes before all engine candidates, at most `highLimit` of them.
/// Tier B goes after the first `lowInsertionIndex` engine candidates, at most
/// `lowLimit`, and only common words typed with telling pinyin: complete
/// matches of two or more characters, no proper nouns, word cost at most
/// `lowMaximumCost`, and every pinyin syllable at least three letters (a
/// two-letter one such as su, ya or ha is also a single kana). On
/// Japanese-looking letters anything else is mostly noise (hashi → 葉室,
/// sushi → 素子, yama → 邪魔), while kencha still offers 検査 and 検察.
/// Within a tier, `PinyinKanjiLookup.Match.ranks` orders matches: complete
/// before partial, then fewer pinyin/romaji switches, then word cost.
/// A word the engine already offers is not repeated.
nonisolated enum PinyinLookupCandidates {
    static let highLimit = 8
    static let lowLimit = 3
    static let lowInsertionIndex = 3
    /// Mozc cost; 検察 is 5211, the rare 素適 6109.
    static let lowMaximumCost = 6000

    enum Tier: Equatable, Sendable { case high, low }

    struct Evidence: Equatable, Sendable {
        /// Rule 1: the letters cannot be romaji.
        var notRomaji = false
        /// Rule 3: the letters contain "ian".
        var pinyinFinal = false
        /// Rule 2: the engine has one dictionary word for the whole reading.
        var engineWord = false
    }

    static func evidence(letters: String, composing: ComposingText, engine: [CandidateSnapshot]) -> Evidence {
        let letters = letters.lowercased()
        var value = Evidence()
        let kana = composing.convertTarget
        let latin = { (c: Character) in c.isASCII && c.isLetter }
        let pending = kana.reversed().prefix(while: latin).count
        let settled = kana.dropLast(pending)
        value.notRomaji = letters.contains { "qxvü".contains($0) }
            || ["zh", "uang", "iang", "iong"].contains { letters.contains($0) }
            || settled.contains(where: latin)
        value.pinyinFinal = letters.contains("ian")
        let reading = RomajiConverter.katakana(String(settled))
        value.engineWord = engine.contains { snapshot in
            guard snapshot.source != .pinyinLookup, snapshot.fullConsumption, snapshot.lexical,
                  snapshot.candidate.data.count == 1,
                  !snapshot.reading.unicodeScalars.contains(where: { $0.isASCII }) else { return false }
            return pending == 0 ? snapshot.reading == reading
                : snapshot.reading.count > reading.count && snapshot.reading.hasPrefix(reading)
        }
        return value
    }

    /// nil: the match is not shown.
    static func tier(of match: PinyinKanjiLookup.Match, evidence: Evidence) -> Tier? {
        if evidence.notRomaji { return .high }
        if !evidence.engineWord && (evidence.pinyinFinal || (!match.partial && match.parts.allSatisfy { $0.mode == .pinyin })) {
            return .high
        }
        guard !match.partial, match.parts.count > 1, !match.properNoun, match.cost <= lowMaximumCost,
              match.parts.allSatisfy({ $0.mode != .pinyin || $0.letters.count >= 3 }) else { return nil }
        return .low
    }

    /// The engine's list with lookup results placed by tier. `composing` is
    /// the composition the engine list answers; its raw letters are the query.
    static func merge(_ engine: [CandidateSnapshot], composing: ComposingText, revision: Int,
                      lookup: PinyinKanjiLookup) -> [CandidateSnapshot] {
        let letters = composing.input.compactMap { element -> Character? in
            if case .character(let c) = element.piece { return c }
            return nil
        }
        guard letters.count == composing.input.count, !composing.isEmpty else { return engine }
        let input = String(letters)
        let matches = lookup.matches(for: input)
        guard !matches.isEmpty else { return engine }
        let evidence = evidence(letters: input, composing: composing, engine: engine)
        let offered = Set(engine.map(\.text))
        var high: [CandidateSnapshot] = [], low: [CandidateSnapshot] = []
        let queryReading = RomajiConverter.katakana(composing.convertTarget)
        for match in matches.sorted(by: PinyinKanjiLookup.Match.ranks) where !offered.contains(match.surface) {
            guard let tier = tier(of: match, evidence: evidence) else { continue }
            if tier == .high ? high.count >= highLimit : low.count >= lowLimit { continue }
            let rank = high.count + low.count
            let snapshot = snapshot(for: match, composing: composing, revision: revision,
                queryReading: queryReading, rank: rank)
            if tier == .high { high.append(snapshot) } else { low.append(snapshot) }
        }
        let split = min(lowInsertionIndex, engine.count)
        return high + engine[..<split] + low + engine[split...]
    }

    /// Selecting the word commits its surface and ends the composition. It
    /// carries no dictionary data and is no learning target: its reading is
    /// not the typed kana, so Japanese learning would pair the wrong reading.
    static func snapshot(for match: PinyinKanjiLookup.Match, composing: ComposingText, revision: Int,
                         queryReading: String, rank: Int) -> CandidateSnapshot {
        let candidate = Candidate(text: match.surface, value: .zero, composingCount: .inputCount(composing.input.count),
            lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false)
        return CandidateSnapshot(candidate: candidate, revision: revision, source: .pinyinLookup,
            remainingComposition: ComposingText(), originalInputCount: composing.input.count,
            consumedInputCount: composing.input.count, queryReading: queryReading,
            engineRank: 1000 + rank, readingOverride: match.reading, predictionStatus: false)
    }
}
