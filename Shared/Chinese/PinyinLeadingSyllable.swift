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
        var remaining = syllable.count
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
}
