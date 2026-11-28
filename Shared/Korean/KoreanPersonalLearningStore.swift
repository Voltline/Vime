import Foundation

/// On-device personal frequency & next-word learning store for Korean input.
///
/// Design invariants:
/// - Lazy-loaded only when Korean input is active; unloaded on `release()`.
/// - Respects `LearningExclusionPolicy`, `LearningExclusionList`, and `PredictionBlocklist.korean`.
/// - Honors global `KeyboardLearningResetRequests` resets.
/// - Bounded size with debounced background JSON persistence in App Group `Vime/`.
nonisolated final class KoreanPersonalLearningStore: @unchecked Sendable {
    struct WordRecord: Codable, Equatable, Sendable {
        var surface: String
        var jamo: String
        var count: Int
        var updatedAt: TimeInterval
    }

    struct BigramRecord: Codable, Equatable, Sendable {
        var prevHash: UInt64
        var next: String
        var count: Int
        var updatedAt: TimeInterval
    }

    private struct Archive: Codable {
        var version = 1
        var resetID: String?
        var words: [WordRecord]
        var bigrams: [BigramRecord]
    }

    static let maxWords = 1024
    static let maxBigrams = 512
    static let writeCoalesceDelay: TimeInterval = 1.5

    static let shared = KoreanPersonalLearningStore(directory: defaultDirectory())

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.Voltline.Vime.KoreanPersonalLearningStore.io", qos: .utility)
    private let fileURL: URL?

    private var loaded = false
    private var words: [String: WordRecord] = [:]
    private var bigrams: [String: BigramRecord] = [:]
    private var lastResetID: String?
    private var pendingResetID: String?
    private var lastLoadedMtime: Date?
    private var lastLoadedExisted = false
    private var dirty = false
    private var pendingFlushWork: DispatchWorkItem?

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    init(directory: URL?) {
        self.fileURL = directory?.appendingPathComponent("KoreanPersonalLearning.json")
    }

    static func defaultDirectory() -> URL? {
        let fm = FileManager.default
        let root = fm.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return root?.appendingPathComponent("Vime", isDirectory: true)
    }

    /// Unloads in-memory tables after flushing pending writes.
    func release() {
        flushIfNeeded()
        lock.lock()
        loaded = false
        words.removeAll(keepingCapacity: false)
        bigrams.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// Records a reset request ID without reading disk while Korean is unloaded.
    /// If Korean is already loaded, clears immediately; otherwise defers until first load.
    func applyResetIfNeeded(resetID: String?) {
        guard let resetID, !resetID.isEmpty else { return }
        lock.lock()
        pendingResetID = resetID
        guard loaded else {
            lock.unlock()
            return
        }
        applyPendingResetLocked()
        lock.unlock()
    }

    private func applyPendingResetLocked() {
        guard let resetID = pendingResetID, !resetID.isEmpty, lastResetID != resetID else { return }
        lastResetID = resetID
        words.removeAll(keepingCapacity: false)
        bigrams.removeAll(keepingCapacity: false)
        dirty = true
        scheduleFlushLocked()
    }

    func reset() {
        lock.lock()
        loaded = true
        words.removeAll(keepingCapacity: false)
        bigrams.removeAll(keepingCapacity: false)
        dirty = false
        pendingFlushWork?.cancel()
        pendingFlushWork = nil
        let url = fileURL
        lock.unlock()
        if let url {
            ioQueue.async { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Synchronously clears all learned words and removes the backing file so the
    /// keyboard extension observes the deletion on its next `reloadIfModified()`.
    func clearAllAndPersist() {
        lock.lock()
        loaded = true
        words.removeAll(keepingCapacity: false)
        bigrams.removeAll(keepingCapacity: false)
        dirty = false
        pendingFlushWork?.cancel()
        pendingFlushWork = nil
        let url = fileURL
        lastLoadedMtime = nil
        lastLoadedExisted = false
        lock.unlock()
        if let url {
            ioQueue.sync { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Returns all learned words sorted by usage count descending, reloading from disk
    /// if another process modified the backing file.
    func allWords() -> [WordRecord] {
        reloadIfModified()
        lock.lock()
        ensureLoadedLocked()
        let result = words.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.surface < rhs.surface
        }
        lock.unlock()
        return result
    }

    /// Whether the backing JSON file currently holds at least one learned word.
    var hasStoredRecords: Bool {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return false }
        return !allWords().isEmpty
    }

    /// Exports learned words as UTF-8 text: each line is `word\tcount`.
    func exportText() -> Data {
        let lines = allWords().map { "\($0.surface)\t\($0.count)" }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return Data(body.utf8)
    }

    /// Deletes a word and synchronously persists the updated JSON file so another
    /// process (keyboard extension) sees the new modification timestamp and never
    /// resurrects the deleted entry from stale in-memory state.
    func forgetAndPersist(word: String) {
        reloadIfModified()
        lock.lock()
        ensureLoadedLocked()
        let removedWord = words.removeValue(forKey: word) != nil
        let before = bigrams.count
        bigrams = bigrams.filter { $0.value.next != word }
        guard removedWord || bigrams.count != before else {
            lock.unlock()
            return
        }
        pendingFlushWork?.cancel()
        pendingFlushWork = nil
        dirty = false
        let archive = Archive(resetID: lastResetID, words: Array(words.values), bigrams: Array(bigrams.values))
        let url = fileURL
        lock.unlock()
        if let url {
            ioQueue.sync { Self.write(archive, to: url) }
            lock.lock()
            let (exists, mtime) = Self.diskState(at: url)
            lastLoadedExisted = exists
            lastLoadedMtime = mtime
            lock.unlock()
        }
    }

    /// Checks whether the backing file was modified or deleted by another process
    /// (e.g. the containing app deleting a word or clearing all records) and reloads
    /// from disk when needed. Does nothing if the store has not been loaded yet.
    func reloadIfModified() {
        lock.lock()
        guard loaded, let url = fileURL else {
            lock.unlock()
            return
        }
        let (exists, mtime) = Self.diskState(at: url)
        let changed = (exists != lastLoadedExisted) || (exists && mtime != lastLoadedMtime)
        guard changed else {
            lock.unlock()
            return
        }
        pendingFlushWork?.cancel()
        pendingFlushWork = nil
        dirty = false
        words.removeAll(keepingCapacity: false)
        bigrams.removeAll(keepingCapacity: false)
        loadFromDiskLocked(url: url, exists: exists, mtime: mtime)
        lock.unlock()
    }

    @discardableResult
    func record(
        word: String,
        previousWord: String? = nil,
        now: Date = Date(),
        exclusionsActive: Bool = LearningExclusionPolicy.isActive(),
        exclusionList: LearningExclusionList = .shared,
        blocklist: LearningExclusionList = PredictionBlocklist.korean
    ) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 20, HangulComposer.isHangul(trimmed) else { return false }
        guard !blocklist.matches(trimmed),
              LearningExclusionPolicy.allowsLearning(trimmed, active: exclusionsActive, list: exclusionList) else {
            return false
        }
        let jamo = String(HangulComposer.decomposeToJamo(trimmed))
        let ts = now.timeIntervalSince1970

        lock.lock()
        ensureLoadedLocked()
        if var existing = words[trimmed] {
            existing.count += 1
            existing.updatedAt = ts
            words[trimmed] = existing
        } else {
            words[trimmed] = WordRecord(surface: trimmed, jamo: jamo, count: 1, updatedAt: ts)
            if words.count > Self.maxWords { trimWordsLocked() }
        }

        if let prev = previousWord?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prev.isEmpty, prev.count <= 20, HangulComposer.isHangul(prev),
           !blocklist.matches(prev),
           LearningExclusionPolicy.allowsLearning(prev, active: exclusionsActive, list: exclusionList) {
            let prevHash = KoreanLexicon.hash(prev)
            let key = "\(prevHash)|\(trimmed)"
            if var existing = bigrams[key] {
                existing.count += 1
                existing.updatedAt = ts
                bigrams[key] = existing
            } else {
                bigrams[key] = BigramRecord(prevHash: prevHash, next: trimmed, count: 1, updatedAt: ts)
                if bigrams.count > Self.maxBigrams { trimBigramsLocked() }
            }
        }
        dirty = true
        scheduleFlushLocked()
        lock.unlock()
        return true
    }

    /// Reverts a single recorded occurrence of `word` (and optional bigram from `previousWord`),
    /// removing the entry entirely when its count drops to 0.
    func unrecord(word: String, previousWord: String? = nil) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        ensureLoadedLocked()
        var mutated = false
        if var existing = words[trimmed] {
            existing.count -= 1
            if existing.count <= 0 {
                words.removeValue(forKey: trimmed)
            } else {
                words[trimmed] = existing
            }
            mutated = true
        }
        if let prev = previousWord?.trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
            let prevHash = KoreanLexicon.hash(prev)
            let key = "\(prevHash)|\(trimmed)"
            if var existing = bigrams[key] {
                existing.count -= 1
                if existing.count <= 0 {
                    bigrams.removeValue(forKey: key)
                } else {
                    bigrams[key] = existing
                }
                mutated = true
            }
        }
        if mutated {
            dirty = true
            scheduleFlushLocked()
        }
        lock.unlock()
    }

    func frequency(of word: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        return words[word]?.count ?? 0
    }

    func isLearned(_ word: String) -> Bool {
        frequency(of: word) > 0
    }

    func forget(word: String) {
        lock.lock()
        ensureLoadedLocked()
        let removedWord = words.removeValue(forKey: word) != nil
        let before = bigrams.count
        bigrams = bigrams.filter { $0.value.next != word }
        if removedWord || bigrams.count != before {
            dirty = true
            scheduleFlushLocked()
        }
        lock.unlock()
    }

    func matchingCompletions(
        jamoPrefix: String,
        limit: Int = 6,
        blocklist: LearningExclusionList = PredictionBlocklist.korean
    ) -> [WordRecord] {
        guard !jamoPrefix.isEmpty, limit > 0 else { return [] }
        lock.lock()
        ensureLoadedLocked()
        let matches = words.values.filter {
            $0.jamo.hasPrefix(jamoPrefix) && !blocklist.matches($0.surface)
        }
        lock.unlock()
        return matches.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.updatedAt > rhs.updatedAt
        }.prefix(limit).map { $0 }
    }

    func nextWords(
        after previousWord: String,
        limit: Int = 6,
        blocklist: LearningExclusionList = PredictionBlocklist.korean
    ) -> [BigramRecord] {
        guard !previousWord.isEmpty, limit > 0 else { return [] }
        let prevHash = KoreanLexicon.hash(previousWord)
        lock.lock()
        ensureLoadedLocked()
        let matches = bigrams.values.filter {
            $0.prevHash == prevHash && !blocklist.matches($0.next)
        }
        lock.unlock()
        return matches.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.updatedAt > rhs.updatedAt
        }.prefix(limit).map { $0 }
    }

    func flushSync() {
        lock.lock()
        pendingFlushWork?.cancel()
        pendingFlushWork = nil
        guard dirty, let url = fileURL else {
            lock.unlock()
            return
        }
        let archive = Archive(resetID: lastResetID, words: Array(words.values), bigrams: Array(bigrams.values))
        dirty = false
        lock.unlock()
        ioQueue.sync { Self.write(archive, to: url) }
        lock.lock()
        let (exists, mtime) = Self.diskState(at: url)
        lastLoadedExisted = exists
        lastLoadedMtime = mtime
        lock.unlock()
    }

    private func flushIfNeeded() {
        lock.lock()
        pendingFlushWork?.cancel()
        pendingFlushWork = nil
        guard dirty, let url = fileURL else {
            lock.unlock()
            return
        }
        // Guard against overwriting an external edit/delete from the containing app.
        let (exists, mtime) = Self.diskState(at: url)
        if (exists != lastLoadedExisted) || (exists && mtime != lastLoadedMtime) {
            dirty = false
            words.removeAll(keepingCapacity: false)
            bigrams.removeAll(keepingCapacity: false)
            loadFromDiskLocked(url: url, exists: exists, mtime: mtime)
            lock.unlock()
            return
        }
        let archive = Archive(resetID: lastResetID, words: Array(words.values), bigrams: Array(bigrams.values))
        dirty = false
        lock.unlock()
        ioQueue.async { [weak self] in
            Self.write(archive, to: url)
            guard let self else { return }
            let (newExists, newMtime) = Self.diskState(at: url)
            self.lock.lock()
            self.lastLoadedExisted = newExists
            self.lastLoadedMtime = newMtime
            self.lock.unlock()
        }
    }

    private func scheduleFlushLocked() {
        guard fileURL != nil else { return }
        pendingFlushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushIfNeeded() }
        pendingFlushWork = work
        ioQueue.asyncAfter(deadline: .now() + Self.writeCoalesceDelay, execute: work)
    }

    private func ensureLoadedLocked() {
        guard !loaded else { return }
        loaded = true
        if let url = fileURL {
            let (exists, mtime) = Self.diskState(at: url)
            loadFromDiskLocked(url: url, exists: exists, mtime: mtime)
        }
        applyPendingResetLocked()
    }

    private func loadFromDiskLocked(url: URL, exists: Bool, mtime: Date?) {
        lastLoadedExisted = exists
        lastLoadedMtime = mtime
        guard exists,
              let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        lastResetID = archive.resetID
        words = Dictionary(uniqueKeysWithValues: archive.words.map { ($0.surface, $0) })
        bigrams = Dictionary(uniqueKeysWithValues: archive.bigrams.map { ("\($0.prevHash)|\($0.next)", $0) })
    }

    private static func diskState(at url: URL) -> (exists: Bool, mtime: Date?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (false, nil)
        }
        return (true, attrs[.modificationDate] as? Date)
    }

    private func trimWordsLocked() {
        let keep = words.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.updatedAt > $1.updatedAt
        }.prefix(Self.maxWords - 64)
        words = Dictionary(uniqueKeysWithValues: keep.map { ($0.surface, $0) })
    }

    private func trimBigramsLocked() {
        let keep = bigrams.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.updatedAt > $1.updatedAt
        }.prefix(Self.maxBigrams - 32)
        bigrams = Dictionary(uniqueKeysWithValues: keep.map { ("\($0.prevHash)|\($0.next)", $0) })
    }

    private static func write(_ archive: Archive, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(archive) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
