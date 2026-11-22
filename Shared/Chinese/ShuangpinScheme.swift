/// 双拼: each syllable typed as two keys, its initial (zh, ch, sh on v, i, u)
/// and the key of its final in the scheme. A syllable without an initial
/// types its first letter, then its last letter (ai, ou) or its final's key
/// (ang -> ah); a single vowel is doubled (a -> aa). One key reads as the
/// initial alone. Scripts/generate_pinyin_algebra.py builds the Rime schemas
/// (vime_shuangpin_<scheme>) from the same tables.
nonisolated enum ShuangpinScheme: String, CaseIterable, Sendable {
    /// 小鹤双拼
    case flypy
    /// 自然码
    case ziranma

    var schema: String { "vime_shuangpin_" + rawValue }

    /// The key of each final.
    var finals: [String: Character] {
        switch self {
        case .flypy: Self.flypyFinals
        case .ziranma: Self.ziranmaFinals
        }
    }

    private static let flypyFinals: [String: Character] = [
        "iu": "q", "ei": "w", "uan": "r", "van": "r", "ue": "t", "ve": "t", "un": "y", "vn": "y",
        "uo": "o", "ie": "p", "ong": "s", "iong": "s", "ai": "d", "en": "f", "eng": "g", "ang": "h",
        "an": "j", "ing": "k", "uai": "k", "iang": "l", "uang": "l", "ou": "z", "ia": "x", "ua": "x",
        "ao": "c", "ui": "v", "v": "v", "in": "b", "iao": "n", "ian": "m",
    ]

    private static let ziranmaFinals: [String: Character] = [
        "iu": "q", "ia": "w", "ua": "w", "uan": "r", "van": "r", "ue": "t", "ve": "t", "ing": "y",
        "uai": "y", "uo": "o", "un": "p", "vn": "p", "ong": "s", "iong": "s", "iang": "d", "uang": "d",
        "en": "f", "eng": "g", "ang": "h", "an": "j", "ao": "k", "ai": "l", "ei": "z", "ie": "x",
        "iao": "c", "ui": "v", "v": "v", "ou": "b", "in": "n", "ian": "m",
    ]

    private static let initialKeys: [String: Character] = ["zh": "v", "ch": "i", "sh": "u"]

    /// The two keys that type `syllable`, or nil for one the scheme lacks.
    func code(for syllable: String) -> String? {
        guard let first = syllable.first else { return nil }
        let initial = ["zh", "ch", "sh"].first { syllable.hasPrefix($0) } ?? ("aoe".contains(first) ? nil : String(first))
        guard let initial else {
            switch syllable.count {
            case 1: return syllable + syllable
            case 2: return syllable
            default:
                let final = String(syllable.dropFirst())
                guard let key = finals[final] ?? finals[syllable] else { return nil }
                return String(first) + String(key)
            }
        }
        let final = String(syllable.dropFirst(initial.count))
        let initialKey = Self.initialKeys[initial] ?? Character(initial)
        if final.count == 1 { return String(initialKey) + final }
        guard let key = finals[final] else { return nil }
        return String(initialKey) + String(key)
    }

    /// The syllable two keys type; luo for the code lo and luo share.
    func syllable(for code: String) -> String? { syllables[code] }

    private var syllables: [String: String] {
        switch self {
        case .flypy: Self.flypySyllables
        case .ziranma: Self.ziranmaSyllables
        }
    }

    private static let flypySyllables = table(.flypy)
    private static let ziranmaSyllables = table(.ziranma)

    private static func table(_ scheme: ShuangpinScheme) -> [String: String] {
        var table: [String: String] = [:]
        for syllable in PinyinSpellingCorrection.syllables.sorted()
        where syllable.contains(where: { "aeiouv".contains($0) }) {
            guard let code = scheme.code(for: syllable), table[code] == nil || syllable == "luo" else { continue }
            table[code] = syllable
        }
        return table
    }

    /// The pinyin a key or two of Rime's preedit stand for: a syllable for
    /// two keys, the initial for one, and keys it cannot read as typed.
    func reading(of keys: String) -> String {
        switch keys.count {
        case 2: return syllable(for: keys) ?? keys
        case 1: return Self.initialKeys.first { String($0.value) == keys }?.key ?? keys
        default: return keys
        }
    }

    /// Rime's preedit (keys, a space after each syllable) read as pinyin.
    func readings(ofPreedit preedit: String) -> [String] {
        preedit.split(whereSeparator: { $0 == " " || $0 == "'" }).map { reading(of: String($0)) }
    }

    /// The pinyin letters of typed keys, two a syllable and a last lone key
    /// as its initial; nil when a pair is no syllable.
    func pinyin(ofKeys keys: String) -> String? {
        var result = ""
        for piece in keys.split(separator: "'") {
            var rest = Substring(piece)
            while !rest.isEmpty {
                let pair = String(rest.prefix(2))
                if pair.count == 1 { result += reading(of: pair); break }
                guard let syllable = syllable(for: pair) else { return nil }
                result += syllable
                rest = rest.dropFirst(2)
            }
        }
        return result
    }

    /// What each letter key shows under its letter: the initial it types,
    /// then its finals.
    var keyHints: [Character: String] {
        var hints: [Character: [String]] = [:]
        for (initial, key) in Self.initialKeys { hints[key, default: []].append(initial) }
        // ü's own finals share their keys with u's, so they need no label.
        for (final, key) in finals.sorted(by: { ($0.key.count, $0.key) < ($1.key.count, $1.key) }) where !final.hasPrefix("v") {
            hints[key, default: []].append(final)
        }
        return hints.mapValues { $0.joined(separator: " ") }
    }
}
