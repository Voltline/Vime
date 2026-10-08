import Foundation
import CryptoKit

/// Small, queue-confined preference memory. AzooKey still learns real candidates;
/// this supplies evidence the neural reranker and next-word generator cannot see.
nonisolated final class CandidatePreferenceMemory {
    enum Policy {
        static let minimumSelections = 2
        static let halfLife: TimeInterval = 30 * 24 * 60 * 60
        static let maximumBonus = 3.0 // Log-probability units; stronger LM evidence can win.
        static let frequencyWeight = 1.0
        static let classicWeight = 1.5
        static let nextWordOrderWeight = 0.18
        static let maximumEntries = 2048
        static let maximumFileBytes = 4 * 1024 * 1024
        static let maximumRememberedSuggestions = 3
    }
    private struct Entry: Codable {
        var scope: String
        var context: String
        var surface: String
        var count: Int
        var selectedAt: TimeInterval
    }
    private struct Archive: Codable {
        var version = 1
        var entries: [String: Entry]
    }
    private let url: URL
    private var entries: [String: Entry] = [:]
    private var dirty = false

    init(directory: URL) {
        url = directory.appendingPathComponent("VimeSelectionFrequency.json")
        if let handle = try? FileHandle(forReadingFrom: url),
           let data = try? handle.read(upToCount: Policy.maximumFileBytes + 1), data.count <= Policy.maximumFileBytes,
           let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 {
            try? handle.close()
            entries = archive.entries.filter { _, e in
                e.count > 0 && e.count <= 1000 && e.selectedAt.isFinite
                    && !e.surface.isEmpty && e.surface.count <= 64 && e.context.count <= 96
            }
            prune()
        }
    }
    private func key(scope: String, context: String, surface: String) -> String {
        scope + "\u{0}" + context + "\u{0}" + surface
    }
    private func contextKey(_ context: String) -> String {
        let tail = String(context.trimmingCharacters(in: .whitespacesAndNewlines).suffix(12))
        return SHA256.hash(data: Data(tail.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func record(scope: String, context: String, surface: String, now: Date) {
        guard !surface.isEmpty, surface.count <= 64, context.count <= 96 else { return }
        let identity = key(scope: scope, context: context, surface: surface)
        let count = min(1000, (entries[identity]?.count ?? 0) + 1)
        entries[identity] = Entry(scope: scope, context: context, surface: surface,
                                  count: count, selectedAt: now.timeIntervalSince1970)
        dirty = true
        prune()
    }
    private func score(_ entry: Entry?, now: Date) -> Double {
        guard let entry, entry.count >= Policy.minimumSelections else { return 0 }
        let age = max(0, now.timeIntervalSince1970 - entry.selectedAt)
        let decay = pow(0.5, age / Policy.halfLife)
        return min(Policy.maximumBonus, Policy.frequencyWeight * log1p(Double(entry.count - 1))) * decay
    }
    func record(reading: String, surface: String, now: Date = Date()) {
        guard !reading.isEmpty else { return }
        record(scope: "conversion", context: reading, surface: surface, now: now)
    }
    func score(reading: String, surface: String, now: Date = Date()) -> Double {
        score(entries[key(scope: "conversion", context: reading, surface: surface)], now: now)
    }
    func recordNextWord(_ text: String, context: String, now: Date = Date()) {
        guard !context.isEmpty else { return }
        record(scope: "nextWord", context: contextKey(context), surface: text, now: now)
    }
    func nextWords(_ generated: [String], context: String, now: Date = Date()) -> [NextWordSuggestion] {
        let bucket = contextKey(context)
        let remembered = entries.values.filter {
            $0.scope == "nextWord" && $0.context == bucket && score($0, now: now) > 0
        }.sorted {
            let a = score($0, now: now), b = score($1, now: now)
            return a == b ? $0.surface < $1.surface : a > b
        }.prefix(Policy.maximumRememberedSuggestions)
        var pool: [String: NextWordSuggestion] = [:]
        for (index, text) in generated.enumerated() {
            let preference = score(entries[key(scope: "nextWord", context: bucket, surface: text)], now: now)
            pool[text] = NextWordSuggestion(text: text, source: .contextPrediction,
                score: -Double(index) * Policy.nextWordOrderWeight + preference, userScore: preference)
        }
        for entry in remembered where pool[entry.surface] == nil {
            let preference = score(entry, now: now)
            pool[entry.surface] = NextWordSuggestion(text: entry.surface, source: .userHistory,
                score: -Double(generated.count) * Policy.nextWordOrderWeight + preference, userScore: preference)
        }
        return Array(pool.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            // Keep model order for ties, then use a deterministic surface order.
            let a = generated.firstIndex(of: $0.text) ?? generated.count
            let b = generated.firstIndex(of: $1.text) ?? generated.count
            return a == b ? $0.text < $1.text : a < b
        }.prefix(5))
    }
    private func prune() {
        if entries.count > Policy.maximumEntries {
            let keep = entries.sorted { $0.value.selectedAt > $1.value.selectedAt }.prefix(Policy.maximumEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
    /// Confirmation/reset boundaries only. Never invoked by a keystroke query.
    func flush() {
        guard dirty, let data = try? JSONEncoder().encode(Archive(entries: entries)) else { return }
        do { try data.write(to: url, options: .atomic); dirty = false } catch { }
    }
    func clear() {
        entries = [:]; dirty = true; flush()
    }
}

nonisolated struct NextWordSuggestion: Sendable {
    let text: String
    let source: CandidateSource
    let score: Double
    let userScore: Double
    var presentation: CandidatePresentation {
        .init(text: text, source: source, consumedInputCount: 0, correction: nil)
    }
}
