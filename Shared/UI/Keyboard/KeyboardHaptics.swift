import UIKit

/// The key-press haptic.
///
/// UIKit plays each impact on a Core Haptics player channel owned by the
/// generator. Calling `prepare()` right after an impact leaks that channel;
/// after about 250 presses without the keyboard hiding, every later impact
/// fails ("Unable to add an additional player channel") and key haptics stop
/// until the generator is released. So impacts are never followed by a
/// prepare: the generator is warmed only when it is created or the keyboard
/// appears, and it is replaced after a bounded number of impacts, which frees
/// any channel the system kept.
@MainActor
final class KeyboardHaptics {
    @MainActor protocol Generator: AnyObject {
        func prepare()
        func impactOccurred(intensity: CGFloat)
    }

    /// Impacts one generator plays before it is replaced.
    static let impactsPerGenerator = 128

    private let makeGenerator: () -> Generator
    private var generator: Generator?
    private var impacts = 0

    init(makeGenerator: @escaping () -> Generator = { UIImpactFeedbackGenerator(style: .heavy) }) {
        self.makeGenerator = makeGenerator
    }

    /// Warms the Taptic Engine before typing starts. Never called after an impact.
    func prepare() {
        current().prepare()
    }

    /// One press at `intensity` (0...1); nothing when it is zero.
    func play(intensity: Double) {
        guard intensity > 0 else { return }
        if impacts >= Self.impactsPerGenerator { generator = nil }
        // Keep one feedback style across the range so intermediate values do
        // not jump when crossing a style boundary.
        current().impactOccurred(intensity: CGFloat(min(1, intensity)))
        impacts += 1
    }

    /// Lets the generator and its channels go; the next press makes a new one.
    func release() {
        generator = nil
    }

    private func current() -> Generator {
        if let generator { return generator }
        let made = makeGenerator()
        generator = made
        impacts = 0
        return made
    }
}

extension UIImpactFeedbackGenerator: KeyboardHaptics.Generator {}
