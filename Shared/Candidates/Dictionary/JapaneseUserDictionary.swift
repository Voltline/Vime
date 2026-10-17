import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

nonisolated struct JapaneseUserDictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case word, shortcut }
    var id = UUID()
    var reading: String
    var surface: String
    var kind: Kind = .word
}

/// App writes atomically; each worker caches a snapshot until the shared revision changes.
/// No disk reads or writes on the unchanged keystroke path.
nonisolated final class JapaneseUserDictionaryStore {
    enum Failure: LocalizedError {
        case invalidReading, invalidSurface, tooLarge, invalidArchive
        var errorDescription: String? {
            switch self {
            case .invalidReading: "读音需为 1–64 个假名，可先输入完整罗马字。"
            case .invalidSurface: "词语或短语需为 1–128 个字符，不能包含控制字符。"
            case .tooLarge: "词典最多支持 1,024 条，导入文件不能超过 1 MB。"
            case .invalidArchive: "无法读取词典，请使用 Vime 导出的 JSON 格式。"
            }
        }
    }
    struct Archive: Codable { var version = 1; var entries: [JapaneseUserDictionaryEntry] }
    static let maximumEntries = 1024
    static let maximumBytes = 1024 * 1024
    private let defaults: UserDefaults
    private let url: URL
    private var revision: String?
    private var loaded = false
    private var cached: [JapaneseUserDictionaryEntry] = []
    private var cachedNative: (words: [DicdataElement], shortcuts: [DicdataElement])?

    init(directory: URL? = nil, defaults: UserDefaults? = nil) {
        let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup)
        let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = (directory ?? (shared ?? local).appendingPathComponent("Vime", isDirectory: true))
            .appendingPathComponent("UserDictionary.json")
        self.defaults = defaults ?? (shared == nil ? .standard : UserDefaults(suiteName: KeyboardPreferences.appGroup) ?? .standard)
    }

    func entries() throws -> [JapaneseUserDictionaryEntry] {
        let current = defaults.string(forKey: "vime.userDictionaryRevision")
        if loaded && current == revision { return cached }
        let values: [JapaneseUserDictionaryEntry]
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            values = try Self.decode(data)
        } else { values = [] }
        cached = values; cachedNative = nil; revision = current; loaded = true
        return values
    }

    static func normalized(_ entry: JapaneseUserDictionaryEntry) throws -> JapaneseUserDictionaryEntry {
        var entry = entry
        let raw = entry.reading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty, raw.count <= 512, raw.utf8.count <= 2048 else { throw Failure.invalidReading }
        var composing = ComposingText(); RomajiConverter.insert(raw, into: &composing)
        composing.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: .roman2kana)])
        let reading = RomajiConverter.katakana(composing.convertTarget)
        guard (1...64).contains(reading.count), reading.unicodeScalars.allSatisfy({
            (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC
        }) else { throw Failure.invalidReading }
        entry.reading = reading
        guard entry.surface.utf8.count <= 2048 else { throw Failure.invalidSurface }
        entry.surface = entry.surface.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...128).contains(entry.surface.count), !entry.surface.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { throw Failure.invalidSurface }
        return entry
    }

    static func decode(_ data: Data) throws -> [JapaneseUserDictionaryEntry] {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 else { throw Failure.invalidArchive }
        guard archive.entries.count <= maximumEntries else { throw Failure.tooLarge }
        return try validated(archive.entries)
    }
    private static func validated(_ values: [JapaneseUserDictionaryEntry]) throws -> [JapaneseUserDictionaryEntry] {
        guard values.count <= maximumEntries * 2 else { throw Failure.tooLarge }
        var seen = Set<String>(); var ids = Set<UUID>()
        let result = try values.compactMap { original -> JapaneseUserDictionaryEntry? in
            var entry = try normalized(original)
            guard seen.insert(entry.kind.rawValue + "\0" + entry.reading + "\0" + entry.surface).inserted else { return nil }
            if !ids.insert(entry.id).inserted { entry.id = UUID(); ids.insert(entry.id) }
            return entry
        }
        guard result.count <= maximumEntries else { throw Failure.tooLarge }
        return result
    }
    func save(_ values: [JapaneseUserDictionaryEntry]) throws {
        let values = try Self.validated(values)
        let data = try JSONEncoder().encode(Archive(entries: values))
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let token = UUID().uuidString
        defaults.set(token, forKey: "vime.userDictionaryRevision")
        cached = values; cachedNative = nil; revision = token; loaded = true
    }
    func importData(_ data: Data) throws { try save(try entries() + Self.decode(data)) }
    func exportData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let archive = Archive(entries: try entries())
        let formatted = try encoder.encode(archive)
        if formatted.count <= Self.maximumBytes { return formatted }
        // Whitespace must not make an otherwise valid dictionary unimportable.
        encoder.outputFormatting = [.sortedKeys]
        let compact = try encoder.encode(archive)
        guard compact.count <= Self.maximumBytes else { throw Failure.tooLarge }
        return compact
    }
    func nativeEntries() -> (words: [DicdataElement], shortcuts: [DicdataElement]) {
        let entries: [JapaneseUserDictionaryEntry]
        do { entries = try self.entries() }
        catch {
            // A corrupt external file must not cause repeated disk work on typing.
            // Keep the last good worker snapshot until the App publishes a new revision.
            loaded = true; revision = defaults.string(forKey: "vime.userDictionaryRevision")
            entries = cached
        }
        if let cachedNative { return cachedNative }
        func elements(_ kind: JapaneseUserDictionaryEntry.Kind) -> [DicdataElement] {
            entries.filter { $0.kind == kind }.map {
                DicdataElement(word: $0.surface, ruby: $0.reading, cid: CIDData.固有名詞.cid,
                    mid: MIDData.一般.mid, value: -8)
            }
        }
        let result = (words: elements(.word), shortcuts: elements(.shortcut))
        cachedNative = result
        return result
    }
}
