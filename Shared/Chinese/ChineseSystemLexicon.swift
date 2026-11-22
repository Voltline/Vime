import Foundation

/// In-memory Chinese candidates derived from the host's iOS supplementary lexicon:
/// - System text replacements whose shortcut is ASCII letters (placed first with user phrases)
/// - Chinese contact names (length >= 2) matched by full pinyin, plus initials for >= 3-char
///   names (placed after the 2nd candidate so contacts never displace normal lead words)
///
/// Held only for the current process; never persisted or exported.
nonisolated enum ChineseSystemLexicon {
    private struct Storage {
        var replacementsByCode: [String: [String]] = [:]
        var contactsByCode: [String: [String]] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage = Storage()

    static let maximumReplacements = 1024
    static let maximumContacts = 2048

    /// Common polyphonic Chinese surnames whose default `CFStringTransform` Mandarin
    /// reading differs from the surname reading.
    static let surnameOverrides: [Character: String] = [
        "单": "shan", "單": "shan",
        "曾": "zeng",
        "解": "xie",
        "仇": "qiu",
        "区": "ou", "區": "ou",
        "朴": "piao",
        "查": "zha",
        "任": "ren",
        "华": "hua", "華": "hua",
        "盖": "ge", "蓋": "ge",
        "乐": "yue", "樂": "yue",
        "缪": "miao", "繆": "miao",
        "员": "yun", "員": "yun",
        "冼": "xian",
        "翟": "zhai",
        "折": "she",
        "尉": "yu",
        "覃": "qin",
        "褚": "chu",
        "阚": "kan", "闞": "kan",
        "种": "chong", "種": "chong",
        "繁": "po",
        "宁": "ning", "寧": "ning",
        "乜": "nie",
        "万": "wan", "萬": "wan",
        "句": "gou",
        "召": "shao",
    ]

    static func update(replacements: [(shortcut: String, phrase: String)], contacts: [String]) {
        var repMap: [String: [String]] = [:]
        var seenRep = Set<String>()
        var repCount = 0

        for pair in replacements {
            guard repCount < maximumReplacements else { break }
            let code = pair.shortcut.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let phrase = pair.phrase.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard (1...64).contains(code.count),
                  code.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }),
                  (1...256).contains(phrase.count),
                  !phrase.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seenRep.insert(code + "\0" + phrase).inserted else { continue }
            repMap[code, default: []].append(phrase)
            repCount += 1
        }

        var contactMap: [String: [String]] = [:]
        var seenNames = Set<String>()
        var contactCount = 0

        for rawName in contacts {
            guard contactCount < maximumContacts else { break }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            // Skip single-character names so common single-syllable words are never polluted.
            guard (2...12).contains(name.count),
                  containsHanIdeograph(name),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seenNames.insert(name).inserted else { continue }

            let keys = pinyinKeys(for: name)
            guard !keys.isEmpty else { continue }
            for key in keys {
                var list = contactMap[key, default: []]
                if !list.contains(name) {
                    list.append(name)
                    contactMap[key] = list
                }
            }
            contactCount += 1
        }

        lock.withLock {
            storage = Storage(replacementsByCode: repMap, contactsByCode: contactMap)
        }
    }

    static func clear() {
        lock.withLock { storage = Storage() }
    }

    /// System text replacements matching `letters` (placed with user phrases at the lead).
    static func replacements(for letters: String) -> [String] {
        guard !letters.isEmpty else { return [] }
        let code = letters.lowercased()
        return lock.withLock { storage.replacementsByCode[code] ?? [] }
    }

    /// Chinese contact names matching `letters` (placed after the 2nd candidate).
    static func contacts(for letters: String) -> [String] {
        guard !letters.isEmpty else { return [] }
        let code = letters.lowercased()
        return lock.withLock { storage.contactsByCode[code] ?? [] }
    }

    /// Combined lookup helper (replacements first, then contacts).
    static func matches(for letters: String) -> [String] {
        let reps = replacements(for: letters)
        let contacts = contacts(for: letters)
        guard !reps.isEmpty || !contacts.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for item in reps where seen.insert(item).inserted { result.append(item) }
        for item in contacts where seen.insert(item).inserted { result.append(item) }
        return result
    }

    // MARK: Pinyin Indexing (Surname overrides + System CFStringTransform, zero bundled data)

    static func containsHanIdeograph(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2CEAF:
                return true
            default:
                return false
            }
        }
    }

    /// Converts a Chinese name (length >= 2) into full pinyin, plus initials only when
    /// the name has >= 3 syllables (so 2-char names like 王军 never collide with `wj`).
    static func pinyinKeys(for name: String) -> [String] {
        guard name.count >= 2 else { return [] }
        var syllables: [String] = []
        let chars = Array(name)
        var startIndex = 0
        if let first = chars.first, let override = surnameOverrides[first] {
            syllables.append(override)
            startIndex = 1
        }
        if startIndex < chars.count {
            let remainder = String(chars[startIndex...])
            syllables.append(contentsOf: transformToSyllables(remainder))
        }
        guard syllables.count >= 2 else { return [] }

        let full = syllables.joined()
        var keys = [full]
        if syllables.count >= 3 {
            let initials = String(syllables.compactMap(\.first))
            if initials.count >= 3 && initials != full {
                keys.append(initials)
            }
        }
        return keys
    }

    private static func transformToSyllables(_ text: String) -> [String] {
        let mutable = NSMutableString(string: text)
        guard CFStringTransform(mutable, nil, kCFStringTransformToLatin, false) else { return [] }
        _ = CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let latin = (mutable as String).lowercased()
        return latin
            .split(whereSeparator: { !($0 >= "a" && $0 <= "z") })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
