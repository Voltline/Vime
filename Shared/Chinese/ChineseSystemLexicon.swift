import Foundation

/// In-memory Chinese candidates derived from the host's iOS supplementary lexicon:
/// - System text replacements whose shortcut is ASCII letters (e.g. `dz` -> address)
/// - Chinese contact names matched by full pinyin and initials (e.g. `张三` -> `zhangsan`, `zs`)
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
            guard (1...12).contains(name.count),
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

    /// Returns matching Chinese text replacements (first) and contact names for an
    /// open lowercase ASCII pinyin input (without apostrophes).
    static func matches(for letters: String) -> [String] {
        guard !letters.isEmpty else { return [] }
        let code = letters.lowercased()
        let (reps, contacts): ([String], [String]) = lock.withLock {
            (storage.replacementsByCode[code] ?? [], storage.contactsByCode[code] ?? [])
        }
        guard !reps.isEmpty || !contacts.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for item in reps where seen.insert(item).inserted { result.append(item) }
        for item in contacts where seen.insert(item).inserted { result.append(item) }
        return result
    }

    // MARK: Pinyin Indexing (System CFStringTransform, zero bundled data)

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

    /// Converts a Chinese name like "张三" into ["zhangsan", "zs"].
    static func pinyinKeys(for name: String) -> [String] {
        let mutable = NSMutableString(string: name)
        guard CFStringTransform(mutable, nil, kCFStringTransformToLatin, false) else { return [] }
        _ = CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let latin = (mutable as String).lowercased()

        let syllables = latin
            .split(whereSeparator: { !($0 >= "a" && $0 <= "z") })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !syllables.isEmpty else { return [] }

        let full = syllables.joined()
        var keys = [full]
        if syllables.count >= 2 {
            let initials = String(syllables.compactMap(\.first))
            if initials.count >= 2 && initials != full {
                keys.append(initials)
            }
        }
        return keys
    }
}
