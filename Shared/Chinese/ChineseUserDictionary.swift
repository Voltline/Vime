import Foundation

/// A phrase the user added for pinyin input: it shows first when the whole
/// input spells it, in full or by the initials of its syllables.
nonisolated struct ChineseUserPhrase: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    /// Syllables separated by single spaces, such as "wei mai".
    var pinyin: String
    var text: String

    var syllables: [Substring] { pinyin.split(separator: " ") }
    /// What the input must be: every letter, or the initials of two or more syllables.
    var spellings: [String] {
        let full = syllables.joined()
        let initials = String(syllables.compactMap(\.first))
        return syllables.count >= 2 ? [full, initials] : [full]
    }
}

/// The app writes the file atomically and bumps a shared revision; the
/// keyboard reads the file again only when the revision changed.
nonisolated final class ChineseUserDictionaryStore {
    enum Failure: LocalizedError {
        case invalidPinyin, invalidText, tooLarge, invalidArchive
        var errorDescription: String? {
            switch self {
            case .invalidPinyin: String(localized: "拼音需为 1–16 个音节，例如 wei mai 或 weimai。")
            case .invalidText: String(localized: "词语或短语需为 1–128 个字符，不能包含控制字符。")
            case .tooLarge: String(localized: "词典最多支持 1,024 条，导入文件不能超过 4 MB。")
            case .invalidArchive: String(localized: "无法读取词典。支持 Vime JSON，以及每行“词语 + Tab + 拼音”的文本。")
            }
        }
    }
    struct Archive: Codable { var version = 1; var entries: [ChineseUserPhrase] }
    static let maximumEntries = 1024
    static let maximumBytes = 1024 * 1024
    static let maximumImportBytes = 4 * 1024 * 1024
    static let revisionKey = "vime.chineseUserDictionaryRevision"
    private let defaults: UserDefaults
    private let url: URL
    private var revision: String?
    private var loaded = false
    private var cached: [ChineseUserPhrase] = []
    private var index: [String: [ChineseUserPhrase]] = [:]

    init(directory: URL? = nil, defaults: UserDefaults? = nil) {
        let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup)
        let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = (directory ?? (shared ?? local).appendingPathComponent("Vime", isDirectory: true))
            .appendingPathComponent("ChineseUserDictionary.json")
        self.defaults = defaults ?? (shared == nil ? .standard : UserDefaults(suiteName: KeyboardPreferences.appGroup) ?? .standard)
    }

    func entries() throws -> [ChineseUserPhrase] {
        let current = defaults.string(forKey: Self.revisionKey)
        if loaded && current == revision { return cached }
        let values: [ChineseUserPhrase]
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            values = try Self.decode(try handle.read(upToCount: Self.maximumBytes + 1) ?? Data())
        } else { values = [] }
        remember(values, revision: current)
        return values
    }

    /// The phrases the whole input spells, in the order they were added.
    /// A file that cannot be read keeps the last good list, without reading
    /// it again until the app saves.
    func phrases(spelledBy input: String) -> [ChineseUserPhrase] {
        if (try? entries()) == nil { loaded = true; revision = defaults.string(forKey: Self.revisionKey) }
        return index[input] ?? []
    }

    private func remember(_ values: [ChineseUserPhrase], revision: String?) {
        cached = values; self.revision = revision; loaded = true
        var index: [String: [ChineseUserPhrase]] = [:]
        for phrase in values { for spelling in Set(phrase.spellings) { index[spelling, default: []].append(phrase) } }
        self.index = index
    }

    /// Splits pinyin into syllables, each standing alone or written together
    /// ("wei mai", "weimai", "wei'mai"); ü may be typed as v. Nil when it
    /// does not read as 1–16 syllables.
    static func syllables(_ pinyin: String) -> [String]? {
        let words = pinyin.lowercased().replacingOccurrences(of: "ü", with: "v").replacingOccurrences(of: "u:", with: "v")
            .split(whereSeparator: { $0 == " " || $0 == "'" || $0 == "’" || $0 == "\t" })
        var result: [String] = []
        for word in words {
            guard word.allSatisfy({ ("a"..."z").contains($0) }), let split = split(String(word)) else { return nil }
            result += split
        }
        return (1...16).contains(result.count) ? result : nil
    }

    /// The fewest syllables that spell `word` exactly.
    private static func split(_ word: String) -> [String]? {
        let letters = Array(word)
        var best: [[String]?] = Array(repeating: nil, count: letters.count + 1)
        best[0] = []
        for end in 1...max(letters.count, 1) where end <= letters.count {
            for start in max(0, end - 6)..<end {
                guard let head = best[start] else { continue }
                let syllable = String(letters[start..<end])
                guard PinyinSpellingCorrection.syllables.contains(syllable) else { continue }
                if best[end] == nil || best[end]!.count > head.count + 1 { best[end] = head + [syllable] }
            }
        }
        return letters.isEmpty ? nil : best[letters.count]
    }

    static func normalized(_ entry: ChineseUserPhrase) throws -> ChineseUserPhrase {
        var entry = entry
        guard entry.pinyin.utf8.count <= 512, let syllables = syllables(entry.pinyin) else { throw Failure.invalidPinyin }
        entry.pinyin = syllables.joined(separator: " ")
        guard entry.text.utf8.count <= 2048 else { throw Failure.invalidText }
        entry.text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...128).contains(entry.text.count),
              !entry.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.invalidText }
        return entry
    }

    static func decode(_ data: Data) throws -> [ChineseUserPhrase] {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 else { throw Failure.invalidArchive }
        guard archive.entries.count <= maximumEntries else { throw Failure.tooLarge }
        return try validated(archive.entries)
    }

    private static func validated(_ values: [ChineseUserPhrase]) throws -> [ChineseUserPhrase] {
        guard values.count <= maximumEntries * 2 else { throw Failure.tooLarge }
        var seen = Set<String>(); var ids = Set<UUID>()
        let result = try values.compactMap { original -> ChineseUserPhrase? in
            var entry = try normalized(original)
            guard seen.insert(entry.pinyin + "\0" + entry.text).inserted else { return nil }
            if !ids.insert(entry.id).inserted { entry.id = UUID(); ids.insert(entry.id) }
            return entry
        }
        guard result.count <= maximumEntries else { throw Failure.tooLarge }
        return result
    }

    func save(_ values: [ChineseUserPhrase]) throws {
        let values = try Self.validated(values)
        let data = try JSONEncoder().encode(Archive(entries: values))
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let token = UUID().uuidString
        defaults.set(token, forKey: Self.revisionKey)
        remember(values, revision: token)
    }

    /// Vime JSON, or text with a phrase and its pinyin on each line
    /// separated by a tab (Rime's dictionary lines; a third column is
    /// ignored). Lines Vime cannot use are skipped; the merge is all or nothing.
    func importFile(_ data: Data) throws -> (added: Int, skipped: Int) {
        guard data.count <= Self.maximumImportBytes else { throw Failure.tooLarge }
        let parsed: (entries: [ChineseUserPhrase], skipped: Int)
        if data.first(where: { !Character(UnicodeScalar($0)).isWhitespace }) == UInt8(ascii: "{") {
            parsed = (try Self.decode(data), 0)
        } else {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw Failure.invalidArchive
            }
            var entries: [ChineseUserPhrase] = [], skipped = 0, rows = 0
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                rows += 1
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count >= 2,
                      let entry = try? Self.normalized(.init(pinyin: String(columns[1]), text: String(columns[0])))
                else { skipped += 1; continue }
                entries.append(entry)
            }
            guard rows > 0, !entries.isEmpty || skipped == 0 else { throw Failure.invalidArchive }
            parsed = (entries, skipped)
        }
        let before = try entries().count
        try save(try entries() + parsed.entries)
        return (try entries().count - before, parsed.skipped)
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Archive(entries: try entries()))
    }

    /// "phrase<TAB>pin yin" lines, which Rime and Vime both read.
    func exportText() throws -> Data {
        Data(try entries().map { $0.text + "\t" + $0.pinyin + "\n" }.joined().utf8)
    }
}
