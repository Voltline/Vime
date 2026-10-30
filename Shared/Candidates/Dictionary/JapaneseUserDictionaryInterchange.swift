import Foundation

/// Reads the user dictionaries other Japanese input methods export, and writes
/// one Google 日本語入力 and Mozc read back. Vime JSON stays the lossless format.
nonisolated enum JapaneseUserDictionaryInterchange {
    /// Text exports run larger than Vime JSON: UTF-16 doubles them, and they
    /// carry entries Vime skips.
    static let maximumBytes = 4 * 1024 * 1024
    /// Part-of-speech names that mean a phrase only offered for its full reading.
    private static let shortcutParts: Set<String> = ["短縮よみ", "短縮読み"]
    /// Entries that hide a conversion instead of adding one.
    private static let suppressionParts: Set<String> = ["抑制単語"]

    struct Parsed { var entries: [JapaneseUserDictionaryEntry]; var skipped: Int }

    /// Vime JSON, a macOS user dictionary property list, or the tab-separated
    /// text Google 日本語入力 / Mozc, Microsoft IME and ATOK export.
    static func parse(_ data: Data) throws -> Parsed {
        guard data.count <= maximumBytes else { throw JapaneseUserDictionaryStore.Failure.tooLarge }
        if data.starts(with: Data("bplist".utf8)) { return try propertyList(data) }
        guard let text = decodeText(data) else { throw JapaneseUserDictionaryStore.Failure.invalidArchive }
        let head = text.drop { $0.isWhitespace }
        if head.hasPrefix("{") { return Parsed(entries: try JapaneseUserDictionaryStore.decode(data), skipped: 0) }
        if head.hasPrefix("<?xml") || head.hasPrefix("<plist") { return try propertyList(data) }
        return try tabSeparated(text)
    }

    /// Google 日本語入力 / Mozc import format: hiragana reading, word, part of speech, comment.
    static func mozcText(_ entries: [JapaneseUserDictionaryEntry]) -> Data {
        let lines = entries.map { entry in
            [RomajiConverter.hiragana(entry.reading), entry.surface, entry.kind == .shortcut ? "短縮よみ" : "固有名詞", ""].joined(separator: "\t")
        }
        return Data(lines.map { $0 + "\n" }.joined().utf8)
    }

    /// Microsoft IME and ATOK write UTF-16 with a byte order mark; older
    /// exports are Shift_JIS.
    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
    }

    private static func tabSeparated(_ text: String) throws -> Parsed {
        var entries: [JapaneseUserDictionaryEntry] = [], skipped = 0, rows = 0
        for line in text.split(whereSeparator: \.isNewline) {
            // Microsoft IME and ATOK headers start with "!".
            guard !line.hasPrefix("!"), !line.allSatisfy(\.isWhitespace) else { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { skipped += 1; continue }
            rows += 1
            let part = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
            if suppressionParts.contains(part) { skipped += 1; continue }
            let entry = JapaneseUserDictionaryEntry(reading: fields[0], surface: fields[1],
                kind: shortcutParts.contains(part) ? .shortcut : .word)
            if let entry = try? JapaneseUserDictionaryStore.normalized(entry) { entries.append(entry) } else { skipped += 1 }
        }
        guard rows > 0 else { throw JapaneseUserDictionaryStore.Failure.invalidArchive }
        return Parsed(entries: entries, skipped: skipped)
    }

    /// The array of `shortcut` (reading) and `phrase` (word) pairs macOS
    /// exports from its user dictionary and text replacements.
    private static func propertyList(_ data: Data) throws -> Parsed {
        guard let rows = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            throw JapaneseUserDictionaryStore.Failure.invalidArchive
        }
        var entries: [JapaneseUserDictionaryEntry] = [], skipped = 0
        for row in rows {
            guard let reading = row["shortcut"] as? String, let surface = row["phrase"] as? String,
                  let entry = try? JapaneseUserDictionaryStore.normalized(.init(reading: reading, surface: surface))
            else { skipped += 1; continue }
            entries.append(entry)
        }
        return Parsed(entries: entries, skipped: skipped)
    }
}
