import CoreGraphics
import Foundation

/// Per-key independent EMA touch-target calibration, bucketed by explicit UI layout.
///
/// Design constraints:
/// - Visual keycaps never move; only the invisible hit-resolution center shifts.
/// - No hand-posture inference and no hierarchical multi-level backoff: each
///   `(layoutBucket, letter)` adapts strictly from its own clean observations.
/// - Bounded, anonymous geometric logs (`Calibration/state.json` and
///   `Calibration/observations.jsonl` in the App Group container) allow offline
///   evaluation without ever storing typed text.
nonisolated final class KeyHitCalibration: @unchecked Sendable {
    enum LayoutBucket: String, Codable, CaseIterable, Sendable {
        case portrait
        case oneHandedLeft
        case oneHandedRight
        case landscape
        case pad
    }

    struct KeyStats: Codable, Equatable, Sendable {
        /// Normalized EMA offset relative to the key's painted body center (`(x - midX) / width`).
        var dx: Double = 0
        /// Normalized EMA offset relative to the key's painted body center (`(y - midY) / height`).
        var dy: Double = 0
        /// Number of accepted training samples for this key in this bucket.
        var count: Int = 0
    }

    struct Summary: Codable, Equatable, Sendable {
        var totalTaps: Int = 0
        var committedSamples: Int = 0
        var neighborFixSamples: Int = 0
        var rejectedOutliers: Int = 0
        var calibrationSwitches: Int = 0
        var languageCorrections: Int = 0
    }

    struct Snapshot: Codable, Equatable, Sendable {
        var version: Int = 1
        var updatedAt: Date = Date()
        var buckets: [String: [String: KeyStats]] = [:]
        var summary: Summary = Summary()
    }

    struct Observation: Codable, Sendable {
        let ts: TimeInterval
        let bucket: String
        let kind: String // "tap", "commit", "neighbor_fix"
        let key: String
        let rawKey: String?
        let dx: Double
        let dy: Double
        let effDx: Double
        let effDy: Double
        let count: Int
        let calSwitched: Bool
        let langCorrected: Bool
    }

    // MARK: - Tuning & Safety Guards

    /// Minimum clean samples for a key before its calibration begins to fade in.
    static let minSamples = 15
    /// Sample count at which a key reaches full (100%) calibration weight.
    static let fullWeightSamples = 30
    /// Steady-state EMA learning rate for normal committed taps.
    static let commitAlpha = 0.04
    /// Stronger EMA learning rate for explicit neighbor-backspace self-corrections.
    static let neighborFixAlpha = 0.10
    /// Outlier rejection bounds (normalized to key width / height).
    static let maxAcceptedDx = 1.10
    static let maxAcceptedDy = 1.00
    /// Hard clamp on stored per-key offset (normalized to key width / height).
    static let maxOffsetDx = 0.25
    static let maxOffsetDy = 0.20
    /// Maximum byte size for `observations.jsonl` before trimming to newest half.
    static let maxLogBytes = 512 * 1024

    static let shared = KeyHitCalibration(directory: KeyHitCalibration.defaultDirectory())

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.Voltline.Vime.KeyHitCalibration.io", qos: .utility)
    private let directory: URL?
    private var snapshot: Snapshot
    private var pendingObservations: [Observation] = []
    private var updatesSinceFlush = 0
    private var dirty = false

    static func defaultDirectory() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup)?
            .appendingPathComponent("Calibration", isDirectory: true)
    }

    init(directory: URL?) {
        self.directory = directory
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let url = directory?.appendingPathComponent("state.json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(Snapshot.self, from: data) {
            self.snapshot = decoded
        } else {
            self.snapshot = Snapshot()
        }
    }

    // MARK: - Query

    /// Effective normalized `(dx, dy)` offset for `letter` in `bucket`, after cold-start fade-in.
    /// Returns `(0, 0)` until `letter` has accumulated at least `minSamples` clean samples.
    func effectiveNormalizedOffset(for letter: Character, in bucket: LayoutBucket) -> (dx: Double, dy: Double) {
        let key = String(letter).lowercased()
        lock.lock()
        let stats = snapshot.buckets[bucket.rawValue]?[key]
        lock.unlock()
        guard let stats, stats.count >= Self.minSamples else { return (0, 0) }
        let span = max(1, Self.fullWeightSamples - Self.minSamples)
        let weight = min(1.0, Double(stats.count - Self.minSamples) / Double(span))
        return (stats.dx * weight, stats.dy * weight)
    }

    /// Effective offset in points for `letter` given its painted `body`.
    func effectivePointOffset(for letter: Character, body: CGRect, in bucket: LayoutBucket) -> CGPoint {
        guard body.width > 0, body.height > 0 else { return .zero }
        let norm = effectiveNormalizedOffset(for: letter, in: bucket)
        return CGPoint(x: CGFloat(norm.dx) * body.width, y: CGFloat(norm.dy) * body.height)
    }

    func currentSnapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    // MARK: - Recording & Learning

    /// Logs a raw tap observation (without updating the EMA model yet; model updates happen
    /// only on clean commit or explicit neighbor-backspace correction).
    func recordTapObservation(
        letter: Character,
        rawLetter: Character?,
        point: CGPoint,
        body: CGRect,
        bucket: LayoutBucket,
        calibrationSwitched: Bool,
        languageCorrected: Bool,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        guard body.width > 0, body.height > 0 else { return }
        let dx = Double((point.x - body.midX) / body.width)
        let dy = Double((point.y - body.midY) / body.height)
        let key = String(letter).lowercased()
        let rawKey = rawLetter.map { String($0).lowercased() }

        lock.lock()
        snapshot.summary.totalTaps += 1
        if calibrationSwitched { snapshot.summary.calibrationSwitches += 1 }
        if languageCorrected { snapshot.summary.languageCorrections += 1 }
        let stats = snapshot.buckets[bucket.rawValue]?[key] ?? KeyStats()
        let eff = Self.effectiveOffset(from: stats)
        pendingObservations.append(Observation(
            ts: timestamp,
            bucket: bucket.rawValue,
            kind: "tap",
            key: key,
            rawKey: rawKey == key ? nil : rawKey,
            dx: Self.round4(dx),
            dy: Self.round4(dy),
            effDx: Self.round4(eff.dx),
            effDy: Self.round4(eff.dy),
            count: stats.count,
            calSwitched: calibrationSwitched,
            langCorrected: languageCorrected
        ))
        dirty = true
        updatesSinceFlush += 1
        let shouldFlush = updatesSinceFlush >= 25
        lock.unlock()
        if shouldFlush { flushAsync() }
    }

    /// Updates the independent per-key EMA for a cleanly committed letter tap.
    @discardableResult
    func learnCommittedTap(
        letter: Character,
        point: CGPoint,
        body: CGRect,
        bucket: LayoutBucket,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        learn(letter: letter, rawLetter: nil, point: point, body: body, bucket: bucket,
              isNeighborFix: false, timestamp: timestamp)
    }

    /// Updates the independent per-key EMA when the user deleted a mistyped key and immediately
    /// pressed a neighboring key `intendedLetter`, attributing the original `mistypedPoint` to `intendedLetter`.
    @discardableResult
    func learnNeighborCorrection(
        intendedLetter: Character,
        mistypedLetter: Character,
        mistypedPoint: CGPoint,
        intendedBody: CGRect,
        bucket: LayoutBucket,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        learn(letter: intendedLetter, rawLetter: mistypedLetter, point: mistypedPoint,
              body: intendedBody, bucket: bucket, isNeighborFix: true, timestamp: timestamp)
    }

    private func learn(
        letter: Character,
        rawLetter: Character?,
        point: CGPoint,
        body: CGRect,
        bucket: LayoutBucket,
        isNeighborFix: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        guard body.width > 0, body.height > 0 else { return false }
        let dx = Double((point.x - body.midX) / body.width)
        let dy = Double((point.y - body.midY) / body.height)
        guard abs(dx) <= Self.maxAcceptedDx, abs(dy) <= Self.maxAcceptedDy else {
            lock.lock()
            snapshot.summary.rejectedOutliers += 1
            dirty = true
            lock.unlock()
            return false
        }

        let key = String(letter).lowercased()
        let rawKey = rawLetter.map { String($0).lowercased() }

        lock.lock()
        var bucketMap = snapshot.buckets[bucket.rawValue] ?? [:]
        var stats = bucketMap[key] ?? KeyStats()
        let alpha: Double
        if isNeighborFix {
            alpha = min(0.15, max(Self.neighborFixAlpha, 1.0 / Double(stats.count + 1)))
            snapshot.summary.neighborFixSamples += 1
        } else {
            alpha = stats.count < 10 ? 1.0 / Double(stats.count + 1) : Self.commitAlpha
            snapshot.summary.committedSamples += 1
        }
        stats.dx = Self.clamp(stats.dx + alpha * (dx - stats.dx), limit: Self.maxOffsetDx)
        stats.dy = Self.clamp(stats.dy + alpha * (dy - stats.dy), limit: Self.maxOffsetDy)
        stats.count += 1
        bucketMap[key] = stats
        snapshot.buckets[bucket.rawValue] = bucketMap
        snapshot.updatedAt = Date(timeIntervalSince1970: timestamp)

        let eff = Self.effectiveOffset(from: stats)
        pendingObservations.append(Observation(
            ts: timestamp,
            bucket: bucket.rawValue,
            kind: isNeighborFix ? "neighbor_fix" : "commit",
            key: key,
            rawKey: rawKey,
            dx: Self.round4(dx),
            dy: Self.round4(dy),
            effDx: Self.round4(eff.dx),
            effDy: Self.round4(eff.dy),
            count: stats.count,
            calSwitched: false,
            langCorrected: false
        ))
        dirty = true
        updatesSinceFlush += 1
        let shouldFlush = updatesSinceFlush >= 20
        lock.unlock()

        if shouldFlush { flushAsync() }
        return true
    }

    func reset() {
        lock.lock()
        snapshot = Snapshot()
        pendingObservations.removeAll()
        dirty = true
        updatesSinceFlush = 0
        lock.unlock()
        guard let directory else { return }
        ioQueue.async {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("state.json"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("observations.jsonl"))
        }
    }

    // MARK: - Persistence & Mirroring

    func flushAsync() {
        guard let directory else { return }
        lock.lock()
        guard dirty || !pendingObservations.isEmpty else { lock.unlock(); return }
        let stateCopy = snapshot
        let obsCopy = pendingObservations
        pendingObservations.removeAll(keepingCapacity: true)
        dirty = false
        updatesSinceFlush = 0
        lock.unlock()

        ioQueue.async {
            Self.writeToDisk(directory: directory, state: stateCopy, observations: obsCopy)
        }
    }

    /// Synchronous flush for deterministic unit tests.
    func flushSync() {
        guard let directory else { return }
        lock.lock()
        let stateCopy = snapshot
        let obsCopy = pendingObservations
        pendingObservations.removeAll(keepingCapacity: true)
        dirty = false
        updatesSinceFlush = 0
        lock.unlock()
        ioQueue.sync {
            Self.writeToDisk(directory: directory, state: stateCopy, observations: obsCopy)
        }
    }

    /// Mirrors App Group calibration files into the main app's `Documents/Calibration`
    /// so logs can be exported via either `appGroupDataContainer` or `appDataContainer`.
    static func mirrorToAppDocuments() {
        guard let sourceDir = defaultDirectory(),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let targetDir = docs.appendingPathComponent("Calibration", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard fm.fileExists(atPath: sourceDir.path) else { return }
            try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            for name in ["state.json", "observations.jsonl"] {
                let src = sourceDir.appendingPathComponent(name)
                let dst = targetDir.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    private static func writeToDisk(directory: URL, state: Snapshot, observations: [Observation]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }

        guard !observations.isEmpty else { return }
        let lineEncoder = JSONEncoder()
        var chunk = Data()
        for item in observations {
            if let encoded = try? lineEncoder.encode(item) {
                chunk.append(encoded)
                chunk.append(0x0A) // '\n'
            }
        }
        guard !chunk.isEmpty else { return }
        let logURL = directory.appendingPathComponent("observations.jsonl")
        if fm.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: chunk)
            }
            if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? Int, size > maxLogBytes,
               let data = try? Data(contentsOf: logURL) {
                let keepFrom = data.count / 2
                if let newline = data[keepFrom...].firstIndex(of: 0x0A), newline + 1 < data.count {
                    try? data[(newline + 1)...].write(to: logURL, options: .atomic)
                }
            }
        } else {
            try? chunk.write(to: logURL, options: .atomic)
        }
    }

    // MARK: - Helpers

    private static func effectiveOffset(from stats: KeyStats) -> (dx: Double, dy: Double) {
        guard stats.count >= minSamples else { return (0, 0) }
        let span = max(1, fullWeightSamples - minSamples)
        let weight = min(1.0, Double(stats.count - minSamples) / Double(span))
        return (stats.dx * weight, stats.dy * weight)
    }

    private static func clamp(_ value: Double, limit: Double) -> Double {
        min(limit, max(-limit, value))
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10000).rounded() / 10000
    }
}
