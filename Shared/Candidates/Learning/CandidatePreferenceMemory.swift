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
        // Each tier can borrow unused capacity from the other. Context hashes
        // must not consume the entire store and evict every global preference.
        static let reservedGlobalEntries = 1024
        static let maximumFileBytes = 4 * 1024 * 1024
        static let maximumRememberedSuggestions = 3
        static let historyAdmissionMargin = 3.0 // LogP gap from best generated word; history must be LM-compatible.
        static let maximumChoiceBonus = 6.0
        // Backoff is a soft prior in a new sentence: one score unit becomes
        // 1.5 log-probability units (about 4.5:1 odds), never a model veto.
        static let maximumBackoffModelScore = 1.0
        static let familiarCandidateVisibility = 3
        static func rankingBonus(score: Double, confidence: Double) -> Double {
            score * classicWeight + (confidence >= 0.65 ? 3 * confidence : 0)
        }
    }
    private struct Confirmation: Codable {
        let weight: Double
        let selectedAt: TimeInterval
    }
    private struct Entry: Codable {
        var scope: String
        var reading: String
        var context: String
        var surface: String
        var evidence: Double
        var confirmations: Int
        var selectedAt: TimeInterval
        // Only the last three deliberate confirmations qualify order protection.
        // Frequency evidence above remains independent and is never reset.
        var protection: [Confirmation]? = nil
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
    private struct ContextKeys {
        let full: String
        let buckets: [String]
    }
    // Cache derived keys, never scores: new feedback must affect the very next
    // query. A short FIFO also covers word-prefix contexts during sentence ranking.
    private var contextKeysByTail: [Data: ContextKeys] = [:]
    private var contextKeyOrder: [Data] = []
    private var dirty = false
    private var epoch: UUID?
    var clearEpoch: UUID? { epoch }
    // Only this instance's delta, coalesced by key. Failed disk writes must not
    // turn a bounded learning store into an unbounded event log.
    private var pendingEvents: [String: Entry] = [:]
    private var pendingClear = false
    private struct Revision: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            seconds = value.st_mtimespec.tv_sec; nanoseconds = value.st_mtimespec.tv_nsec
        }
    }
    private var loadedRevision: Revision?
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
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadedRevision = nil
            return Archive(epoch: nil, entries: [:])
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(handle.fileDescriptor, &metadata) == 0 else { throw POSIXError(.EIO) }
        let data = try handle.read(upToCount: Policy.maximumFileBytes + 1) ?? Data()
        guard data.count <= Policy.maximumFileBytes else { throw PersistenceFailure.oversizedArchive }
        var decoded: [String: Entry] = [:]
        if let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 2 {
            for entry in archive.entries.values where valid(entry) { decoded[key(entry)] = entry }
            loadedRevision = Revision(metadata)
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
            loadedRevision = Revision(metadata)
            return Archive(epoch: nil, entries: decoded)
        }
        // A failed/corrupt read is not permission to replace existing history
        // with an empty snapshot. Keep pending events available for a retry.
        throw PersistenceFailure.invalidArchive
    }

    /// Check once per candidate request, on the worker queue. Unchanged files
    /// need only stat(); atomic replacement changes the inode. fstat() above
    /// identifies the actual file read even if another writer replaces it.
    func refreshIfChanged() {
        guard !pendingClear else { return }
        var metadata = stat()
        let status = stat(url.path, &metadata)
        guard status == 0 || errno == ENOENT else { return }
        let revision = status == 0 ? Revision(metadata) : nil
        guard revision != loadedRevision else { return }
        do {
            let latest = try readArchive()
            if latest.epoch != epoch {
                pendingEvents = [:]; recent = []; dirty = false
            }
            epoch = latest.epoch
            entries = latest.entries
            for event in pendingEvents.values { apply(event, to: &entries) }
            prune(); rebuildIndex(); persistenceError = nil
        } catch { persistenceError = String(describing: error) }
    }
    private func valid(_ e: Entry) -> Bool {
        ["conversion", "style", "nextWord", "choice", "wordChoice"].contains(e.scope) && e.evidence.isFinite
            && e.evidence > 0 && e.evidence <= 1000 && (1...1000).contains(e.confirmations)
            && e.selectedAt.isFinite && !e.surface.isEmpty && e.surface.count <= 64
            && e.context.count <= 96 && e.reading.count <= 96
            && ![e.reading, e.surface, e.context].contains(where: { $0.contains("\0") })
            && (e.protection.map { $0.count <= 3 && $0.allSatisfy {
                $0.weight.isFinite && $0.weight > 0 && $0.weight <= 1000
                    && $0.selectedAt.isFinite && $0.selectedAt <= e.selectedAt
            } } ?? true)
    }
    private func population(_ scope: String, _ reading: String, _ context: String) -> String {
        [scope, reading, context].joined(separator: "\0")
    }
    private func key(_ e: Entry) -> String { population(e.scope, e.reading, e.context) + "\0" + e.surface }
    private static func digest(_ data: Data) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: data) { bytes.append(hex[Int(byte >> 4)]); bytes.append(hex[Int(byte & 15)]) }
        return String(decoding: bytes, as: UTF8.self)
    }
    private func contextKeys(_ context: String) -> ContextKeys {
        let tail = String(context.trimmingCharacters(in: .whitespacesAndNewlines).suffix(12))
        // Archives hash UTF-8 bytes. Swift String equality also merges canonically
        // equivalent spellings, which must not alias two existing archive keys.
        let bytes = Data(tail.utf8)
        if let keys = contextKeysByTail[bytes] { return keys }
        let full = Self.digest(bytes)
        let keys = ContextKeys(full: full, buckets: tail.isEmpty ? [] : [full, "short:" + Self.digest(Data(tail.suffix(4).utf8))])
        if bytes.count <= 1024 {
            if contextKeyOrder.count == 32 { contextKeysByTail.removeValue(forKey: contextKeyOrder.removeFirst()) }
            contextKeyOrder.append(bytes)
            contextKeysByTail[bytes] = keys
        }
        return keys
    }
    private func contextKey(_ context: String) -> String { contextKeys(context).full }
    private func buckets(_ context: String) -> [String] {
        contextKeys(context).buckets
    }
    private func effective(_ e: Entry, now: Date) -> Double {
        e.evidence * pow(0.5, max(0, now.timeIntervalSince1970 - e.selectedAt) / Policy.halfLife)
    }
    private func bump(scope: String, reading: String, context: String, surface: String, weight: Double, now: Date) {
        let e = Entry(scope: scope, reading: reading, context: context, surface: surface,
            evidence: weight, confirmations: 1, selectedAt: now.timeIntervalSince1970,
            protection: scope == "choice" ? [Confirmation(weight: weight, selectedAt: now.timeIntervalSince1970)] : nil)
        guard weight.isFinite, weight > 0, valid(e) else { return }
        apply(e, to: &pendingEvents)
        apply(e, to: &entries)
        populations[population(scope, reading, context), default: [:]][surface] = key(e)
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
            if e.scope == "choice" {
                e.protection = Array((protectionEvents(old) + protectionEvents(event)).sorted {
                    $0.selectedAt == $1.selectedAt ? $0.weight < $1.weight : $0.selectedAt < $1.selectedAt
                }.suffix(3))
            }
        }
        target[key(e)] = e
    }
    private func protectionEvents(_ entry: Entry) -> [Confirmation] {
        // Older archives do not contain consecutive-confirmation timestamps.
        // Retain their frequency, but credit only one known latest selection.
        entry.protection ?? [Confirmation(weight: min(1, entry.evidence), selectedAt: entry.selectedAt)]
    }
    private func rows(scope: String, reading: String, context: String) -> [String: Entry] {
        (populations[population(scope, reading, context)] ?? [:]).compactMapValues { entries[$0] }
    }

    // Request-local aggregates. Recall scores every remembered surface, so
    // recomputing totals/latest choices per surface would be quadratic.
    private struct EvidencePopulation {
        let entries: [String: Entry]
        let weights: [String: Double]
        let total: Double
        let latest: TimeInterval
        let latestCount: Int
        let protectionSupport: [String: Double]
    }
    private func evidencePopulation(_ values: [String: Entry], now: Date) -> EvidencePopulation {
        let weights = values.mapValues { effective($0, now: now) }
        let latest = values.values.map(\.selectedAt).max() ?? -.infinity
        let latestCount = values.values.filter { $0.selectedAt == latest }.count
        let competitor = values.values.filter { $0.selectedAt < latest }.map(\.selectedAt).max() ?? -.infinity
        var protection: [String: Double] = [:]
        if latestCount == 1, let selected = values.values.first(where: { $0.selectedAt == latest }), selected.scope == "choice" {
            protection[selected.surface] = protectionEvents(selected).filter { $0.selectedAt > competitor }.reduce(0) {
                $0 + $1.weight * pow(0.5, max(0, now.timeIntervalSince1970 - $1.selectedAt) / Policy.halfLife)
            }
        }
        return EvidencePopulation(entries: values, weights: weights, total: weights.values.reduce(0, +),
            latest: latest, latestCount: latestCount, protectionSupport: protection)
    }
    private struct ConversionDistribution {
        struct Context {
            let population: EvidencePopulation
            let vocabulary: Double
            let weight: Double
        }
        let global: EvidencePopulation
        let contexts: [Context]
        func score(_ surface: String) -> Double {
            let base = global.entries[surface].map {
                $0.confirmations >= Policy.minimumSelections ? log1p(max(0, global.weights[surface, default: 0] - 1)) : 0
            } ?? 0
            var adjustment = 0.0
            for context in contexts {
                let local = context.population
                guard let target = local.entries[surface], target.confirmations >= Policy.minimumSelections else { continue }
                let prior = (global.weights[surface, default: 0] + Policy.priorMass / context.vocabulary)
                    / (global.total + Policy.priorMass)
                let posterior = (local.weights[surface, default: 0] + Policy.priorMass * prior) / (local.total + Policy.priorMass)
                adjustment += context.weight * max(0, log(posterior / prior))
            }
            return min(Policy.maximumBonus, base + min(Policy.contextLimit, adjustment))
        }
    }
    private func conversionDistribution(scope: String, reading: String, context: String, now: Date) -> ConversionDistribution {
        let global = evidencePopulation(rows(scope: scope, reading: reading, context: ""), now: now)
        let contexts = buckets(context).enumerated().map { level, bucket in
            let local = evidencePopulation(rows(scope: scope, reading: reading, context: bucket), now: now)
            return ConversionDistribution.Context(population: local,
                vocabulary: Double(max(2, Set(global.entries.keys).union(local.entries.keys).count)),
                weight: level == 0 ? 1 : 0.25)
        }
        return ConversionDistribution(global: global, contexts: contexts)
    }
    private struct ChoiceDistribution {
        let global: EvidencePopulation
        let local: EvidencePopulation
        let contextual: Bool
        let exactContext: Bool
        let confidenceLimit: Double
        let requiredSupport: Double
        func preference(_ surface: String, word: Bool = false) -> ChoicePreference {
            let evidence = global.weights[surface, default: 0]
            guard evidence > 0 else { return ChoicePreference() }
            var bonus = min(4, 2.4 * log1p(evidence))
            var confidence = 0.0
            let support = local.weights[surface, default: 0]
            if contextual { bonus += min(2, 1.5 * log1p(support)) }
            if support > 0, let selected = local.entries[surface] {
                let strength = min(confidenceLimit, local.protectionSupport[surface, default: 0] / requiredSupport)
                if selected.selectedAt == local.latest {
                    confidence = local.latestCount == 1 ? strength : strength * support / max(support, local.total)
                } else { bonus *= 0.25 }
            } else if contextual { bonus *= 0.25 }
            return ChoicePreference(bonus: word ? min(1.5, bonus * 0.35) : min(Policy.maximumChoiceBonus, bonus),
                confidence: word ? 0 : confidence, matchesExactContext: exactContext)
        }
    }
    private func choiceDistribution(scope: String, reading: String, context: String, now: Date) -> ChoiceDistribution {
        let global = evidencePopulation(rows(scope: scope, reading: reading, context: ""), now: now)
        guard !global.entries.isEmpty else {
            return ChoiceDistribution(global: global, local: global, contextual: false, exactContext: false, confidenceLimit: 0, requiredSupport: 2)
        }
        // The closest context containing any choices overrides global recency.
        for (level, bucket) in buckets(context).enumerated() {
            let values = rows(scope: scope, reading: reading, context: bucket)
            if !values.isEmpty {
                return ChoiceDistribution(global: global, local: evidencePopulation(values, now: now), contextual: true, exactContext: level == 0,
                    confidenceLimit: level == 0 ? 1 : 0.85, requiredSupport: 2)
            }
        }
        return ChoiceDistribution(global: global, local: global, contextual: false, exactContext: false,
            confidenceLimit: context.isEmpty ? 1 : 0.8, requiredSupport: context.isEmpty ? 2 : 3)
    }

    /// Recall accepted surface/reading pairs independently of native N-best.
    /// Provisional feedback is deliberately excluded. One deliberate choice is
    /// sufficient; passive confirmations and shared word evidence need repeats.
    func rememberedConversions(reading: String, context: String, now: Date = Date()) -> [String] {
        guard !entries.isEmpty else { return [] }
        let reading = reading.precomposedStringWithCanonicalMapping
        guard (1...96).contains(reading.count), reading.unicodeScalars.allSatisfy({
            (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC
        }) else { return [] }
        let choices = choiceDistribution(scope: "choice", reading: reading, context: context, now: now)
        let conversions = conversionDistribution(scope: "conversion", reading: reading, context: context, now: now)
        let words = choiceDistribution(scope: "wordChoice", reading: reading, context: context, now: now)
        let surfaces = Set(choices.global.entries.keys).union(conversions.global.entries.keys).union(words.global.entries.keys)
        let recalled = surfaces.compactMap { surface -> (surface: String, score: Double, date: TimeInterval)? in
            guard !surface.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            let choice = choices.global.entries[surface]
            let repeated = [conversions.global.entries[surface], words.global.entries[surface]].compactMap { $0 }.filter {
                $0.confirmations >= Policy.minimumSelections && effective($0, now: now) > 1
            }
            guard choice.map({ effective($0, now: now) >= 0.5 }) == true || !repeated.isEmpty else { return nil }
            let score = choices.preference(surface).bonus + conversions.score(surface) + words.preference(surface, word: true).bonus
            return (surface, score, ([choice].compactMap { $0 } + repeated).map(\.selectedAt).max() ?? 0)
        }
        return recalled.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.surface < $1.surface
        }.prefix(Policy.maximumRememberedSuggestions).map(\.surface)
    }
    private func persistentScore(scope: String, reading: String, surface: String, context: String, now: Date) -> Double {
        guard !entries.isEmpty else { return 0 }
        guard populations[population(scope, reading, "")]?[surface] != nil
            || buckets(context).contains(where: { populations[population(scope, reading, $0)]?[surface] != nil }) else { return 0 }
        return conversionDistribution(scope: scope, reading: reading, context: context, now: now).score(surface)
    }
    private func recentScore(scope: String, reading: String, surface: String, context: String, now: Date) -> Double {
        guard !recent.isEmpty else { return 0 }
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
        pruneRecordedEntries()
    }
    func score(reading: String, surface: String, context: String = "", scope: String = "conversion", now: Date = Date()) -> Double {
        min(Policy.maximumBonus, persistentScore(scope: scope, reading: reading, surface: surface, context: context, now: now)
            + recentScore(scope: scope, reading: reading, surface: surface, context: context, now: now))
    }

    struct ChoicePreference {
        var bonus = 0.0
        var confidence = 0.0
        var matchesExactContext = false
    }

    /// Deliberate selections have their own evidence, separate from accepting
    /// the default result. Existing archives and weak automatic feedback keep
    /// their original interpretation. Context keys remain hashed on disk.
    func choicePreference(reading: String, surface: String, context: String, word: Bool = false,
                          now: Date = Date()) -> ChoicePreference {
        let scope = word ? "wordChoice" : "choice"
        guard let key = populations[population(scope, reading, "")]?[surface], let entry = entries[key],
              effective(entry, now: now) > 0 else { return ChoicePreference() }
        return choiceDistribution(scope: scope, reading: reading, context: context, now: now)
            .preference(surface, word: word)
    }
    func recordNextWord(_ text: String, context: String, weight: Double = 1, now: Date = Date()) {
        guard !context.isEmpty else { return }
        // No context-free next-word recall: frequent phrases must not leak into
        // an unrelated sentence. The shorter bucket is an explicit weak backoff.
        for bucket in buckets(context) { bump(scope: "nextWord", reading: "", context: bucket, surface: text, weight: weight, now: now) }
        pruneRecordedEntries()
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
    private func pruneRecordedEntries() {
        for entry in prune() {
            let group = population(entry.scope, entry.reading, entry.context)
            populations[group]?.removeValue(forKey: entry.surface)
            if populations[group]?.isEmpty == true { populations.removeValue(forKey: group) }
        }
    }
    // Archive replacement rebuilds its index only after a successful read/write.
    // Recording can instead remove just the entries evicted from the live index.
    @discardableResult private func prune() -> [Entry] {
        let removed = trim(&entries)
        _ = trim(&pendingEvents)
        return removed
    }
    private func trim(_ store: inout [String: Entry]) -> [Entry] {
        guard store.count > Policy.maximumEntries else { return [] }
        // Stored keys are already canonical archive keys. Reconstructing them
        // during every tie comparison is costly when one confirmation records
        // several words at the same timestamp.
        let recent = store.sorted {
            $0.value.selectedAt == $1.value.selectedAt ? $0.key < $1.key : $0.value.selectedAt > $1.value.selectedAt
        }
        let globals = recent.filter { $0.value.context.isEmpty }
        let contexts = recent.filter { !$0.value.context.isEmpty }
        let globalLimit = min(globals.count, max(Policy.reservedGlobalEntries, Policy.maximumEntries - contexts.count))
        // Protect frequent global habits, while leaving at least half of this
        // tier open to recent changes. Log evidence plus timestamp is the same
        // ordering as decayed evidence, without underflow for old archives.
        let decayRate = log(2.0) / Policy.halfLife
        let priorities: [(key: String, priority: Double)] = globals.map { item in
            (key: item.key, priority: log(item.value.evidence) + item.value.selectedAt * decayRate)
        }
        let frequent = priorities.sorted {
            $0.priority == $1.priority ? $0.key < $1.key : $0.priority > $1.priority
        }.prefix(globalLimit / 2)
        var retained = Set(frequent.map(\.key))
        for item in globals where retained.count < globalLimit { retained.insert(item.key) }
        retained.formUnion(contexts.prefix(Policy.maximumEntries - globalLimit).map(\.key))
        let removed = recent.filter { !retained.contains($0.key) }
        for (key, _) in removed { store.removeValue(forKey: key) }
        return removed.map(\.value)
    }
    private func rebuildIndex() {
        populations = [:]
        for (key, e) in entries { populations[population(e.scope, e.reading, e.context), default: [:]][e.surface] = key }
    }
    func flush() {
        guard dirty else { refreshIfChanged(); return }
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
            let lockStartedAt = KeyboardPerformance.start()
            repeat { locked = flock(descriptor, LOCK_EX) } while locked != 0 && errno == EINTR
            KeyboardPerformance.record(.learningLockWait, since: lockStartedAt)
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
                    var metadata = stat()
                    loadedRevision = stat(url.path, &metadata) == 0 ? Revision(metadata) : nil
                } catch { entries = previous; loadedRevision = nil; throw error }
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
