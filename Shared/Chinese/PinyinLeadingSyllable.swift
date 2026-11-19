/// The syllable the open pinyin input starts with, which the expanded panel
/// lets the user pick (xian as xian, xia or xi). Picking one puts a syllable
/// break after it, so Rime lists what starts with that syllable; choosing a
/// candidate then takes it off the front as any partial choice does.
nonisolated enum PinyinLeadingSyllable {
    /// No pinyin syllable is longer.
    static let longest = 6

    /// The syllables `letters` can start with, longest first. Each leaves
    /// letters another syllable can start (not i, u or v), and has a vowel,
    /// so a lone n or m is not offered.
    static func options(for letters: String) -> [String] {
        let letters = Array(letters.lowercased())
        guard letters.allSatisfy({ ("a"..."z").contains($0) }) else { return [] }
        return (1...max(1, min(longest, letters.count))).reversed().compactMap { length in
            guard length <= letters.count else { return nil }
            let syllable = String(letters[..<length])
            guard PinyinSpellingCorrection.syllables.contains(syllable),
                  syllable.contains(where: { "aeiouv".contains($0) }) else { return nil }
            if length < letters.count, "iuv".contains(letters[length]) { return nil }
            return syllable
        }
    }

    /// `input` with a syllable break after its first `syllable.count`
    /// letters, which must spell `syllable`. Breaks typed later stay.
    static func input(_ input: String, leadingWith syllable: String) -> String {
        Self.input(input, replacing: syllable.count, with: syllable)
    }

    /// `input` with its first `count` letters spelled as `syllable` and a
    /// syllable break after them. Breaks typed later stay.
    static func input(_ input: String, replacing count: Int, with syllable: String) -> String {
        var remaining = count
        var rest = Substring(input)
        while remaining > 0, let first = rest.first {
            if first != "'" { remaining -= 1 }
            rest = rest.dropFirst()
        }
        rest = rest.drop { $0 == "'" }
        return rest.isEmpty ? syllable : syllable + "'" + rest
    }

    /// The first syllable of a preedit's letters (Rime spaces them), or nil
    /// when it starts with chosen text.
    static func first(ofPreedit preedit: String) -> String? {
        let token = preedit.split(whereSeparator: { $0 == " " || $0 == "'" }).first.map(String.init)
        guard let token, !token.isEmpty, token.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        return token
    }

    /// Other syllables `syllable` may have been meant as, which the column
    /// offers as corrections: fuzzy sounds (z/zh, n/l, an/ang…) first, then
    /// one letter swapped for a neighbouring key, nearest keys first.
    static func alternatives(to syllable: String, excluding: Set<String>, limit: Int = 4) -> [String] {
        var found: [String] = []
        var seen = excluding.union([syllable])
        func add(_ spelling: String) {
            guard found.count < limit, PinyinSpellingCorrection.syllables.contains(spelling),
                  spelling.contains(where: { "aeiouv".contains($0) }), seen.insert(spelling).inserted else { return }
            found.append(spelling)
        }
        let initial = ["zh", "ch", "sh"].first { syllable.hasPrefix($0) } ?? String(syllable.prefix(1))
        for swap in fuzzyInitials[initial] ?? [] { add(swap + syllable.dropFirst(initial.count)) }
        for (long, short) in [("ang", "an"), ("eng", "en"), ("ing", "in")] {
            if syllable.hasSuffix(long) { add(String(syllable.dropLast())) }
            else if syllable.hasSuffix(short) { add(syllable + "g") }
        }
        let letters = Array(syllable)
        var swaps: [(rank: Int, spelling: String)] = []
        for (index, letter) in letters.enumerated() {
            for (rank, neighbour) in PinyinSpellingCorrection.neighbours(of: letter).enumerated() {
                var changed = letters
                changed[index] = neighbour
                swaps.append((rank, String(changed)))
            }
        }
        for swap in swaps.enumerated().sorted(by: { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }) {
            add(swap.element.spelling)
        }
        return found
    }

    private static let fuzzyInitials: [String: [String]] = [
        "zh": ["z"], "z": ["zh"], "ch": ["c"], "c": ["ch"], "sh": ["s"], "s": ["sh"],
        "n": ["l"], "l": ["n", "r"], "r": ["l"], "f": ["h"], "h": ["f"],
    ]
}
