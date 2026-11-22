import CoreGraphics
import Foundation

/// Behavioral guard for accidental language-switch taps.
///
/// The language key sits immediately to the right of Space and below the bottom letter
/// row, making accidental edge grazes during fast typing costly (they flip global input
/// mode). This guard evaluates each language-key tap using geometric position, timing
/// relative to the previous letter tap, rolling-touch overlap, and composing state.
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

    static let shared = LanguageSwitchGuard()

    /// Enabled by default (默认启用): suppresses high-confidence accidental edge grazes
    /// and rolling overlaps while allowing an immediate retry within 1.0 s.
    var enforcementEnabled = true

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

    private let lock = NSLock()

    private var lastSuppressedAt: TimeInterval?
    private var lastAllowedAt: TimeInterval?

    // In-memory counters for quick inspection and tests.
    private(set) var totalEvaluations = 0
    private(set) var quickRevertCount = 0
    private(set) var unretriedSuppressCount = 0
    private(set) var overrideAllowCount = 0

    init() {}

    /// Evaluates a language-key tap. Pass `context == nil` when triggered
    /// programmatically (e.g. `sendActions` in tests) to bypass touch heuristics.
    func evaluate(context: TapContext?) -> Evaluation {
        guard let context else {
            return Evaluation(recommendation: .allow, effectiveDecision: .allow, reason: .directAction)
        }

        lock.lock()
        defer { lock.unlock() }
        totalEvaluations += 1

        if let suppressedAt = lastSuppressedAt,
           context.timestamp - suppressedAt > Self.quickRevertWindow {
            unretriedSuppressCount += 1
            lastSuppressedAt = nil
        }

        let evaluation = evaluateLocked(context: context)

        if evaluation.shouldToggleLanguage {
            if let priorAt = lastAllowedAt,
               context.timestamp - priorAt <= Self.quickRevertWindow,
               context.timestamp >= priorAt {
                quickRevertCount += 1
                lastAllowedAt = nil
            } else {
                lastAllowedAt = context.timestamp
            }
        }

        return evaluation
    }

    /// Call on subsequent non-language key taps so an unretried suppression can be
    /// finalized and counted even if the user never taps the language key again.
    func noteOtherActivity(at timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if let suppressedAt = lastSuppressedAt,
           timestamp - suppressedAt > Self.quickRevertWindow {
            unretriedSuppressCount += 1
            lastSuppressedAt = nil
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastSuppressedAt = nil
        lastAllowedAt = nil
        totalEvaluations = 0
        quickRevertCount = 0
        unretriedSuppressCount = 0
        overrideAllowCount = 0
    }

    private func evaluateLocked(context: TapContext) -> Evaluation {
        if let suppressedAt = lastSuppressedAt,
           context.timestamp - suppressedAt <= Self.doubleTapOverrideWindow,
           context.timestamp >= suppressedAt {
            lastSuppressedAt = nil
            overrideAllowCount += 1
            return Evaluation(recommendation: .overrideAllow, effectiveDecision: .overrideAllow, reason: .doubleTapOverride)
        }

        let suppressReason = classifyAccidentalReason(context: context)
        let recommendation: Decision = suppressReason == nil ? .allow : .suppress
        let reason = suppressReason ?? .normal

        if recommendation == .suppress {
            if enforcementEnabled {
                lastSuppressedAt = context.timestamp
                return Evaluation(recommendation: .suppress, effectiveDecision: .suppress, reason: reason)
            } else {
                return Evaluation(recommendation: .suppress, effectiveDecision: .allow, reason: reason)
            }
        }

        return Evaluation(recommendation: .allow, effectiveDecision: .allow, reason: .normal)
    }

    private func classifyAccidentalReason(context: TapContext) -> Reason? {
        if context.hasOtherHeldKey {
            return .rollingOverlap
        }

        guard let iki = context.ikiSinceLastLetter else {
            return nil
        }

        if context.dx <= Self.leftEdgeThreshold && iki <= Self.leftEdgeFastIKI {
            return .leftEdgeFast
        }

        if iki <= Self.fastEdgeIKI && (abs(context.dx) >= Self.fastEdgeX || context.dy <= Self.fastEdgeTopY) {
            return .fastEdge
        }

        if context.isComposing && iki <= Self.composingFastIKI && (context.dy <= Self.composingTopY || abs(context.dx) >= Self.composingEdgeX) {
            return .composingFastEdge
        }

        return nil
    }
}
