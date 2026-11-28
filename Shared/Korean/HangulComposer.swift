import Foundation

/// Pure value-type Hangul 2-beolsik (두벌식) composition state machine.
///
/// Produces Unicode precomposed syllables (`U+AC00...U+D7A3`) and compatibility
/// jamo (`U+3131...U+318E`) for standalone letters, with zero UIKit dependency.
///
/// Tracks an entire composing word (completed syllables + active composing syllable)
/// so the session can keep the word underlined as marked text for completion and
/// jamo-level error correction. Backspace unrolls the active syllable jamo-by-jamo
/// (`닭 → 달 → 다 → ㄷ`), and removes earlier completed syllables one syllable at a time.
nonisolated struct HangulComposer: Equatable, Sendable {
    // MARK: - Unicode Hangul Tables

    static let syllableBase: UInt32 = 0xAC00
    static let syllableEnd: UInt32 = 0xD7A3
    static let jungseongCount: UInt32 = 21
    static let jongseongCount: UInt32 = 28

    /// 19 choseong (initial consonants), in Unicode syllable order (0...18).
    static let choseong: [Character] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
    ]

    /// 21 jungseong (medial vowels), in Unicode syllable order (0...20).
    static let jungseong: [Character] = [
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ",
        "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ", "ㅣ"
    ]

    /// 28 jongseong (final consonants; index 0 is empty), in Unicode syllable order (0...27).
    static let jongseong: [Character?] = [
        nil, "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ",
        "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
    ]

    static let choseongIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: choseong.enumerated().map { ($0.element, $0.offset) }
    )

    static let jungseongIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: jungseong.enumerated().map { ($0.element, $0.offset) }
    )

    static let jongseongIndex: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (index, ch) in jongseong.enumerated() where ch != nil {
            map[ch!] = index
        }
        return map
    }()

    /// Compound vowels: (firstJungseongIndex, secondJungseongIndex) -> combinedJungseongIndex.
    static let compoundVowel: [Int: [Int: Int]] = [
        8: [0: 9, 1: 10, 20: 11],   // ㅗ + ㅏ=ㅘ, ㅐ=ㅙ, ㅣ=ㅚ
        13: [4: 14, 5: 15, 20: 16], // ㅜ + ㅓ=ㅝ, ㅔ=ㅞ, ㅣ=ㅟ
        18: [20: 19]                // ㅡ + ㅣ=ㅢ
    ]

    /// Split of a compound vowel back into (firstJungseongIndex, secondJungseongIndex).
    static let splitCompoundVowel: [Int: (Int, Int)] = [
        9: (8, 0),   // ㅘ -> ㅗ, ㅏ
        10: (8, 1),  // ㅙ -> ㅗ, ㅐ
        11: (8, 20), // ㅚ -> ㅗ, ㅣ
        14: (13, 4), // ㅝ -> ㅜ, ㅓ
        15: (13, 5), // ㅞ -> ㅜ, ㅔ
        16: (13, 20),// ㅟ -> ㅜ, ㅣ
        19: (18, 20) // ㅢ -> ㅡ, ㅣ
    ]

    /// Compound jongseong: (firstJongseongIndex, secondChoseongIndex) -> combinedJongseongIndex.
    /// Second component is keyed by choseong index so spillover to the next syllable is direct.
    static let compoundJongseong: [Int: [Int: Int]] = [
        1: [9: 3],                                  // ㄱ + ㅅ = ㄳ
        4: [12: 5, 18: 6],                          // ㄴ + ㅈ = ㄵ, ㅎ = ㄶ
        8: [0: 9, 6: 10, 7: 11, 9: 12, 16: 13, 17: 14, 18: 15], // ㄹ + ㄱ,ㅁ,ㅂ,ㅅ,ㅌ,ㅍ,ㅎ
        17: [9: 18]                                 // ㅂ + ㅅ = ㅄ
    ]

    /// Split of a compound jongseong into (firstJongseongIndex, secondChoseongIndex).
    static let splitCompoundJongseong: [Int: (firstJong: Int, secondCho: Int)] = [
        3: (1, 9),   // ㄳ -> ㄱ, ㅅ
        5: (4, 12),  // ㄵ -> ㄴ, ㅈ
        6: (4, 18),  // ㄶ -> ㄴ, ㅎ
        9: (8, 0),   // ㄺ -> ㄹ, ㄱ
        10: (8, 6),  // ㄻ -> ㄹ, ㅁ
        11: (8, 7),  // ㄼ -> ㄹ, ㅂ
        12: (8, 9),  // ㄽ -> ㄹ, ㅅ
        13: (8, 16), // ㄾ -> ㄹ, ㅌ
        14: (8, 17), // ㄿ -> ㄹ, ㅍ
        15: (8, 18), // ㅀ -> ㄹ, ㅎ
        18: (17, 9)  // ㅄ -> ㅂ, ㅅ
    ]

    /// Maps a simple jongseong index to its equivalent choseong index for spillover.
    static let jongseongToChoseong: [Int: Int] = {
        var map: [Int: Int] = [:]
        for (jongIdx, ch) in jongseong.enumerated() {
            if let ch, let choIdx = choseongIndex[ch] {
                map[jongIdx] = choIdx
            }
        }
        return map
    }()

    // MARK: - Active Syllable State

    enum ActiveSyllable: Equatable, Sendable {
        case consonant(cho: Int)
        case vowel(jung: Int)
        case syllable(cho: Int, jung: Int, jong: Int)

        var rendered: String {
            switch self {
            case .consonant(let cho):
                return String(HangulComposer.choseong[cho])
            case .vowel(let jung):
                return String(HangulComposer.jungseong[jung])
            case .syllable(let cho, let jung, let jong):
                return String(HangulComposer.compose(cho: cho, jung: jung, jong: jong))
            }
        }
    }

    /// Completed syllables within the current composing word (kept in marked text).
    private(set) var committedSyllables: [String] = []
    /// Currently active composing syllable at the tail of the word.
    private(set) var active: ActiveSyllable?

    var isEmpty: Bool { committedSyllables.isEmpty && active == nil }

    /// Full rendered text of the current composing word.
    var text: String {
        var result = committedSyllables.joined()
        if let active { result += active.rendered }
        return result
    }

    /// Decomposed 2-beolsik jamo sequence for the current composing word.
    var jamos: [Character] {
        Self.decomposeToJamo(text)
    }

    /// Whether the active syllable currently expects a vowel, consonant, or either.
    /// Used by the hit-correction prior.
    var activeState: ActiveSyllable? { active }

    // MARK: - Composition Operations

    /// Feeds one Hangul compatibility jamo (consonant or vowel).
    /// Returns `true` if the character was accepted as Hangul jamo, `false` otherwise.
    @discardableResult
    mutating func input(_ jamo: Character) -> Bool {
        if let cho = Self.choseongIndex[jamo] {
            inputConsonant(cho, jamo: jamo)
            return true
        }
        if let jung = Self.jungseongIndex[jamo] {
            inputVowel(jung)
            return true
        }
        return false
    }

    /// Feeds a string of one or more Hangul jamo. Returns `false` if any character is non-jamo.
    @discardableResult
    mutating func input(string: String) -> Bool {
        guard !string.isEmpty else { return false }
        for ch in string {
            guard Self.choseongIndex[ch] != nil || Self.jungseongIndex[ch] != nil else { return false }
        }
        for ch in string { _ = input(ch) }
        return true
    }

    private mutating func inputConsonant(_ cho: Int, jamo: Character) {
        guard let current = active else {
            active = .consonant(cho: cho)
            return
        }
        switch current {
        case .consonant:
            // Matches iOS system 2-Set: standalone consonants stay separate (e.g. ㄱ+ㅅ -> ㄱㅅ, ㄹ+ㄱ -> ㄹㄱ).
            committedSyllables.append(current.rendered)
            active = .consonant(cho: cho)

        case .vowel:
            committedSyllables.append(current.rendered)
            active = .consonant(cho: cho)

        case .syllable(let curCho, let curJung, let curJong):
            if curJong == 0 {
                if let jong = Self.jongseongIndex[jamo] {
                    active = .syllable(cho: curCho, jung: curJung, jong: jong)
                } else {
                    // ㄸ, ㅃ, ㅉ cannot serve as jongseong.
                    committedSyllables.append(current.rendered)
                    active = .consonant(cho: cho)
                }
            } else if let combined = Self.compoundJongseong[curJong]?[cho] {
                active = .syllable(cho: curCho, jung: curJung, jong: combined)
            } else {
                committedSyllables.append(current.rendered)
                active = .consonant(cho: cho)
            }
        }
    }

    private mutating func inputVowel(_ jung: Int) {
        guard let current = active else {
            active = .vowel(jung: jung)
            return
        }
        switch current {
        case .consonant(let curCho):
            active = .syllable(cho: curCho, jung: jung, jong: 0)

        case .vowel(let curJung):
            // Matches iOS system 2-Set: standalone vowels combine into compound vowels (e.g. ㅗ+ㅏ -> ㅘ).
            if let combined = Self.compoundVowel[curJung]?[jung] {
                active = .vowel(jung: combined)
            } else {
                committedSyllables.append(current.rendered)
                active = .vowel(jung: jung)
            }

        case .syllable(let curCho, let curJung, let curJong):
            if curJong == 0 {
                if let combined = Self.compoundVowel[curJung]?[jung] {
                    active = .syllable(cho: curCho, jung: combined, jong: 0)
                } else {
                    committedSyllables.append(current.rendered)
                    active = .vowel(jung: jung)
                }
            } else if let (firstJong, secondCho) = Self.splitCompoundJongseong[curJong] {
                // Compound jongseong splits: 닭 + ㅏ -> 달가.
                committedSyllables.append(String(Self.compose(cho: curCho, jung: curJung, jong: firstJong)))
                active = .syllable(cho: secondCho, jung: jung, jong: 0)
            } else if let nextCho = Self.jongseongToChoseong[curJong] {
                // Simple jongseong spills over as next choseong: 각 + ㅏ -> 가가.
                committedSyllables.append(String(Self.compose(cho: curCho, jung: curJung, jong: 0)))
                active = .syllable(cho: nextCho, jung: jung, jong: 0)
            } else {
                committedSyllables.append(current.rendered)
                active = .vowel(jung: jung)
            }
        }
    }

    /// Backspace: unrolls the active syllable jamo-by-jamo (`닭 → 달 → 다 → ㄷ → nil`),
    /// or removes the last completed syllable in the word when no active syllable remains.
    /// Returns `true` if something in the composing buffer was deleted, `false` if already empty.
    @discardableResult
    mutating func backspace() -> Bool {
        if let current = active {
            switch current {
            case .consonant:
                active = nil
            case .vowel(let jung):
                if let (firstJung, _) = Self.splitCompoundVowel[jung] {
                    active = .vowel(jung: firstJung)
                } else {
                    active = nil
                }
            case .syllable(let cho, let jung, let jong):
                if jong != 0 {
                    if let (firstJong, _) = Self.splitCompoundJongseong[jong] {
                        active = .syllable(cho: cho, jung: jung, jong: firstJong)
                    } else {
                        active = .syllable(cho: cho, jung: jung, jong: 0)
                    }
                } else if let (firstJung, _) = Self.splitCompoundVowel[jung] {
                    active = .syllable(cho: cho, jung: firstJung, jong: 0)
                } else {
                    active = .consonant(cho: cho)
                }
            }
            return true
        }
        if !committedSyllables.isEmpty {
            committedSyllables.removeLast()
            return true
        }
        return false
    }

    /// Flushes and clears the composing buffer, returning its rendered text.
    mutating func flush() -> String {
        let result = text
        committedSyllables.removeAll()
        active = nil
        return result
    }

    mutating func clear() {
        committedSyllables.removeAll()
        active = nil
    }

    // MARK: - Static Utilities

    static func compose(cho: Int, jung: Int, jong: Int) -> Character {
        let code = syllableBase + (UInt32(cho) * jungseongCount + UInt32(jung)) * jongseongCount + UInt32(jong)
        return Character(Unicode.Scalar(code)!)
    }

    static func isHangulSyllable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= syllableBase && scalar.value <= syllableEnd
    }

    static func isCompatibilityJamo(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x3131 && scalar.value <= 0x318E
    }

    static func isHangul(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { isHangulSyllable($0) || isCompatibilityJamo($0) }
    }

    /// Whether the final character of `word` has a batchim (jongseong).
    /// Returns `nil` if `word` does not end in a precomposed Hangul syllable.
    static func hasBatchim(_ word: String) -> Bool? {
        guard let last = word.unicodeScalars.last, isHangulSyllable(last) else { return nil }
        return (last.value - syllableBase) % jongseongCount != 0
    }

    /// Whether the final character of `word` has a `ㄹ` batchim (needed for `으로/로`).
    static func hasRieulBatchim(_ word: String) -> Bool {
        guard let last = word.unicodeScalars.last, isHangulSyllable(last) else { return false }
        return (last.value - syllableBase) % jongseongCount == 8
    }

    /// Decomposes any Hangul text into a flat sequence of 2-beolsik input jamo
    /// (splitting compound vowels and compound jongseong into their component keys).
    static func decomposeToJamo(_ text: String) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(text.count * 3)
        for scalar in text.unicodeScalars {
            if isHangulSyllable(scalar) {
                let offset = Int(scalar.value - syllableBase)
                let cho = offset / Int(jungseongCount * jongseongCount)
                let jung = (offset % Int(jungseongCount * jongseongCount)) / Int(jongseongCount)
                let jong = offset % Int(jongseongCount)
                result.append(choseong[cho])
                if let (v1, v2) = splitCompoundVowel[jung] {
                    result.append(jungseong[v1])
                    result.append(jungseong[v2])
                } else {
                    result.append(jungseong[jung])
                }
                if jong != 0 {
                    if let (j1, c2) = splitCompoundJongseong[jong] {
                        if let first = jongseong[j1] { result.append(first) }
                        result.append(choseong[c2])
                    } else if let final = jongseong[jong] {
                        result.append(final)
                    }
                }
            } else {
                let ch = Character(scalar)
                if let jong = jongseongIndex[ch], let (j1, c2) = splitCompoundJongseong[jong] {
                    if let first = jongseong[j1] { result.append(first) }
                    result.append(choseong[c2])
                } else if let jung = jungseongIndex[ch], let (v1, v2) = splitCompoundVowel[jung] {
                    result.append(jungseong[v1])
                    result.append(jungseong[v2])
                } else {
                    result.append(ch)
                }
            }
        }
        return result
    }

    /// Re-composes a sequence of 2-beolsik jamo into rendered Hangul text.
    static func composeFromJamo(_ jamos: [Character]) -> String {
        var composer = HangulComposer()
        for jamo in jamos {
            if !composer.input(jamo) {
                // Preserve non-jamo scalars if any appear.
                let prefix = composer.flush()
                return prefix + String(jamo)
            }
        }
        return composer.text
    }
}
