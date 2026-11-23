/// A lone syllable that starts with a vowel and also starts with a shorter
/// one: ei is e then i, en is e then n, ang is an then g. Rime keeps only the
/// whole syllable, which has few characters of its own, so the keyboard
/// looks the split up too and lists it after them.
nonisolated enum PinyinVowelSplit {
    /// `input` with a syllable break after the longest shorter syllable it
    /// starts with, or nil when it is not one vowel-led syllable.
    static func spelling(for input: String) -> String? {
        guard input.count >= 2, let first = input.first, "aeo".contains(first),
              PinyinSpellingCorrection.syllables.contains(input) else { return nil }
        let leading = (1..<input.count).reversed().lazy.map { String(input.prefix($0)) }
            .first { PinyinSpellingCorrection.syllables.contains($0) }
        guard let leading else { return nil }
        return leading + "'" + input.dropFirst(leading.count)
    }
}
