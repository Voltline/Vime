import CoreGraphics
import Foundation

/// Per-key independent anisotropic 2D Gaussian touch-target calibration,
/// bucketed by explicit UI layout.
///
/// Design constraints:
/// - Visual keycaps never move; only the invisible hit-resolution distribution adapts.
/// - No hand-posture inference and no hierarchical multi-level backoff: each
///   `(layoutBucket, letter)` adapts strictly from its own observations, with smooth
///   single-key shrinkage toward the painted center `(0, 0)` when samples are few.
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
        /// Normalized EMA mean offset relative to the key's painted body center.
        var dx: Double = 0
        var dy: Double = 0
        /// Normalized EMA variance along x and y (anisotropic Gaussian spread).
        var varX: Double = KeyHitCalibration.defaultVarX
        var varY: Double = KeyHitCalibration.defaultVarY
        /// Number of accepted training samples for this key in this bucket.
        var count: Int = 0

        enum CodingKeys: String, CodingKey { case dx, dy, varX, varY, count }

        init(dx: Double = 0, dy: Double = 0, varX: Double = KeyHitCalibration.defaultVarX,
             varY: Double = KeyHitCalibration.defaultVarY, count: Int = 0) {
            self.dx = dx
            self.dy = dy
            self.varX = varX
            self.varY = varY
            self.count = count
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dx = try c.decodeIfPresent(Double.self, forKey: .dx) ?? 0
            dy = try c.decodeIfPresent(Double.self, forKey: .dy) ?? 0
            varX = try c.decodeIfPresent(Double.self, forKey: .varX) ?? KeyHitCalibration.defaultVarX
            varY = try c.decodeIfPresent(Double.self, forKey: .varY) ?? KeyHitCalibration.defaultVarY
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        }
    }

    struct EffectiveModel: Equatable, Sendable {
        let dx: Double
        let dy: Double
        let varX: Double
        let varY: Double
        let weight: Double
        let count: Int
    }

    struct Summary: Codable, Equatable, Sendable {
        var totalTaps: Int = 0
        var committedSamples: Int = 0
        var neighborFixSamples: Int = 0
        var rejectedOutliers: Int = 0
        var calibrationSwitches: Int = 0
        var jointBayesianSwitches: Int = 0
        var languageCorrections: Int = 0

        enum CodingKeys: String, CodingKey {
            case totalTaps, committedSamples, neighborFixSamples, rejectedOutliers,
                 calibrationSwitches, jointBayesianSwitches, languageCorrections
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalTaps = try c.decodeIfPresent(Int.self, forKey: .totalTaps) ?? 0
            committedSamples = try c.decodeIfPresent(Int.self, forKey: .committedSamples) ?? 0
            neighborFixSamples = try c.decodeIfPresent(Int.self, forKey: .neighborFixSamples) ?? 0
            rejectedOutliers = try c.decodeIfPresent(Int.self, forKey: .rejectedOutliers) ?? 0
            calibrationSwitches = try c.decodeIfPresent(Int.self, forKey: .calibrationSwitches) ?? 0
            jointBayesianSwitches = try c.decodeIfPresent(Int.self, forKey: .jointBayesianSwitches) ?? 0
            languageCorrections = try c.decodeIfPresent(Int.self, forKey: .languageCorrections) ?? 0
        }
    }

    struct Snapshot: Codable, Equatable, Sendable {
        var version: Int = 2
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

    /// Single-key shrinkage prior strength (`weight = count / (count + shrinkageKappa)`).
    /// Replaces hard 15-tap cutoff with smooth ramp: 50% at 8 taps, 75% at 24 taps.
    static let shrinkageKappa = 8.0
    /// Minimum samples before a key contributes any nonzero offset (prevents 1–2 tap noise).
    static let minSamples = 3
    /// Steady-state EMA learning rate for normal committed taps.
    static let commitAlpha = 0.05
    /// Stronger EMA learning rate for explicit neighbor-backspace self-corrections.
    static let neighborFixAlpha = 0.14
    /// Default normalized variances (sdX ≈ 0.21, sdY ≈ 0.18, empirically matching thumb typing).
    static let defaultVarX = 0.044
    static let defaultVarY = 0.032
    /// Keep per-key variance within a tight band so a very consistent key never loses territory to a noisier neighbor.
    static let minVarianceX = 0.034
    static let maxVarianceX = 0.060
    static let minVarianceY = 0.024
    static let maxVarianceY = 0.046
    /// Outlier rejection bounds (normalized to key width / height).
    static let maxAcceptedDx = 1.10
    static let maxAcceptedDy = 1.00
    /// Hard clamp on stored per-key offset (normalized to key width / height).
    static let maxOffsetDx = 0.28
    static let maxOffsetDy = 0.22
    /// Weight of log language prior in joint Bayesian scoring.
    static let languagePriorWeight = 1.65
    /// Minimum joint log-score margin required to override the raw geometric key when language prior assists.
    static let jointSwitchMargin = 0.35
    /// Core safe zone around a key's calibrated center: taps inside are never overridden by language prior.
    static let coreSafeDx = 0.24
    static let coreSafeDy = 0.24
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

    /// Effective per-key anisotropic 2D Gaussian parameters after single-key shrinkage toward `(0, 0)`.
    func effectiveModel(for letter: Character, in bucket: LayoutBucket) -> EffectiveModel {
        let key = String(letter).lowercased()
        lock.lock()
        let stats = snapshot.buckets[bucket.rawValue]?[key]
        lock.unlock()
        guard let stats else {
            return EffectiveModel(dx: 0, dy: 0, varX: Self.defaultVarX, varY: Self.defaultVarY, weight: 0, count: 0)
        }
        return Self.effectiveModel(from: stats)
    }

    /// Effective normalized `(dx, dy)` offset for `letter` in `bucket`.
    func effectiveNormalizedOffset(for letter: Character, in bucket: LayoutBucket) -> (dx: Double, dy: Double) {
        let model = effectiveModel(for: letter, in: bucket)
        return (model.dx, model.dy)
    }

    /// Effective offset in points for `letter` given its painted `body`.
    func effectivePointOffset(for letter: Character, body: CGRect, in bucket: LayoutBucket) -> CGPoint {
        guard body.width > 0, body.height > 0 else { return .zero }
        let model = effectiveModel(for: letter, in: bucket)
        return CGPoint(x: CGFloat(model.dx) * body.width, y: CGFloat(model.dy) * body.height)
    }

    /// Joint anisotropic 2D Gaussian spatial log-likelihood + optional language prior score.
    static func spatialLogLikelihood(point: CGPoint, body: CGRect, model: EffectiveModel) -> Double {
        guard body.width > 0, body.height > 0 else { return -.infinity }
        let cx = body.midX + CGFloat(model.dx) * body.width
        let cy = body.midY + CGFloat(model.dy) * body.height
        let nx = Double((point.x - cx) / body.width)
        let ny = Double((point.y - cy) / body.height)
        return -0.5 * ((nx * nx) / model.varX + (ny * ny) / model.varY + log(model.varX * model.varY))
    }

    /// Whether `point` lies inside the core safe zone of a key's calibrated center.
    static func isInCoreSafeZone(point: CGPoint, body: CGRect, model: EffectiveModel) -> Bool {
        guard body.width > 0, body.height > 0 else { return false }
        let cx = body.midX + CGFloat(model.dx) * body.width
        let cy = body.midY + CGFloat(model.dy) * body.height
        let nx = abs(Double((point.x - cx) / body.width))
        let ny = abs(Double((point.y - cy) / body.height))
        return nx <= coreSafeDx && ny <= coreSafeDy
    }

    func currentSnapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    // MARK: - Recording & Learning

    func recordTapObservation(
        letter: Character,
        rawLetter: Character?,
        point: CGPoint,
        body: CGRect,
        bucket: LayoutBucket,
        calibrationSwitched: Bool,
        jointBayesianSwitched: Bool = false,
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
        if jointBayesianSwitched { snapshot.summary.jointBayesianSwitches += 1 }
        if languageCorrected { snapshot.summary.languageCorrections += 1 }
        let stats = snapshot.buckets[bucket.rawValue]?[key] ?? KeyStats()
        let eff = Self.effectiveModel(from: stats)
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
            calSwitched: calibrationSwitched || jointBayesianSwitched,
            langCorrected: languageCorrected
        ))
        dirty = true
        updatesSinceFlush += 1
        let shouldFlush = updatesSinceFlush >= 25
        lock.unlock()
        if shouldFlush { flushAsync() }
    }

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
            alpha = Self.neighborFixAlpha
            snapshot.summary.neighborFixSamples += 1
        } else {
            // Bounded early step size prevents 1–2 edge taps from slamming the clamp.
            alpha = min(0.18, max(Self.commitAlpha, 1.0 / Double(stats.count + 4)))
            snapshot.summary.committedSamples += 1
        }
        let residualX = dx - stats.dx
        let residualY = dy - stats.dy
        stats.dx = Self.clamp(stats.dx + alpha * residualX, limit: Self.maxOffsetDx)
        stats.dy = Self.clamp(stats.dy + alpha * residualY, limit: Self.maxOffsetDy)
        // Only update variance from normal committed taps so neighbor fixes don't inflate variance excessively.
        if !isNeighborFix {
            let varAlpha = min(0.08, alpha)
            stats.varX = Self.clampRange(stats.varX + varAlpha * (residualX * residualX - stats.varX),
                                         min: Self.minVarianceX, max: Self.maxVarianceX)
            stats.varY = Self.clampRange(stats.varY + varAlpha * (residualY * residualY - stats.varY),
                                         min: Self.minVarianceY, max: Self.maxVarianceY)
        }
        stats.count += 1
        bucketMap[key] = stats
        snapshot.buckets[bucket.rawValue] = bucketMap
        snapshot.updatedAt = Date(timeIntervalSince1970: timestamp)

        let eff = Self.effectiveModel(from: stats)
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
    /// so logs can be exported via `devicectl` `appDataContainer`.
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

    private static func effectiveModel(from stats: KeyStats) -> EffectiveModel {
        guard stats.count >= minSamples else {
            return EffectiveModel(dx: 0, dy: 0, varX: defaultVarX, varY: defaultVarY, weight: 0, count: stats.count)
        }
        let weight = Double(stats.count) / (Double(stats.count) + shrinkageKappa)
        let effVarX = defaultVarX + weight * (stats.varX - defaultVarX)
        let effVarY = defaultVarY + weight * (stats.varY - defaultVarY)
        return EffectiveModel(
            dx: stats.dx * weight,
            dy: stats.dy * weight,
            varX: effVarX,
            varY: effVarY,
            weight: weight,
            count: stats.count
        )
    }

    private static func clamp(_ value: Double, limit: Double) -> Double {
        min(limit, max(-limit, value))
    }

    private static func clampRange(_ value: Double, min lo: Double, max hi: Double) -> Double {
        Swift.min(hi, Swift.max(lo, value))
    }

    private static func round4(_ value: Double) -> Double {
        (value * 10000).rounded() / 10000
    }
}
