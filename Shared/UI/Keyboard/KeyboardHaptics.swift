import UIKit

/// The key-press haptic.
///
/// UIKit plays each impact on a Core Haptics player channel owned by the
/// generator. Calling `prepare()` right after an impact leaks that channel;
/// after about 250 presses without the keyboard hiding, every later impact
/// fails ("Unable to add an additional player channel") and key haptics stop
/// until the generator is released. So impacts are never followed by a
/// prepare: generators are warmed only when created or when the keyboard
/// appears, and all generators share one bounded rotation counter that frees
/// any channel the system kept.
@MainActor
final class KeyboardHaptics {
    enum Style: Equatable, Sendable {
        case letter
        case utility
        case repeatDelete
        case tick
        case cursorTick
    }

    @MainActor protocol Generator: AnyObject {
        func prepare()
        func impactOccurred(intensity: CGFloat)
    }

    @MainActor protocol SelectionGenerator: AnyObject {
        func prepare()
        func selectionChanged()
    }

    /// Feedback events played across generators before they are rotated.
    static let impactsPerGenerator = 128
    static let repeatDeleteInterval: TimeInterval = 0.085
    static let cursorTickInterval: TimeInterval = 0.050
    /// Heavy layer under the rigid snap, relative to the press intensity.
    static let letterBodyScale = 0.55
    static let utilityBodyScale = 0.90

    private let makeGenerator: () -> Generator
    private let makeUtilityGenerator: () -> Generator
    private let makeSelectionGenerator: () -> SelectionGenerator
    private let now: () -> TimeInterval

    private var letterGenerator: Generator?
    private var utilityGenerator: Generator?
    private var selectionGenerator: SelectionGenerator?
    private var impacts = 0
    private var lastRepeatDeleteAt: TimeInterval = -.infinity
    private var lastCursorTickAt: TimeInterval = -.infinity

    init(
        makeGenerator: @escaping () -> Generator = { UIImpactFeedbackGenerator(style: .rigid) },
        makeUtilityGenerator: @escaping () -> Generator = { UIImpactFeedbackGenerator(style: .heavy) },
        makeSelectionGenerator: @escaping () -> SelectionGenerator = { UISelectionFeedbackGenerator() },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.makeGenerator = makeGenerator
        self.makeUtilityGenerator = makeUtilityGenerator
        self.makeSelectionGenerator = makeSelectionGenerator
        self.now = now
    }

    /// Warms the Taptic Engine before typing starts. Never called after an impact.
    func prepare() {
        currentLetter().prepare()
    }

    /// One press at `intensity` (0...1); nothing when it is zero.
    /// Returns whether the event passed throttling (even when `intensity == 0`, so repeat audio can share the throttle).
    @discardableResult
    func play(intensity: Double, style: Style = .letter) -> Bool {
        let timestamp = now()
        let clamped = min(1, max(0, intensity))
        switch style {
        case .repeatDelete:
            guard timestamp - lastRepeatDeleteAt >= Self.repeatDeleteInterval else { return false }
            lastRepeatDeleteAt = timestamp
            guard clamped > 0 else { return true }
            rotateIfNeeded()
            currentLetter().impactOccurred(intensity: CGFloat(min(1, clamped * 0.40)))
            impacts += 1
            return true
        case .cursorTick:
            guard timestamp - lastCursorTickAt >= Self.cursorTickInterval else { return false }
            lastCursorTickAt = timestamp
            guard clamped > 0 else { return true }
            rotateIfNeeded()
            currentSelection().selectionChanged()
            impacts += 1
            return true
        case .tick:
            guard clamped > 0 else { return true }
            rotateIfNeeded()
            currentSelection().selectionChanged()
            impacts += 1
            return true
        case .utility:
            guard clamped > 0 else { return true }
            rotateIfNeeded()
            // Compound bottom-out: crisp rigid snap + a fuller heavy thud.
            currentLetter().impactOccurred(intensity: CGFloat(clamped))
            currentUtility().impactOccurred(intensity: CGFloat(min(1, clamped * Self.utilityBodyScale)))
            impacts += 2
            return true
        case .letter:
            guard clamped > 0 else { return true }
            rotateIfNeeded()
            // Rigid alone is crisp but thin; a softer heavy layer gives it body.
            currentLetter().impactOccurred(intensity: CGFloat(clamped))
            currentUtility().impactOccurred(intensity: CGFloat(min(1, clamped * Self.letterBodyScale)))
            impacts += 2
            return true
        }
    }

    /// Lets all generators and their channels go; the next event makes fresh ones.
    func release() {
        letterGenerator = nil
        utilityGenerator = nil
        selectionGenerator = nil
        impacts = 0
    }

    private func rotateIfNeeded() {
        if impacts >= Self.impactsPerGenerator {
            release()
        }
    }

    private func currentLetter() -> Generator {
        if let letterGenerator { return letterGenerator }
        let made = makeGenerator()
        letterGenerator = made
        return made
    }

    private func currentUtility() -> Generator {
        if let utilityGenerator { return utilityGenerator }
        let made = makeUtilityGenerator()
        utilityGenerator = made
        return made
    }

    private func currentSelection() -> SelectionGenerator {
        if let selectionGenerator { return selectionGenerator }
        let made = makeSelectionGenerator()
        selectionGenerator = made
        return made
    }
}

extension UIImpactFeedbackGenerator: KeyboardHaptics.Generator {}
extension UISelectionFeedbackGenerator: KeyboardHaptics.SelectionGenerator {}
