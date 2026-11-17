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
        guard !letters.isEmpty, letters.allSatisfy({ ("a"..."z").contains($0) }),
              !readable(letters[...]) else { return [] }
        let found = splits(letters[...], depth: mostRaw)
        // Stable: equal splits keep the order they were found in.
        return found.enumerated().sorted {
            let (a, b) = (penalty($0.element), penalty($1.element))
            return a == b ? $0.offset < $1.offset : a < b
        }.prefix(splitLimit).map(\.element)
    }

    private static func splits(_ letters: ArraySlice<Character>, depth: Int) -> [[Segment]] {
        if readable(letters) { return letters.isEmpty ? [[]] : [[.pinyin(String(letters))]] }
        guard depth > 0 else { return [] }
        // The first letter no reading of what comes before it takes.
        let base = letters.startIndex
        guard let stuck = (base + 1...letters.endIndex).first(where: { !readable(letters[base..<$0]) }).map({ $0 - 1 })
        else { return [] }
        // The kept word starts after a full syllable shortly before it
        // (bu|gshi or |bugshi), the latest first.
        let starts = (max(base, stuck - reachBack)...stuck).reversed().filter {
            PinyinSpellingCorrection.isFullSyllables(String(letters[base..<$0]))
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
    /// pinyin after a word seldom starts with a bare vowel (vim|e, vi|me).
    private static func penalty(_ segments: [Segment]) -> Int {
        segments.indices.reduce(0) { total, index in
            guard case .raw(let letters) = segments[index] else { return total }
            var cost = total
            if let last = letters.last, "iuv".contains(last) { cost += 1 }
            if index + 1 < segments.count, case .pinyin(let next) = segments[index + 1],
               let first = next.first, "aeo".contains(first) { cost += 1 }
            return cost
        }
    }

    /// Whether `letters` reads as pinyin: full syllables, then perhaps the
    /// start of one more (an initial typed alone, or a syllable half typed).
    private static func readable(_ letters: ArraySlice<Character>) -> Bool {
        let text = String(letters)
        if text.isEmpty || PinyinSpellingCorrection.isFullSyllables(text) { return true }
        for cut in 1...min(5, text.count) {
            let head = String(text.dropLast(cut)), tail = String(text.suffix(cut))
            guard head.isEmpty || PinyinSpellingCorrection.isFullSyllables(head) else { continue }
            if PinyinSpellingCorrection.syllables.contains(where: { $0.hasPrefix(tail) }) { return true }
        }
        return false
    }
}
