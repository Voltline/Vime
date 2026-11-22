import CryptoKit
import Foundation

/// On-device contextual collocation cache for Chinese candidate personalization.
///
/// Design invariants:
/// - **Chinese only**: Japanese already has contextual memory in `CandidatePreferenceMemory`.
/// - **Hashed context only**: preceding text is stored exclusively as truncated SHA-256
///   digests (never plaintext), in two tiers (`last4` and `last2` trailing Han characters).
/// - **Sentence-compatible matching**:
///   - On `record(prevText:committed:)`: records `(ctxHash, committed)` at weight `1.0`.
///     For multi-word/sentence commits (`committed.count >= 4`), also records leading
///     2- and 3-character prefixes at `0.5` weight so subsequent segmented typing benefits.
///   - On `bonus(prevText:candidate:)`: checks exact candidate match (`1.0x`), and for
///     sentence candidates (`candidate.count > 2`) checks leading 2/3/4-character prefixes
///     (`0.65x`, taking the best match), so whole-sentence candidates can match learned
///     "prev word -> next word" collocations.
/// - **Score scale aligned with `ChineseCandidateRanking`**:
///   `keepBonus = 2.0`, so this bonus is strictly capped at `maximumBonus = 1.2`
///   (natural-log scale) with `minimumSelections = 2`, 30-day half-life, and `priorMass = 4.0`
///   Bayesian shrinkage — never overriding high-confidence LM or lead-stability protection.
/// - **Lazy-loaded & debounced background writes**: never parses or writes JSON on the
///   main thread per keystroke.
/// - **Compliance**: respects `LearningExclusionPolicy`, clears on both global and Chinese-only
///   learning reset requests, and lives inside App Group `Vime/` so system backup may include it.
nonisolated final class ChinesePersonalRankingCache: @unchecked Sendable {
    enum Policy {
        static let minimumSelections = 2
        static let halfLife: TimeInterval = 30 * 24 * 60 * 60
        static let priorMass = 4.0
        static let contextWeight = 0.72
        static let sentencePrefixFactor = 0.65
        static let shortContextFactor = 0.80
        static let maximumBonus = 1.2
        static let maximumEntries = 1024
        static let maximumFileBytes = 512 * 1024
        static let writeCoalesceDelay: TimeInterval = 1.5
    }

    struct Parameters: Equatable, Sendable {
        var minimumSelections: Int = Policy.minimumSelections
        var halfLife: TimeInterval = Policy.halfLife
        var priorMass: Double = Policy.priorMass
        var contextWeight: Double = Policy.contextWeight
        var sentencePrefixFactor: Double = Policy.sentencePrefixFactor
        var shortContextFactor: Double = Policy.shortContextFactor
        var maximumBonus: Double = Policy.maximumBonus
    }

    private struct Entry: Codable, Equatable {
        var ctxHash: String
        var surface: String
        var evidence: Double
        var confirmations: Int
        var updatedAt: TimeInterval
    }

    private struct Archive: Codable {
        var version = 1
        var resetID: String?
        var entries: [Entry]
    }

    static let shared = ChinesePersonalRankingCache(directory: ChinesePersonalRankingCache.defaultDirectory())

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.Voltline.Vime.ChinesePersonalRankingCache.io", qos: .utility)
    private let fileURL: URL?
    private let parameters: Parameters

    private var loaded = false
    private var entriesByKey: [String: Entry] = [:]
    private var totalEvidenceByContext: [String: Double] = [:]
    private var lastResetID: String?
    private var dirty = false
    private var pendingFlushWork: DispatchWorkItem?

    init(directory: URL?, parameters: Parameters = Parameters()) {
        self.fileURL = directory?.appendingPathComponent("ChinesePersonalRanking.json")
        self.parameters = parameters
    }

    static func defaultDirectory() -> URL? {
        let fm = FileManager.default
        let root = fm.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return root?.appendingPathComponent("Vime", isDirectory: true)
    }

    // MARK: Public API (Pure read/write hooks)

    /// Records a confirmed Chinese commit following `prevText`.
    /// Callers must pass the current `LearningExclusionPolicy` active flag.
    func record(
        prevText: String,
        committed: String,
        now: Date = Date(),
        exclusionsActive: Bool = LearningExclusionPolicy.isActive(),
        exclusionList: LearningExclusionList = .shared
    ) {
        let surface = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surface.isEmpty, surface.count <= 24, containsHan(surface) else { return }
        guard LearningExclusionPolicy.allowsLearning(surface, active: exclusionsActive, list: exclusionList),
              LearningExclusionPolicy.allowsLearning(prevText, active: exclusionsActive, list: exclusionList) else {
            return
        }

        let contexts = Self.contextHashes(from: prevText)
        guard !contexts.isEmpty else { return }

        let ts = now.timeIntervalSince1970
        lock.lock()
        ensureLoadedLocked()
        for ctx in contexts {
            recordLocked(ctxHash: ctx.hash, surface: surface, weight: 1.0, at: ts)
            // For longer sentence commits, also store leading 2- and 3-char prefixes at 0.5x
            // so future segmented typing after the same context benefits.
            if surface.count >= 4 {
                let p2 = String(surface.prefix(2))
                let p3 = String(surface.prefix(3))
                recordLocked(ctxHash: ctx.hash, surface: p2, weight: 0.5, at: ts)
                recordLocked(ctxHash: ctx.hash, surface: p3, weight: 0.5, at: ts)
            }
        }
        pruneLocked(now: ts)
        dirty = true
        scheduleFlushLocked()
        lock.unlock()
    }

    /// Computes a bounded log-probability-scale bonus (`0.0 ... Policy.maximumBonus`)
    /// for `candidate` given `prevText`. Pure O(1) in-memory lookup; never touches disk on hit.
    func bonus(prevText: String, candidate: String, now: Date = Date()) -> Double {
        let surface = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surface.isEmpty, containsHan(surface) else { return 0 }
        let contexts = Self.contextHashes(from: prevText)
        guard !contexts.isEmpty else { return 0 }

        let ts = now.timeIntervalSince1970
        lock.lock()
        ensureLoadedLocked()
        guard !entriesByKey.isEmpty else {
            lock.unlock()
            return 0
        }

        var best = 0.0
        for ctx in contexts {
            let ctxScale = ctx.isShort ? parameters.shortContextFactor : 1.0

            // 1. Exact candidate match (word or full sentence).
            let exact = scoreLocked(ctxHash: ctx.hash, surface: surface, now: ts) * ctxScale
            if exact > best { best = exact }

            // 2. Whole-sentence leading-word match: check 2-, 3-, and 4-char prefixes.
            if surface.count > 2 {
                let maxPrefix = min(4, surface.count - 1)
                for len in 2...maxPrefix {
                    let prefix = String(surface.prefix(len))
                    let prefixScore = scoreLocked(ctxHash: ctx.hash, surface: prefix, now: ts)
                        * ctxScale * parameters.sentencePrefixFactor
                    if prefixScore > best { best = prefixScore }
                }
            }
        }
        lock.unlock()
        return min(parameters.maximumBonus, best)
    }

    /// Clears cached collocations if either the global or Chinese learning reset ID changed.
    func applyResetIfNeeded(resetID: String?) {
        guard let resetID, !resetID.isEmpty else { return }
        lock.lock()
        ensureLoadedLocked()
        if lastResetID != resetID {
            entriesByKey.removeAll()
            totalEvidenceByContext.removeAll()
            lastResetID = resetID
            dirty = true
            scheduleFlushLocked(immediate: true)
        }
        lock.unlock()
    }

    /// Immediately clears all in-memory and on-disk collocation entries.
    func clear(resetID: String? = nil) {
        lock.lock()
        loaded = true
        entriesByKey.removeAll()
        totalEvidenceByContext.removeAll()
        if let resetID { lastResetID = resetID }
        pendingFlushWork?.cancel()
        pendingFlushWork = nil
        dirty = false
        let url = fileURL
        lock.unlock()

        if let url {
            ioQueue.sync {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Forces any pending coalesced write to disk immediately (used in tests and lifecycle hooks).
    func flushSynchronously() {
        lock.lock()
        pendingFlushWork?.cancel()
        pendingFlushWork = nil
        let snapshot = makeArchiveSnapshotLocked()
        dirty = false
        lock.unlock()

        if let snapshot {
            ioQueue.sync {
                self.writeArchiveToDisk(snapshot)
            }
        }
    }

    var entryCount: Int {
        lock.lock()
        ensureLoadedLocked()
        let count = entriesByKey.count
        lock.unlock()
        return count
    }

    // MARK: Context Hashing (never stores plaintext)

    private struct ContextKey {
        let hash: String
        let isShort: Bool
    }

    /// Extracts trailing Han characters from `prevText` (stopping at punctuation/whitespace)
    /// and returns up to two hashed context keys (`last4` and `last2`).
    private static func contextHashes(from prevText: String) -> [ContextKey] {
        guard !prevText.isEmpty else { return [] }
        // Take the trailing contiguous Han characters before the caret.
        let tail = String(prevText.reversed().prefix(while: { isHanCharacter($0) }).reversed())
        guard !tail.isEmpty else { return [] }

        var result: [ContextKey] = []
        if tail.count >= 4 {
            result.append(ContextKey(hash: sha256Prefix("4:" + String(tail.suffix(4))), isShort: false))
        }
        let shortLen = min(2, tail.count)
        let shortSlice = String(tail.suffix(shortLen))
        result.append(ContextKey(hash: sha256Prefix("2:" + shortSlice), isShort: true))
        return result
    }

    private static func sha256Prefix(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func isHanCharacter(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2CEAF:
                return true
            default:
                return false
            }
        }
    }

    private func containsHan(_ text: String) -> Bool {
        text.contains(where: Self.isHanCharacter)
    }

    // MARK: Scoring & Decay

    private func compositeKey(ctxHash: String, surface: String) -> String {
        ctxHash + "\0" + surface
    }

    private func decayed(_ value: Double, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, parameters.halfLife > 0 else { return value }
        return value * exp(-log(2.0) * elapsed / parameters.halfLife)
    }

    private func recordLocked(ctxHash: String, surface: String, weight: Double, at ts: TimeInterval) {
        let key = compositeKey(ctxHash: ctxHash, surface: surface)
        if var existing = entriesByKey[key] {
            let dt = max(0, ts - existing.updatedAt)
            let prevEvidence = existing.evidence
            let newEvidence = decayed(prevEvidence, elapsed: dt) + weight
            existing.evidence = newEvidence
            existing.confirmations += 1
            existing.updatedAt = ts
            entriesByKey[key] = existing
            totalEvidenceByContext[ctxHash] = max(0, (totalEvidenceByContext[ctxHash] ?? 0) - prevEvidence) + newEvidence
        } else {
            let entry = Entry(ctxHash: ctxHash, surface: surface, evidence: weight, confirmations: 1, updatedAt: ts)
            entriesByKey[key] = entry
            totalEvidenceByContext[ctxHash, default: 0] += weight
        }
    }

    private func scoreLocked(ctxHash: String, surface: String, now ts: TimeInterval) -> Double {
        let key = compositeKey(ctxHash: ctxHash, surface: surface)
        guard let entry = entriesByKey[key],
              entry.confirmations >= parameters.minimumSelections else {
            return 0
        }
        let dt = max(0, ts - entry.updatedAt)
        let ev = decayed(entry.evidence, elapsed: dt)
        guard ev > 0.05 else { return 0 }
        let totalCtx = max(ev, totalEvidenceByContext[ctxHash] ?? ev)
        // Shrink sparse contexts toward 0 via priorMass (mirrors CandidatePreferenceMemory).
        let confidence = totalCtx / (totalCtx + parameters.priorMass)
        let raw = parameters.contextWeight * log1p(ev) * confidence
        return min(parameters.maximumBonus, raw)
    }

    private func pruneLocked(now ts: TimeInterval) {
        guard entriesByKey.count > Policy.maximumEntries else { return }
        let ranked = entriesByKey.sorted { lhs, rhs in
            let lScore = decayed(lhs.value.evidence, elapsed: max(0, ts - lhs.value.updatedAt))
            let rScore = decayed(rhs.value.evidence, elapsed: max(0, ts - rhs.value.updatedAt))
            return lScore > rScore
        }
        let kept = ranked.prefix(Policy.maximumEntries)
        entriesByKey = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        rebuildContextTotalsLocked()
    }

    private func rebuildContextTotalsLocked() {
        var totals: [String: Double] = [:]
        for entry in entriesByKey.values {
            totals[entry.ctxHash, default: 0] += entry.evidence
        }
        totalEvidenceByContext = totals
    }

    // MARK: Lazy Persistence (coalesced background writes)

    private func ensureLoadedLocked() {
        guard !loaded else { return }
        loaded = true
        guard let url = fileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size <= Policy.maximumFileBytes,
              let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        lastResetID = archive.resetID
        entriesByKey.removeAll(keepingCapacity: true)
        for entry in archive.entries.prefix(Policy.maximumEntries) {
            entriesByKey[compositeKey(ctxHash: entry.ctxHash, surface: entry.surface)] = entry
        }
        rebuildContextTotalsLocked()
    }

    private func makeArchiveSnapshotLocked() -> Archive? {
        guard dirty, fileURL != nil else { return nil }
        return Archive(version: 1, resetID: lastResetID, entries: Array(entriesByKey.values))
    }

    private func scheduleFlushLocked(immediate: Bool = false) {
        guard fileURL != nil else { return }
        pendingFlushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let snapshot = self.makeArchiveSnapshotLocked()
            self.dirty = false
            self.pendingFlushWork = nil
            self.lock.unlock()
            if let snapshot {
                self.writeArchiveToDisk(snapshot)
            }
        }
        pendingFlushWork = work
        if immediate {
            ioQueue.async(execute: work)
        } else {
            ioQueue.asyncAfter(deadline: .now() + Policy.writeCoalesceDelay, execute: work)
        }
    }

    private func writeArchiveToDisk(_ archive: Archive) {
        guard let url = fileURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(archive), data.count <= Policy.maximumFileBytes else { return }
        try? data.write(to: url, options: .atomic)
    }
}
