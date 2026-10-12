import Foundation
import CryptoKit
import Darwin

/// Queue-confined, bounded memory. Persistent evidence is accepted feedback;
/// request/session evidence is removable and never written to the archive.
nonisolated final class CandidatePreferenceMemory {
    enum Policy {
        static let minimumSelections = 2
        static let halfLife: TimeInterval = 30 * 24 * 60 * 60
        static let recentHalfLife: TimeInterval = 5 * 60
        static let maximumBonus = 3.0
        static let recentLimit = 0.6
        static let contextLimit = 1.0
        static let priorMass = 4.0 // Sparse contexts shrink toward the reading's global distribution.
        static let classicWeight = 1.5
        static let maximumEntries = 2048
        static let maximumFileBytes = 4 * 1024 * 1024
        static let maximumRememberedSuggestions = 3
        static let historyAdmissionMargin = 3.0 // LogP gap from best generated word; history must be LM-compatible.
    }
    private struct Entry: Codable {
        var scope: String
        var reading: String
        var context: String
        var surface: String
        var evidence: Double
        var confirmations: Int
        var selectedAt: TimeInterval
    }
    // nil is the original generation, including v1/v2 files written before
    // clear epochs existed. Ordinary writes preserve it; only clear changes it.
    private struct Archive: Codable {
        var version = 2
        var epoch: UUID?
        var entries: [String: Entry]
    }
    private struct LegacyArchive: Decodable {
        struct Entry: Decodable { let scope: String; let context: String; let surface: String; let count: Int; let selectedAt: TimeInterval }
        let version: Int
        let entries: [String: Entry]
    }
    private struct Recent {
        let id: UUID; let scope: String; let reading: String; let context: String
        let surface: String; let weight: Double; let selectedAt: Date
    }
    private let url: URL
    private var entries: [String: Entry] = [:]
    private var populations: [String: [String: String]] = [:]
    private var recent: [Recent] = []
    private var dirty = false
    private var epoch: UUID?
    // Only this instance's delta, coalesced by key. Failed disk writes must not
    // turn a bounded learning store into an unbounded event log.
    private var pendingEvents: [String: Entry] = [:]
    private var pendingClear = false
    private(set) var persistenceError: String?
    var pendingPersistenceEntryCount: Int { pendingEvents.count }

    private enum PersistenceFailure: Error { case oversizedArchive, invalidArchive, oversizedOutput }

    init(directory: URL) {
        url = directory.appendingPathComponent("VimeSelectionFrequency.json")
        do {
            let archive = try readArchive()
            entries = archive.entries
            epoch = archive.epoch
            prune(); rebuildIndex()
        } catch { persistenceError = String(describing: error) }
    }

    private func readArchive() throws -> Archive {
        guard FileManager.default.fileExists(atPath: url.path) else { return Archive(epoch: nil, entries: [:]) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Policy.maximumFileBytes + 1) ?? Data()
        guard data.count <= Policy.maximumFileBytes else { throw PersistenceFailure.oversizedArchive }
        var decoded: [String: Entry] = [:]
        if let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 2 {
            for entry in archive.entries.values where valid(entry) { decoded[key(entry)] = entry }
            return Archive(epoch: archive.epoch, entries: decoded)
        } else if let old = try? JSONDecoder().decode(LegacyArchive.self, from: data), old.version == 1 {
            for item in old.entries.values {
                guard item.count > 0, item.count <= 1000 else { continue }
                let entry = Entry(scope: item.scope, reading: item.scope == "conversion" ? item.context : "",
                    context: item.scope == "conversion" ? "" : item.context, surface: item.surface,
                    evidence: Double(item.count), confirmations: item.count, selectedAt: item.selectedAt)
                if valid(entry) { decoded[key(entry)] = entry }
            }
            dirty = true // Migration is persisted at the next confirmation/lifecycle boundary.
            return Archive(epoch: nil, entries: decoded)
        }
        // A failed/corrupt read is not permission to replace existing history
        // with an empty snapshot. Keep pending events available for a retry.
        throw PersistenceFailure.invalidArchive
    }
    private func valid(_ e: Entry) -> Bool {
        ["conversion", "style", "nextWord"].contains(e.scope) && e.evidence.isFinite
            && e.evidence > 0 && e.evidence <= 1000 && (1...1000).contains(e.confirmations)
            && e.selectedAt.isFinite && !e.surface.isEmpty && e.surface.count <= 64
            && e.context.count <= 96 && e.reading.count <= 96
            && ![e.reading, e.surface, e.context].contains(where: { $0.contains("\0") })
    }
    private func population(_ scope: String, _ reading: String, _ context: String) -> String {
        [scope, reading, context].joined(separator: "\0")
    }
    private func key(_ e: Entry) -> String { population(e.scope, e.reading, e.context) + "\0" + e.surface }
    private func contextKey(_ context: String, length: Int = 12) -> String {
        let tail = String(context.trimmingCharacters(in: .whitespacesAndNewlines).suffix(length))
        return SHA256.hash(data: Data(tail.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func buckets(_ context: String) -> [String] {
        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [contextKey(context), "short:" + contextKey(context, length: 4)]
    }
    private func effective(_ e: Entry, now: Date) -> Double {
        e.evidence * pow(0.5, max(0, now.timeIntervalSince1970 - e.selectedAt) / Policy.halfLife)
    }
    private func bump(scope: String, reading: String, context: String, surface: String, weight: Double, now: Date) {
        let e = Entry(scope: scope, reading: reading, context: context, surface: surface,
            evidence: weight, confirmations: 1, selectedAt: now.timeIntervalSince1970)
        guard weight.isFinite, weight > 0, valid(e) else { return }
        apply(e, to: &pendingEvents)
        apply(e, to: &entries)
        dirty = true
    }
    private func apply(_ event: Entry, to target: inout [String: Entry]) {
        var e = event
        if let old = target[key(e)] {
            // Decay the accumulated evidence BEFORE adding new feedback. A new
            // selection never refreshes all historical counts to full strength.
            // Writers may flush in a different order from event timestamps.
            // Bring both contributions to the later instant, never rejuvenate.
            let instant = Date(timeIntervalSince1970: max(old.selectedAt, e.selectedAt))
            e.evidence = min(1000, effective(old, now: instant) + effective(e, now: instant))
            e.confirmations = min(1000, old.confirmations + event.confirmations)
            e.selectedAt = instant.timeIntervalSince1970
        }
        target[key(e)] = e
    }
    private func rows(scope: String, reading: String, context: String) -> [String: Entry] {
        (populations[population(scope, reading, context)] ?? [:]).compactMapValues { entries[$0] }
    }
    private func persistentScore(scope: String, reading: String, surface: String, context: String, now: Date) -> Double {
        let global = rows(scope: scope, reading: reading, context: "")
        let base = global[surface].map {
            $0.confirmations >= Policy.minimumSelections ? log1p(max(0, effective($0, now: now) - 1)) : 0
        } ?? 0
        var adjustment = 0.0
        for (level, bucket) in buckets(context).enumerated() {
            let local = rows(scope: scope, reading: reading, context: bucket)
            guard let target = local[surface], target.confirmations >= Policy.minimumSelections else { continue }
            let surfaces = Set(global.keys).union(local.keys).union([surface])
            let vocabulary = Double(max(2, surfaces.count))
            let globalTotal = global.values.reduce(0) { $0 + effective($1, now: now) }
            let prior = ((global[surface].map { effective($0, now: now) } ?? 0) + Policy.priorMass / vocabulary)
                / (globalTotal + Policy.priorMass)
            let localTotal = local.values.reduce(0) { $0 + effective($1, now: now) }
            let posterior = (effective(target, now: now) + Policy.priorMass * prior) / (localTotal + Policy.priorMass)
            // Positive evidence only: an unselected/unseen item is not a rejection.
            adjustment += (level == 0 ? 1.0 : 0.25) * max(0, log(posterior / prior))
        }
        return min(Policy.maximumBonus, base + min(Policy.contextLimit, adjustment))
    }
    private func recentScore(scope: String, reading: String, surface: String, context: String, now: Date) -> Double {
        let bucket = context.isEmpty ? "" : contextKey(context)
        let score = recent.filter { $0.scope == scope && $0.reading == reading && $0.surface == surface && $0.context == bucket }
            .reduce(0.0) { $0 + $1.weight * pow(0.5, max(0, now.timeIntervalSince($1.selectedAt)) / Policy.recentHalfLife) }
        return min(Policy.recentLimit, 0.5 * score)
    }
    func stage(id: UUID, reading: String, surface: String, context: String, scope: String = "conversion", weight: Double, now: Date = Date()) {
        guard ["conversion", "style", "nextWord"].contains(scope), !surface.isEmpty, surface.count <= 64,
              reading.count <= 96, !surface.contains("\0"), !reading.contains("\0"),
              weight.isFinite, weight > 0, now.timeIntervalSince1970.isFinite else { return }
        recent.removeAll { $0.id == id }
        recent.append(Recent(id: id, scope: scope, reading: reading,
            context: context.isEmpty ? "" : contextKey(context), surface: surface, weight: weight, selectedAt: now))
        if recent.count > CandidateLearningFeedback.Policy.maximumRecentEvents {
            recent.removeFirst(recent.count - CandidateLearningFeedback.Policy.maximumRecentEvents)
        }
    }
    func cancel(_ id: UUID) { recent.removeAll { $0.id == id } }
    func resetRecent() { recent = [] }
    func record(reading: String, surface: String, context: String = "", scope: String = "conversion", weight: Double = 1, now: Date = Date()) {
        guard !reading.isEmpty else { return }
        bump(scope: scope, reading: reading, context: "", surface: surface, weight: weight, now: now)
        for bucket in buckets(context) { bump(scope: scope, reading: reading, context: bucket, surface: surface, weight: weight, now: now) }
        prune(); rebuildIndex()
    }
    func score(reading: String, surface: String, context: String = "", scope: String = "conversion", now: Date = Date()) -> Double {
        min(Policy.maximumBonus, persistentScore(scope: scope, reading: reading, surface: surface, context: context, now: now)
            + recentScore(scope: scope, reading: reading, surface: surface, context: context, now: now))
    }
    func recordNextWord(_ text: String, context: String, weight: Double = 1, now: Date = Date()) {
        guard !context.isEmpty else { return }
        // No context-free next-word recall: frequent phrases must not leak into
        // an unrelated sentence. The shorter bucket is an explicit weak backoff.
        for bucket in buckets(context) { bump(scope: "nextWord", reading: "", context: bucket, surface: text, weight: weight, now: now) }
        prune(); rebuildIndex()
    }
    func nextWordScore(_ text: String, context: String, now: Date = Date()) -> Double {
        var score = recentScore(scope: "nextWord", reading: "", surface: text, context: context, now: now)
        for (level, bucket) in buckets(context).enumerated() {
            guard let e = rows(scope: "nextWord", reading: "", context: bucket)[text], e.confirmations >= Policy.minimumSelections else { continue }
            score += (level == 0 ? 1.0 : 0.25) * log1p(max(0, effective(e, now: now) - 1))
        }
        return min(Policy.maximumBonus, score)
    }
    func rememberedNextWords(context: String, now: Date = Date()) -> [String] {
        var surfaces = Set<String>()
        for (level, bucket) in buckets(context).enumerated() {
            for e in rows(scope: "nextWord", reading: "", context: bucket).values
                where e.confirmations >= (level == 0 ? 2 : 3) && effective(e, now: now) > 1 { surfaces.insert(e.surface) }
        }
        // A provisional event is only recalled in its exact session context.
        surfaces.formUnion(recent.filter { $0.scope == "nextWord" && $0.context == contextKey(context)
            && now.timeIntervalSince($0.selectedAt) <= Policy.recentHalfLife * 2 }.map(\.surface))
        return Array(surfaces.sorted {
            let a = nextWordScore($0, context: context, now: now), b = nextWordScore($1, context: context, now: now)
            return a == b ? $0 < $1 : a > b
        }.prefix(Policy.maximumRememberedSuggestions))
    }
    func nextWords(_ generated: [ScoredNextWord], history: [ScoredNextWord], context: String, now: Date = Date()) -> [NextWordSuggestion] {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.personalization, since: started) }
        let best = generated.map(\.logProbabilitySum).max()
        var pool: [String: NextWordSuggestion] = [:]
        for (isHistory, words) in [(false, generated), (true, history)] {
            for word in words where word.logProbabilitySum.isFinite && !word.text.isEmpty {
                if isHistory, let best, word.logProbabilitySum < best - Policy.historyAdmissionMargin { continue }
                // No unscored history fallback when the LM request failed.
                let user = nextWordScore(word.text, context: context, now: now)
                let value = NextWordSuggestion(text: word.text, source: isHistory ? .userHistory : .contextPrediction,
                    score: word.logProbabilitySum + user, userScore: user,
                    modelScore: word.logProbabilitySum, tokenCount: word.tokenCount)
                if let old = pool[word.text], old.score >= value.score { continue }
                pool[word.text] = value
            }
        }
        let order = Dictionary(generated.enumerated().map { ($0.element.text, $0.offset) }, uniquingKeysWith: min)
        return Array(pool.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = order[$0.text] ?? generated.count, b = order[$1.text] ?? generated.count
            return a == b ? $0.text < $1.text : a < b
        }.prefix(5))
    }
    private func prune() {
        trim(&entries)
        trim(&pendingEvents)
    }
    private func trim(_ store: inout [String: Entry]) {
        if store.count > Policy.maximumEntries {
            let keep = store.values.sorted {
                $0.selectedAt == $1.selectedAt ? key($0) < key($1) : $0.selectedAt > $1.selectedAt
            }.prefix(Policy.maximumEntries)
            store = Dictionary(uniqueKeysWithValues: keep.map { (key($0), $0) })
        }
    }
    private func rebuildIndex() {
        populations = [:]
        for (key, e) in entries { populations[population(e.scope, e.reading, e.context), default: [:]][e.surface] = key }
    }
    func flush() {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Lock a separate, persistent inode: atomic replacement of the JSON
            // must not replace the lock itself. flock coordinates other processes
            // as well as live instances, regardless of their worker queues.
            let lockURL = url.appendingPathExtension("lock")
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            var locked: Int32
            repeat { locked = flock(descriptor, LOCK_EX) } while locked != 0 && errno == EINTR
            guard locked == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { _ = flock(descriptor, LOCK_UN) }
            let latest = pendingClear ? Archive(epoch: epoch, entries: [:]) : try readArchive()
            if !pendingClear && latest.epoch != epoch {
                // Another instance cleared history. Discard this old generation's
                // pending feedback instead of resurrecting data the user removed.
                entries = latest.entries; epoch = latest.epoch; recent = []
            } else {
                var merged = latest.entries
                for event in pendingEvents.values { apply(event, to: &merged) }
                let previous = entries
                entries = merged; prune()
                do {
                    let data = try JSONEncoder().encode(Archive(epoch: epoch, entries: entries))
                    guard data.count <= Policy.maximumFileBytes else { throw PersistenceFailure.oversizedOutput }
                    try data.write(to: url, options: .atomic)
                } catch { entries = previous; throw error }
            }
            pendingEvents = [:]; pendingClear = false; dirty = false
            rebuildIndex(); persistenceError = nil
        } catch { persistenceError = String(describing: error) }
    }
    func clear() {
        entries = [:]; populations = [:]; recent = []; pendingEvents = [:]
        epoch = UUID(); pendingClear = true; dirty = true; flush()
    }
}

nonisolated struct ScoredNextWord: Sendable {
    let text: String
    let logProbabilitySum: Double
    let tokenCount: Int
}

nonisolated struct NextWordSuggestion: Sendable {
    let text: String
    let source: CandidateSource
    var score: Double
    let userScore: Double
    var modelScore: Double? = nil
    var tokenCount: Int? = nil
    var nativePrediction: NativePostCompositionPrediction? = nil
    var presentation: CandidatePresentation {
        let replacementAnnotation = nativePrediction.flatMap { $0.isReplacement ? "替换「\($0.replacedText)」" : nil }
        return .init(text: text, source: source, consumedInputCount: 0, correction: nil,
            detailAnnotation: replacementAnnotation ?? (source == .emoji ? "表情" : nil))
    }
}
