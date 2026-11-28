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

    func record(
        word: String,
        previousWord: String? = nil,
        now: Date = Date(),
        exclusionsActive: Bool = LearningExclusionPolicy.isActive(),
        exclusionList: LearningExclusionList = .shared,
        blocklist: LearningExclusionList = PredictionBlocklist.korean
    ) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 20, HangulComposer.isHangul(trimmed) else { return }
        guard !blocklist.matches(trimmed),
              LearningExclusionPolicy.allowsLearning(trimmed, active: exclusionsActive, list: exclusionList) else {
            return
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
    }

    private func flushIfNeeded() {
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
        ioQueue.async { Self.write(archive, to: url) }
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
        if let url = fileURL,
           let data = try? Data(contentsOf: url),
           let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            lastResetID = archive.resetID
            words = Dictionary(uniqueKeysWithValues: archive.words.map { ($0.surface, $0) })
            bigrams = Dictionary(uniqueKeysWithValues: archive.bigrams.map { ("\($0.prevHash)|\($0.next)", $0) })
        }
        applyPendingResetLocked()
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
