import CRime
import Foundation

nonisolated struct ChineseLearnedWord: Identifiable, Hashable, Sendable {
    var text: String
    /// Syllables separated by spaces, as Rime keeps them.
    var pinyin: String
    var commits: Int
    var id: String { pinyin + "\t" + text }
}

/// What pinyin input learned, kept by the keyboard in Rime's user
/// dictionary. The app reads a copy of the database, since the keyboard may
/// hold it open, and leaves changes as files the keyboard merges the next
/// time it starts Rime (`RimeEngine`), so only one process ever writes it.
nonisolated struct ChineseLearnedWords: @unchecked Sendable {
    enum Failure: LocalizedError {
        case unreadable, invalidFile, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "暂时无法读取学到的词，请稍后再试。")
            case .invalidFile: String(localized: "无法读取文件。支持 Rime 用户词典导出的文本：每行“词语 + Tab + 拼音 + Tab + 次数”。")
            case .tooLarge: String(localized: "导入文件不能超过 4 MB。")
            }
        }
    }

    static let dictionary = "vime_pinyin"
    static let maximumImportBytes = 4 * 1024 * 1024
    static let revisionKey = "vime.chineseLearnedWordsRevision"
    /// The keyboard's dictionary folder, which `ChineseInputSession.userDirectory` gives inside the extension.
    let userDirectory: URL
    /// Changes waiting for the keyboard, merged in name order.
    let pendingDirectory: URL
    let defaults: UserDefaults

    init(userDirectory: URL, pendingDirectory: URL, defaults: UserDefaults) {
        self.userDirectory = userDirectory
        self.pendingDirectory = pendingDirectory
        self.defaults = defaults
    }

    /// The keyboard's, in the App Group.
    static func shared() -> ChineseLearnedWords {
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup)
        let root = (group ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Vime", isDirectory: true)
        return ChineseLearnedWords(userDirectory: root.appendingPathComponent("Rime", isDirectory: true),
                                   pendingDirectory: root.appendingPathComponent("RimePending", isDirectory: true),
                                   defaults: group == nil ? .standard : UserDefaults(suiteName: KeyboardPreferences.appGroup) ?? .standard)
    }

    private var database: URL { userDirectory.appendingPathComponent(Self.dictionary + ".userdb", isDirectory: true) }
    var revision: String? { defaults.string(forKey: Self.revisionKey) }

    // MARK: App

    /// Learned words, most used first, with the changes still waiting applied.
    func words() throws -> [ChineseLearnedWord] {
        var words: [String: ChineseLearnedWord] = [:]
        let files = FileManager.default
        if files.fileExists(atPath: database.path) {
            let copy = files.temporaryDirectory.appendingPathComponent("VimeLearned-" + UUID().uuidString, isDirectory: true)
            defer { try? files.removeItem(at: copy) }
            try files.createDirectory(at: copy, withIntermediateDirectories: true)
            let target = copy.appendingPathComponent(Self.dictionary + ".userdb", isDirectory: true)
            try files.copyItem(at: database, to: target)
            // A lock file copied from the open database would keep the copy closed.
            try? files.removeItem(at: target.appendingPathComponent("LOCK"))
            let text = copy.appendingPathComponent("export.txt")
            guard vime_rime_userdb_export(target.path, Self.dictionary, text.path) >= 0 else { throw Failure.unreadable }
            for word in Self.parse(try String(contentsOf: text, encoding: .utf8)) { words[word.id] = word }
        }
        for file in pendingFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for word in Self.parse(text, allowingDeletions: true) {
                if word.commits < 0 { words[word.id] = nil }
                else { words[word.id] = ChineseLearnedWord(text: word.text, pinyin: word.pinyin,
                                                          commits: max(word.commits, words[word.id]?.commits ?? 0)) }
            }
        }
        return words.values.filter { $0.commits > 0 }
            .sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.pinyin < $1.pinyin }
    }

    func delete(_ words: [ChineseLearnedWord]) throws {
        guard !words.isEmpty else { return }
        try leave(words.map { $0.text + "\t" + $0.pinyin + "\t-1\n" }.joined())
    }

    /// Rime's text export: phrase, pinyin and how often it was chosen. Lines
    /// Vime cannot use, and text it never learns, are skipped.
    func importFile(_ data: Data) throws -> (added: Int, skipped: Int) {
        guard data.count <= Self.maximumImportBytes else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw Failure.invalidFile }
        var lines = "", added = 0, skipped = 0
        let active = LearningExclusionPolicy.isActive()
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let word = Self.word(line, checkingPinyin: true), word.commits > 0, word.text.count <= 64,
                  LearningExclusionPolicy.allowsLearning(word.text, active: active)
            else { skipped += 1; continue }
            lines += word.text + "\t" + word.pinyin + "\t" + String(min(word.commits, 1000)) + "\n"
            added += 1
        }
        guard added > 0 || skipped == 0, added + skipped > 0 else { throw Failure.invalidFile }
        if added > 0 { try leave(lines) }
        return (added, skipped)
    }

    func exportText() throws -> Data {
        Data(("# Rime user dictionary export\n" + (try words()).map { "\($0.text)\t\($0.pinyin)\t\($0.commits)\n" }.joined()).utf8)
    }

    /// Changes waiting are dropped with the dictionary they were meant for.
    func discardPending() {
        for file in pendingFiles() { try? FileManager.default.removeItem(at: file) }
        defaults.set(UUID().uuidString, forKey: Self.revisionKey)
    }

    private func leave(_ lines: String) throws {
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        let name = String(format: "%.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".txt"
        try Data(lines.utf8).write(to: pendingDirectory.appendingPathComponent(name), options: .atomic)
        defaults.set(UUID().uuidString, forKey: Self.revisionKey)
    }

    private func pendingFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".txt") }.sorted().map { pendingDirectory.appendingPathComponent($0) }
    }

    // MARK: Keyboard

    /// Merges every waiting change into the dictionary. Rime must not be
    /// running on it. A change that fails stays for a later try.
    func applyPending() {
        try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        for file in pendingFiles() where vime_rime_userdb_import(database.path, Self.dictionary, file.path) >= 0 {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Text

    static func parse(_ text: String, allowingDeletions: Bool = false) -> [ChineseLearnedWord] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#"), let word = word(line), allowingDeletions || word.commits > 0 else { return nil }
            return word
        }
    }

    /// Rime's own lines keep the code as it is; imported ones must spell syllables.
    private static func word(_ line: Substring, checkingPinyin: Bool = false) -> ChineseLearnedWord? {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count >= 2 else { return nil }
        let text = columns[0].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let syllables = checkingPinyin ? ChineseUserDictionaryStore.syllables(String(columns[1]))
                : columns[1].split(separator: " ").map(String.init),
              !syllables.isEmpty else { return nil }
        let commits = columns.count >= 3 ? Int(columns[2].trimmingCharacters(in: .whitespaces)) ?? 1 : 1
        return ChineseLearnedWord(text: text, pinyin: syllables.joined(separator: " "), commits: commits)
    }
}
