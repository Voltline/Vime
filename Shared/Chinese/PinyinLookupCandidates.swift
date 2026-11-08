import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Places words found by their Mandarin reading (PinyinKanjiLookup) among the
/// Japanese engine's candidates for the same letters.
///
/// The rule, in order:
///
/// 1. The letters **cannot be romaji** when they contain q, x before i or u,
///    v (or ü) after l or n, "zh", a pinyin final "uang", "iang" or "iong", or a
///    letter the romaji converter left unconverted before the end of the
///    composition (jingji → じんgじ). Then every match is tier A. Other x and v
///    are romaji: xtu is っ, va is ゔぁ.
/// 2. Otherwise the letters read as kana, and the engine decides. When it has
///    a **single dictionary word for the whole reading** (exact, or a prediction
///    extending it while the last syllable is still incomplete), the user may
///    well be typing Japanese, so every match is tier B: kencha → 献茶.
/// 3. With no such word, a match is tier A when the letters contain "ian"
///    (a pinyin final that Japanese spells only across a syllable boundary, as
///    in 事案) or when every character was typed in pinyin, the last syllable
///    is complete, and the letters hold a pinyin medial vowel pair (ia, ie, io,
///    ua, ue, uo): jiancha, jiansatsu, tushuguan, yinyue. Letters made only of
///    syllables Japanese also has are left to the engine even when its answer
///    is a phrase (deshou → でしょう, renai → れない, not 得手 or 仁愛). Other mixes
///    of romaji and pinyin stay tier B, since the letters are plausible Japanese.
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
        /// Rule 3: the letters contain a pinyin medial vowel pair.
        var pinyinMedial = false
        /// Rule 2: the engine has one dictionary word for the whole reading.
        var engineWord = false
    }

    private static func isLatin(_ c: Character) -> Bool { c.isASCII && c.isLetter }

    /// The romaji converter left a letter inside the kana, before the letters
    /// still being typed at the end: jingji → じんgじ.
    static func leavesLettersInKana(_ composing: ComposingText) -> Bool {
        let kana = composing.convertTarget
        return kana.dropLast(kana.reversed().prefix(while: isLatin).count).contains(where: isLatin)
    }

    /// Rule 1: the letters cannot be romaji.
    static func cannotBeRomaji(letters: String, composing: ComposingText) -> Bool {
        let letters = letters.lowercased()
        return letters.contains { "qü".contains($0) }
            || ["zh", "uang", "iang", "iong", "xi", "xu", "lv", "nv"].contains { letters.contains($0) }
            || leavesLettersInKana(composing)
    }

    /// Whether the preedit shows the typed letters instead of kana: when kana
    /// with letters left inside would be unreadable (じんgじ), or when a
    /// looked-up word leads the list, which takes pinyin-only evidence, so the
    /// user is typing pinyin (tushuguan, not つしゅぐあn).
    static func showsLetters(composing: ComposingText, lookupLeads: Bool) -> Bool {
        guard !composing.isEmpty, typedLetters(composing) != nil else { return false }
        return lookupLeads || leavesLettersInKana(composing)
    }

    /// The raw letters, or nil when the composition holds anything else.
    static func typedLetters(_ composing: ComposingText) -> String? {
        let letters = composing.input.compactMap { element -> Character? in
            if case .character(let c) = element.piece, c.isASCII ? c.isLetter : c == "ü" { return c }
            return nil
        }
        return letters.count == composing.input.count ? String(letters) : nil
    }

    static func evidence(letters: String, composing: ComposingText, engine: [CandidateSnapshot]) -> Evidence {
        let letters = letters.lowercased()
        var value = Evidence()
        let kana = composing.convertTarget
        let pending = kana.reversed().prefix(while: isLatin).count
        let settled = kana.dropLast(pending)
        value.notRomaji = cannotBeRomaji(letters: letters, composing: composing)
        value.pinyinFinal = letters.contains("ian")
        value.pinyinMedial = ["ia", "ie", "io", "ua", "ue", "uo"].contains { letters.contains($0) }
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
    /// `pinyinContext`: this composition already showed pinyin, so the rest
    /// of it is pinyin too (wenti after 経済 was chosen from jingjiwenti).
    static func tier(of match: PinyinKanjiLookup.Match, evidence: Evidence, pinyinContext: Bool = false) -> Tier? {
        if evidence.notRomaji || pinyinContext { return .high }
        if !evidence.engineWord && (evidence.pinyinFinal
            || (evidence.pinyinMedial && !match.partial && match.parts.allSatisfy { $0.mode == .pinyin })) {
            return .high
        }
        guard !match.partial, match.parts.count > 1, !match.properNoun, match.cost <= lowMaximumCost,
              match.parts.allSatisfy({ $0.mode != .pinyin || $0.letters.count >= 3 }) else { return nil }
        return .low
    }

    /// The engine's list with lookup results placed by tier. `composing` is
    /// the composition the engine list answers; its raw letters are the query.
    static func merge(_ engine: [CandidateSnapshot], composing: ComposingText, revision: Int,
                      lookup: PinyinKanjiLookup, pinyinContext: Bool = false,
                      falseFriends: PinyinFalseFriends = .shared) -> [CandidateSnapshot] {
        let letters = composing.input.compactMap { element -> Character? in
            if case .character(let c) = element.piece { return c }
            return nil
        }
        guard letters.count == composing.input.count, !composing.isEmpty else { return engine }
        let input = String(letters)
        var matches = lookup.matches(for: input)
        let evidence = evidence(letters: input, composing: composing, engine: engine)
        var consumed = letters.count, remaining = ComposingText()
        if matches.isEmpty {
            matches = prefixMatches(for: input, evidence: evidence, pinyinContext: pinyinContext, lookup: lookup)
            guard let first = matches.first else { return engine }
            consumed = first.letterCount
            for letter in letters[consumed...] { RomajiConverter.insert(String(letter), into: &remaining) }
        }
        let prefix = consumed < letters.count
        var offered = Set(engine.map(\.text))
        var high: [CandidateSnapshot] = [], low: [CandidateSnapshot] = []
        var highCount = 0, lowCount = 0
        let queryReading = RomajiConverter.katakana(composing.convertTarget)
        for match in matches.sorted(by: PinyinKanjiLookup.Match.ranks) where !offered.contains(match.surface) {
            guard let tier = prefix ? .high : tier(of: match, evidence: evidence, pinyinContext: pinyinContext) else { continue }
            if tier == .high ? highCount >= highLimit : lowCount >= lowLimit { continue }
            var added = [snapshot(surface: match.surface, reading: match.reading, composing: composing,
                                  consumed: consumed, remaining: remaining, revision: revision,
                                  queryReading: queryReading, rank: high.count + low.count)]
            offered.insert(match.surface)
            // A false friend notes its Japanese meaning, and the Japanese word
            // for its Chinese meaning follows it, outside the tier's limit.
            if let entry = falseFriends[match.surface] {
                added[0].lookupNote = .falseFriend(meaning: entry.meaning)
                if let equivalent = entry.equivalent, !offered.contains(equivalent.surface) {
                    var snapshot = snapshot(surface: equivalent.surface, reading: equivalent.reading, composing: composing,
                        consumed: consumed, remaining: remaining, revision: revision,
                        queryReading: queryReading, rank: high.count + low.count + 1)
                    snapshot.lookupNote = .japaneseEquivalent
                    added.append(snapshot)
                    offered.insert(equivalent.surface)
                }
            }
            if tier == .high { high += added; highCount += 1 } else { low += added; lowCount += 1 }
        }
        let split = min(lowInsertionIndex, engine.count)
        return high + engine[..<split] + low + engine[split...]
    }

    /// Words for the longest beginning of letters that spell no whole word,
    /// so a run of pinyin is chosen word by word: jingjiwenti offers 経済, and
    /// wenti stays to be looked up next. Only when the user is clearly typing
    /// pinyin: the letters cannot be romaji, or this composition already
    /// showed pinyin (a word was looked up, or chosen from it). "ian" alone is
    /// not enough, since Japanese spells it across syllables (shianwo → 思案を).
    /// Every character of the word must be typed in pinyin; mixed spellings
    /// of a fragment are too loose a guess.
    static func prefixMatches(for input: String, evidence: Evidence, pinyinContext: Bool,
                              lookup: PinyinKanjiLookup) -> [PinyinKanjiLookup.Match] {
        guard evidence.notRomaji || pinyinContext else { return [] }
        let matches = lookup.prefixMatches(for: input).filter { $0.parts.allSatisfy { $0.mode == .pinyin } }
        guard let longest = matches.first?.letterCount else { return [] }
        return matches.filter { $0.letterCount == longest }
    }

    /// Selecting the word commits its surface. It ends the composition, or
    /// for a beginning of the letters (`consumed`), leaves `remaining`. It
    /// carries no dictionary data and is no learning target: its reading is
    /// not the typed kana, so Japanese learning would pair the wrong reading.
    static func snapshot(surface: String, reading: String, composing: ComposingText,
                         consumed: Int? = nil, remaining: ComposingText = ComposingText(), revision: Int,
                         queryReading: String, rank: Int) -> CandidateSnapshot {
        let consumed = consumed ?? composing.input.count
        let candidate = Candidate(text: surface, value: .zero, composingCount: .inputCount(consumed),
            lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false)
        return CandidateSnapshot(candidate: candidate, revision: revision, source: .pinyinLookup,
            remainingComposition: remaining, originalInputCount: composing.input.count,
            consumedInputCount: consumed, queryReading: queryReading,
            engineRank: 1000 + rank, readingOverride: reading, predictionStatus: false)
    }
}
