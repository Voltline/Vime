import CoreGraphics
import Foundation

/// Behavioral guard and shadow-mode observer for accidental language-switch taps.
///
/// The language key sits immediately to the right of Space and below the bottom letter
/// row, making accidental edge grazes during fast typing costly (they flip global input
/// mode). This guard evaluates each language-key tap using geometric position, timing
/// relative to the previous letter tap, rolling-touch overlap, and composing state.
///
/// In shadow mode (`enforcementEnabled == false`), every tap still toggles the language
/// normally while logging what the rule would have decided alongside ground-truth
/// signals (`quick_revert` when the user toggles back within 1.8 s, and
/// `unretried_suppress` when a suppressed tap is not retried within 1.8 s).
nonisolated final class LanguageSwitchGuard: @unchecked Sendable {
    struct TapContext: Equatable, Sendable {
        /// Normalized tap coordinates relative to the language key's visible body
        /// (`-0.5...0.5` inside the keycap; negative X is left toward Space,
        /// negative Y is top toward the letter row).
        let dx: Double
        let dy: Double
        /// Seconds since the previous letter key touch-down, or nil if none / reset.
        let ikiSinceLastLetter: TimeInterval?
        /// True if another key was simultaneously held down when this press began.
        let hasOtherHeldKey: Bool
        /// Whether the input session was composing at tap time.
        let isComposing: Bool
        /// Monotonic timestamp (seconds) for timing checks.
        let timestamp: TimeInterval
    }

    enum Decision: String, Equatable, Sendable {
        case allow
        case overrideAllow = "override_allow"
        case suppress
    }

    enum Reason: String, Equatable, Sendable {
        case directAction = "direct_action"
        case normal
        case doubleTapOverride = "double_tap_override"
        case rollingOverlap = "rolling_overlap"
        case leftEdgeFast = "left_edge_fast"
        case fastEdge = "fast_edge"
        case composingFastEdge = "composing_fast_edge"
    }

    struct Evaluation: Equatable, Sendable {
        /// The rule's recommendation independent of `enforcementEnabled`.
        let recommendation: Decision
        /// The actual outcome applied to the UI (always `.allow` or `.overrideAllow`
        /// when `enforcementEnabled == false`).
        let effectiveDecision: Decision
        let reason: Reason
        /// True when the UI should proceed with toggling the language.
        var shouldToggleLanguage: Bool { effectiveDecision != .suppress }
    }

    static let shared = LanguageSwitchGuard(directory: LanguageSwitchGuard.defaultDirectory())

    /// Shadow mode by default: evaluate and log without blocking until real-world
    /// `quick_revert` data validates the thresholds.
    var enforcementEnabled = false
    var observationLoggingEnabled = true

    // Tunable thresholds
    static let doubleTapOverrideWindow: TimeInterval = 1.0
    static let quickRevertWindow: TimeInterval = 1.8
    static let leftEdgeFastIKI: TimeInterval = 0.20
    static let leftEdgeThreshold: Double = -0.25
    static let fastEdgeIKI: TimeInterval = 0.22
    static let fastEdgeX: Double = 0.22
    static let fastEdgeTopY: Double = -0.22
    static let composingFastIKI: TimeInterval = 0.25
    static let composingEdgeX: Double = 0.25
    static let composingTopY: Double = -0.18
    static let maxLogLines = 3000

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.Voltline.Vime.LanguageSwitchGuard.io", qos: .utility)
    private let directory: URL?

    private var lastSuppressedAt: TimeInterval?
    private var lastSuppressedReason: Reason?
    private var lastAllowedAt: TimeInterval?
    private var lastAllowedRecommendedSuppress = false
    private var lastAllowedReason: Reason?

    // In-memory counters for quick inspection and tests.
    private(set) var totalEvaluations = 0
    private(set) var quickRevertCount = 0
    private(set) var unretriedSuppressCount = 0
    private(set) var overrideAllowCount = 0

    init(directory: URL? = nil) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup)?
            .appendingPathComponent("Calibration", isDirectory: true)
    }

    /// Evaluates a language-key tap. Pass `context == nil` when triggered
    /// programmatically (e.g. `sendActions` in tests) to bypass touch heuristics.
    func evaluate(context: TapContext?) -> Evaluation {
        guard let context else {
            return Evaluation(recommendation: .allow, effectiveDecision: .allow, reason: .directAction)
        }

        lock.lock()
        totalEvaluations += 1

        // Check whether a previously suppressed tap expired without being retried.
        var expiredUnretried: (ts: TimeInterval, reason: Reason)?
        if let suppressedAt = lastSuppressedAt,
           context.timestamp - suppressedAt > Self.quickRevertWindow {
            unretriedSuppressCount += 1
            expiredUnretried = (suppressedAt, lastSuppressedReason ?? .fastEdge)
            lastSuppressedAt = nil
            lastSuppressedReason = nil
        }

        let evaluation = evaluateLocked(context: context)

        // Track quick-revert ground truth: toggling again within quickRevertWindow
        // after an allowed toggle strongly indicates the first toggle was accidental.
        var quickRevert: (dtMs: Int, priorRecommendedSuppress: Bool, priorReason: Reason)?
        if evaluation.shouldToggleLanguage {
            if let priorAt = lastAllowedAt,
               context.timestamp - priorAt <= Self.quickRevertWindow,
               context.timestamp >= priorAt {
                quickRevertCount += 1
                quickRevert = (
                    Int(((context.timestamp - priorAt) * 1000).rounded()),
                    lastAllowedRecommendedSuppress,
                    lastAllowedReason ?? .normal
                )
                // Consume the revert pair so a third tap starts a fresh cycle.
                lastAllowedAt = nil
                lastAllowedRecommendedSuppress = false
                lastAllowedReason = nil
            } else {
                lastAllowedAt = context.timestamp
                lastAllowedRecommendedSuppress = (evaluation.recommendation == .suppress)
                lastAllowedReason = evaluation.reason
            }
        }

        let shouldLog = observationLoggingEnabled && directory != nil
        let enforce = enforcementEnabled
        lock.unlock()

        if shouldLog {
            if let expired = expiredUnretried {
                appendLogRecord([
                    "kind": "unretried_suppress",
                    "ts": Date().timeIntervalSince1970,
                    "suppressedAt": expired.ts,
                    "reason": expired.reason.rawValue,
                ])
            }
            var record: [String: Any] = [
                "kind": "tap",
                "ts": Date().timeIntervalSince1970,
                "dx": round4(context.dx),
                "dy": round4(context.dy),
                "isComposing": context.isComposing,
                "hasOtherHeldKey": context.hasOtherHeldKey,
                "recommendation": evaluation.recommendation.rawValue,
                "effectiveDecision": evaluation.effectiveDecision.rawValue,
                "reason": evaluation.reason.rawValue,
                "enforced": enforce,
            ]
            if let iki = context.ikiSinceLastLetter {
                record["ikiMs"] = Int((iki * 1000).rounded())
            }
            appendLogRecord(record)

            if let revert = quickRevert {
                appendLogRecord([
                    "kind": "quick_revert",
                    "ts": Date().timeIntervalSince1970,
                    "revertDtMs": revert.dtMs,
                    "priorRecommendedSuppress": revert.priorRecommendedSuppress,
                    "priorReason": revert.priorReason.rawValue,
                ])
            }
        }

        return evaluation
    }

    /// Call on subsequent non-language key taps so an unretried suppression can be
    /// finalized and counted even if the user never taps the language key again.
    func noteOtherActivity(at timestamp: TimeInterval) {
        lock.lock()
        var expiredUnretried: (ts: TimeInterval, reason: Reason)?
        if let suppressedAt = lastSuppressedAt,
           timestamp - suppressedAt > Self.quickRevertWindow {
            unretriedSuppressCount += 1
            expiredUnretried = (suppressedAt, lastSuppressedReason ?? .fastEdge)
            lastSuppressedAt = nil
            lastSuppressedReason = nil
        }
        let shouldLog = observationLoggingEnabled && directory != nil
        lock.unlock()

        if shouldLog, let expired = expiredUnretried {
            appendLogRecord([
                "kind": "unretried_suppress",
                "ts": Date().timeIntervalSince1970,
                "suppressedAt": expired.ts,
                "reason": expired.reason.rawValue,
            ])
        }
    }

    func reset() {
        lock.lock()
        lastSuppressedAt = nil
        lastSuppressedReason = nil
        lastAllowedAt = nil
        lastAllowedRecommendedSuppress = false
        lastAllowedReason = nil
        totalEvaluations = 0
        quickRevertCount = 0
        unretriedSuppressCount = 0
        overrideAllowCount = 0
        lock.unlock()
    }

    private func evaluateLocked(context: TapContext) -> Evaluation {
        // Safety valve: if the user retries within 1.0 s after a suppressed tap,
        // allow unconditionally so an intentional fast tap is never stuck.
        if let suppressedAt = lastSuppressedAt,
           context.timestamp - suppressedAt <= Self.doubleTapOverrideWindow,
           context.timestamp >= suppressedAt {
            lastSuppressedAt = nil
            lastSuppressedReason = nil
            overrideAllowCount += 1
            return Evaluation(recommendation: .overrideAllow, effectiveDecision: .overrideAllow, reason: .doubleTapOverride)
        }

        let suppressReason = classifyAccidentalReason(context: context)
        let recommendation: Decision = suppressReason == nil ? .allow : .suppress
        let reason = suppressReason ?? .normal

        if recommendation == .suppress {
            if enforcementEnabled {
                lastSuppressedAt = context.timestamp
                lastSuppressedReason = reason
                return Evaluation(recommendation: .suppress, effectiveDecision: .suppress, reason: reason)
            } else {
                // Shadow mode: record the recommendation, but allow the toggle.
                return Evaluation(recommendation: .suppress, effectiveDecision: .allow, reason: reason)
            }
        }

        return Evaluation(recommendation: .allow, effectiveDecision: .allow, reason: .normal)
    }

    private func classifyAccidentalReason(context: TapContext) -> Reason? {
        // 1. Simultaneous rolling touch with another key.
        if context.hasOtherHeldKey {
            return .rollingOverlap
        }

        guard let iki = context.ikiSinceLastLetter else {
            return nil
        }

        // 2. Left edge immediately after a letter (spacebar right-drift graze).
        if context.dx <= Self.leftEdgeThreshold && iki <= Self.leftEdgeFastIKI {
            return .leftEdgeFast
        }

        // 3. Fast typing flow hitting the periphery of the language key.
        if iki <= Self.fastEdgeIKI && (abs(context.dx) >= Self.fastEdgeX || context.dy <= Self.fastEdgeTopY) {
            return .fastEdge
        }

        // 4. Mid-composition fast graze along the top/side edge.
        if context.isComposing && iki <= Self.composingFastIKI && (context.dy <= Self.composingTopY || abs(context.dx) >= Self.composingEdgeX) {
            return .composingFastEdge
        }

        return nil
    }

    private func round4(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private func appendLogRecord(_ record: [String: Any]) {
        guard let directory else { return }
        let fileURL = directory.appendingPathComponent("language_switch.jsonl")
        ioQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONSerialization.data(withJSONObject: record),
                  var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            guard let lineData = line.data(using: .utf8) else { return }

            if fm.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: lineData)
                }
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
                    if lines.count > Self.maxLogLines {
                        let kept = lines.suffix(Self.maxLogLines).joined(separator: "\n") + "\n"
                        try? kept.write(to: fileURL, atomically: true, encoding: .utf8)
                    }
                }
            } else {
                try? lineData.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// Mirrors `language_switch.jsonl` into the main app's Documents/Calibration
    /// directory so it can be retrieved with `devicectl device copy from`.
    static func mirrorToAppDocuments() {
        guard let srcDir = defaultDirectory(),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let srcFile = srcDir.appendingPathComponent("language_switch.jsonl")
        let fm = FileManager.default
        guard fm.fileExists(atPath: srcFile.path) else { return }
        let dstDir = docs.appendingPathComponent("Calibration", isDirectory: true)
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let dstFile = dstDir.appendingPathComponent("language_switch.jsonl")
        try? fm.removeItem(at: dstFile)
        try? fm.copyItem(at: srcFile, to: dstFile)
    }
}
