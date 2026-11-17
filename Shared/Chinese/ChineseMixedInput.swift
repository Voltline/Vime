import Foundation

/// Input with letters no pinyin reading takes, such as an English word in a
/// sentence (wozaixiugaivimedepeizhi): Rime stops converting at the first such
/// letter and leaves the rest as typed. Here those letters stay as typed and
/// the pinyin around them converts on its own, so the sentence goes on after
/// the word. Where a word ends is a guess (vime|de or vi|mede), so every
/// likely end is a split, and the model picks one.
nonisolated enum ChineseMixedInput {
    enum Segment: Equatable, Sendable {
        /// Pinyin Rime converts.
        case pinyin(String)
        /// Letters kept as typed.
        case raw(String)

        var hasCapital: Bool { if case .raw(let letters) = self { letters.contains(where: \.isUppercase) } else { false } }
    }

    /// One way to read the whole input, as shown and as weighed.
    struct Option: Sendable {
        let segments: [Segment]
        let text: String
        let genuine: String
    }

    /// Longest kept word, and how far before the first letter no pinyin
    /// takes it may start.
    static let longestRaw = 12
    static let reachBack = 4
    /// Kept words in one input.
    static let mostRaw = 3
    static let splitLimit = 16
    static let shownOptions = 3

    /// Ways to keep runs of letters as typed so the rest reads as pinyin,
    /// likeliest first by spelling alone; empty when the whole input reads as
    /// pinyin (initials typed alone included) or holds anything but a–z.
    static func splits(for input: String) -> [[Segment]] {
        let letters = Array(input)
        guard !letters.isEmpty, letters.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) else { return [] }
        let found: [[Segment]]
        if letters.contains(where: \.isUppercase) {
            found = capitalSplits(letters[...], abbreviated: true)
        } else {
            guard !readable(letters[...], abbreviated: true) else { return [] }
            found = splits(letters[...], depth: mostRaw, abbreviated: true)
        }
        // Stable: equal splits keep the order they were found in.
        return found.enumerated().sorted {
            let (a, b) = (penalty($0.element), penalty($1.element))
            return a == b ? $0.offset < $1.offset : a < b
        }.prefix(splitLimit).map(\.element)
    }

    /// Abbreviations (wsm for 为什么) read only before the first kept word,
    /// the part Rime itself converted; after it, nearly any letters would
    /// read as some abbreviation, so the pinyin there is spelled out.
    private static func splits(_ letters: ArraySlice<Character>, depth: Int, abbreviated: Bool = false) -> [[Segment]] {
        if readable(letters, abbreviated: abbreviated) { return letters.isEmpty ? [[]] : [[.pinyin(String(letters))]] }
        guard depth > 0 else { return [] }
        // The first letter no reading of what comes before it takes.
        let base = letters.startIndex
        guard let stuck = (base + 1...letters.endIndex).first(where: { !readable(letters[base..<$0], abbreviated: abbreviated) }).map({ $0 - 1 })
        else { return [] }
        // The kept word starts after a full syllable shortly before it
        // (bu|gshi or |bugshi), the latest first, or right where the
        // pinyin stops after an abbreviation (wsm|vime).
        let starts = (max(base, stuck - reachBack)...stuck).reversed().filter {
            let head = letters[base..<$0]
            if $0 == base || PinyinSpellingCorrection.isFullSyllables(String(head)) { return true }
            return abbreviated && (pieces(head).endsOnSyllable || ($0 == stuck && readable(head, abbreviated: true)))
        }
        var found: [[Segment]] = []
        for start in starts {
            let head: [Segment] = start == base ? [] : [.pinyin(String(letters[base..<start]))]
            for end in (stuck + 1)...min(letters.endIndex, start + longestRaw) {
                let raw = Segment.raw(String(letters[start..<end]))
                for rest in splits(letters[end...], depth: depth - 1) {
                    // A kept word never runs into the next one.
                    if case .raw? = rest.first { continue }
                    found.append(head + [raw] + rest)
                }
            }
        }
        return found
    }

    /// A capital is never pinyin: it starts a word kept as typed, with the
    /// capitals after it and the lowercase letters it runs on into (Vime,
    /// iPhone's Phone), and the pinyin around it converts. Where the
    /// word ends is a guess again, the shortest first (Vime|dazi before
    /// Vimeda|zi); a capital after lowercase letters starts the next word.
    private static func capitalSplits(_ letters: ArraySlice<Character>, abbreviated: Bool) -> [[Segment]] {
        let base = letters.startIndex
        guard let capital = letters.firstIndex(where: \.isUppercase) else {
            if letters.isEmpty { return [[]] }
            return splits(letters, depth: 2, abbreviated: abbreviated)
        }
        let heads: [[Segment]]
        if capital == base {
            heads = [[]]
        } else {
            let found = splits(letters[base..<capital], depth: 2, abbreviated: abbreviated)
            heads = found.isEmpty ? [[.raw(String(letters[base..<capital]))]] : found
        }
        var shortest = capital
        while shortest < letters.endIndex, letters[shortest].isUppercase { shortest += 1 }
        let next = letters[shortest...].firstIndex(where: \.isUppercase) ?? letters.endIndex
        // A run of capitals (GPT, PDF) is the word whole; one capital runs on.
        let longest = shortest - capital > 1 ? shortest : min(next, shortest + longestRaw)
        var found: [[Segment]] = []
        for end in shortest...max(shortest, longest) {
            // Lowercase letters right after the word belong to it, unless
            // all of them up to the next capital read as pinyin.
            let between = letters[end..<next]
            guard between.isEmpty || readable(between, abbreviated: false) else { continue }
            let pinyin: [Segment] = between.isEmpty ? [] : [.pinyin(String(between))]
            let word = Segment.raw(String(letters[capital..<end]))
            for rest in next == letters.endIndex ? [[]] : capitalSplits(letters[next...], abbreviated: false) {
                for head in heads { found.append(joined(head + [word] + pinyin + rest)) }
            }
        }
        return found
    }

    /// Kept words side by side read as one (Mc and Donald).
    private static func joined(_ segments: [Segment]) -> [Segment] {
        segments.reduce(into: []) { result, segment in
            if case .raw(let letters) = segment, case .raw(let before)? = result.last {
                result[result.count - 1] = .raw(before + letters)
            } else {
                result.append(segment)
            }
        }
    }

    /// The pinyin to look up for `splits`, each once.
    static func spellings(for splits: [[Segment]]) -> [String] {
        var seen: Set<String> = []
        return splits.flatMap { $0 }.compactMap {
            if case .pinyin(let spelling) = $0, seen.insert(spelling).inserted { spelling } else { nil }
        }
    }

    /// Each split whose pinyin Rime converts whole, with Rime's best reading of it.
    static func options(_ splits: [[Segment]], converted: [(spelling: String, candidates: [RimeCandidate])]) -> [Option] {
        var best: [String: RimeCandidate] = [:]
        for (spelling, candidates) in converted where best[spelling] == nil {
            best[spelling] = candidates.first(where: \.coversInput)
        }
        var seen: Set<String> = []
        return splits.compactMap { segments in
            var text = "", genuine = ""
            for segment in segments {
                switch segment {
                case .raw(let letters): text += letters; genuine += letters
                case .pinyin(let spelling):
                    guard let candidate = best[spelling] else { return nil }
                    text += candidate.text; genuine += candidate.genuine
                }
            }
            guard seen.insert(text).inserted else { return nil }
            return Option(segments: segments, text: text, genuine: genuine)
        }
    }

    /// Options in the model's order, likeliest first; without scores, as they are.
    static func ranked(_ options: [Option], scores: [Double]?) -> [Option] {
        guard let scores, scores.count == options.count else { return options }
        return options.indices.sorted {
            let (a, b) = (scores[$0], scores[$1])
            return a == b ? $0 < $1 : a > b
        }.map { options[$0] }
    }

    /// How unlike a typed word and the pinyin after it a split looks, for
    /// when the model cannot weigh them: words seldom end in i or u, and
    /// pinyin after a word seldom starts with a bare vowel (vim|e, vi|me);
    /// pinyin between words is seldom abbreviated (git|hub|shang, not gi|t|hub).
    /// Ties keep the order found, the latest start first.
    private static func penalty(_ segments: [Segment]) -> Int {
        segments.indices.reduce(0) { total, index in
            if case .pinyin(let spelling) = segments[index] {
                // Pinyin between words, or cut short right after one
                // a capital's word (McDonal|d), is seldom what was meant.
                let between = index > 0 && (index + 1 < segments.count || segments[index - 1].hasCapital)
                return between && !PinyinSpellingCorrection.isFullSyllables(spelling) ? total + 1 : total
            }
            guard case .raw(let letters) = segments[index] else { return total }
            var cost = total
            // A word seldom starts on letters pinyin could take: just after an
            // initial typed alone (kanyixiag|ithub), or first where the input
            // could start as pinyin (wsmvime).
            if index > 0, case .pinyin(let before) = segments[index - 1],
               !PinyinSpellingCorrection.isFullSyllables(before) { cost += 1 }
            if index == 0, let first = letters.first, syllableStarts.contains(String(first)) { cost += 1 }
            if let last = letters.last, last.isLowercase, "iuv".contains(last) { cost += 1 }
            if index + 1 < segments.count, case .pinyin(let next) = segments[index + 1],
               let first = next.first, "aeo".contains(first) { cost += 1 }
            return cost
        }
    }

    /// Whether `letters` reads as pinyin: full syllables, then perhaps the
    /// start of one more (an initial typed alone, or a syllable half typed).
    /// Abbreviated, any syllable may be cut to its start, as Rime reads them.
    private static func readable(_ letters: ArraySlice<Character>, abbreviated: Bool) -> Bool {
        let text = String(letters)
        if text.isEmpty || PinyinSpellingCorrection.isFullSyllables(text) { return true }
        if abbreviated { return pieces(letters).reads }
        // Full syllables, then perhaps the start of one more.
        for cut in 1...min(5, text.count) {
            let head = String(text.dropLast(cut)), tail = String(text.suffix(cut))
            guard head.isEmpty || PinyinSpellingCorrection.isFullSyllables(head) else { continue }
            if syllableStarts.contains(tail) { return true }
        }
        return false
    }

    /// Every start of a syllable, the abbreviations Rime accepts among them.
    private static let syllableStarts: Set<String> = Set(PinyinSpellingCorrection.syllables.flatMap { syllable in
        (1...syllable.count).map { String(syllable.prefix($0)) }
    })

    /// Whether `letters` splits into syllable starts, and whether one such
    /// split ends on a full syllable.
    private static func pieces(_ letters: ArraySlice<Character>) -> (reads: Bool, endsOnSyllable: Bool) {
        let text = Array(letters)
        var reach = [true] + Array(repeating: false, count: text.count)
        var full = [false] + Array(repeating: false, count: text.count)
        for end in 1...max(1, text.count) where end <= text.count {
            for start in max(0, end - 6)..<end where reach[start] {
                let piece = String(text[start..<end])
                guard syllableStarts.contains(piece) else { continue }
                reach[end] = true
                if PinyinSpellingCorrection.syllables.contains(piece) { full[end] = true }
            }
        }
        return (reach[text.count], full[text.count])
    }
}
