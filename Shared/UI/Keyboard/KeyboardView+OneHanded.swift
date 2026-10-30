import UIKit

// One-handed mode narrows the key plane toward one side on an upright iPhone.
// The freed strip holds a button that restores the full-width keyboard.
extension KeyboardView {
    var activeOneHandedSide: KeyboardOneHandedSide { pad || compact ? .off : appliedPreferences?.oneHanded ?? .off }

    /// The horizontal span the keys use; the whole width when inactive.
    var oneHandedKeyArea: ClosedRange<CGFloat> {
        let width = bounds.width
        let gutter = min(width * 0.18, 72)
        switch activeOneHandedSide {
        case .off: return 0...width
        case .left: return 0...(width - gutter)
        case .right: return gutter...width
        }
    }

    /// Maps a full-width key frame into the one-handed span.
    func oneHandedFrame(_ frame: CGRect) -> CGRect {
        guard activeOneHandedSide != .off, bounds.width > 0 else { return frame }
        let area = oneHandedKeyArea, factor = (area.upperBound - area.lowerBound) / bounds.width
        return CGRect(x: area.lowerBound + frame.minX * factor, y: frame.minY, width: frame.width * factor, height: frame.height)
    }

    func layoutOneHandedButton(keysTop: CGFloat, keysBottom: CGFloat) {
        let side = activeOneHandedSide
        oneHandedButton.isHidden = side == .off || panel != .keyboard
        guard side != .off else { return }
        let area = oneHandedKeyArea
        // The whole strip is the target, so it is easy to reach with a thumb.
        oneHandedButton.frame = side == .left
            ? CGRect(x: area.upperBound, y: keysTop, width: bounds.width - area.upperBound, height: keysBottom - keysTop)
            : CGRect(x: 0, y: keysTop, width: area.lowerBound, height: keysBottom - keysTop)
        oneHandedButton.setImage(UIImage(systemName: side == .left ? "chevron.compact.right" : "chevron.compact.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)), for: .normal)
        oneHandedButton.tintColor = KeyboardPalette.text.withAlphaComponent(0.6)
        bringSubviewToFront(oneHandedButton)
    }

    @objc func leaveOneHandedMode() {
        playFeedback()
        preferences.oneHanded = .off
        reloadPreferences()
    }
}
