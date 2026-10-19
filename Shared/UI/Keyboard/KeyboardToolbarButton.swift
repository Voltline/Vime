import UIKit

/// Keep circular artwork independent of the minimum touch target. The keyboard
/// resolves any neighboring targets before UIKit starts control tracking.
final class KeyboardToolbarButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -max(0, (44 - bounds.width) / 2),
            dy: -max(0, (44 - bounds.height) / 2)).contains(point)
    }
}
