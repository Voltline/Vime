import UIKit

/// The actual input view must enable Apple's standard input clicks, rather than
/// only a descendant view.
final class KeyboardInputView: UIView, UIInputViewAudioFeedback {
    // UIInputView's system content views retained retired roots during native
    // host reconnects. Use an ordinary root; Vime draws its own background.
    // The subview hierarchy owns the keyboard only while it is attached.
    private(set) weak var keyboard: KeyboardView?
    // Sizing belongs to the root for its entire lifetime, including periods
    // without content or a controller. UIKit can measure a retained root via
    // its own wrapper rather than calling our fitting override directly.
    private var sizing: KeyboardMetrics
    private var heightConstraint: NSLayoutConstraint?
    var enableInputClicksWhenVisible: Bool { keyboard?.enableInputClicksWhenVisible ?? false }

    init(keyboard: KeyboardView) {
        sizing = KeyboardMetrics(width: keyboard.bounds.width > 0 ? keyboard.bounds.width : 440,
            compact: keyboard.compact, showsFooter: keyboard.showsFooter, heightFactor: keyboard.heightFactor,
            pad: keyboard.pad)
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: sizing.width, height: sizing.height)))
        let height = heightAnchor.constraint(equalToConstant: sizing.height)
        height.identifier = "vime.keyboard.height"
        height.priority = .init(999)
        height.isActive = true
        heightConstraint = height
        attachKeyboard(keyboard)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attachKeyboard(_ keyboard: KeyboardView) {
        if let previous = self.keyboard, previous !== keyboard {
            previous.onHeightChange = nil
            previous.removeFromSuperview()
        }
        self.keyboard = keyboard
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        keyboard.onHeightChange = { [weak self] in self?.refreshSizing() }
        if keyboard.superview !== self {
            addSubview(keyboard)
            NSLayoutConstraint.activate([
                keyboard.leadingAnchor.constraint(equalTo: leadingAnchor),
                keyboard.trailingAnchor.constraint(equalTo: trailingAnchor),
                keyboard.topAnchor.constraint(equalTo: topAnchor),
                keyboard.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        refreshSizing()
        setNeedsLayout()
    }

    func detachKeyboard() {
        refreshSizing()
        keyboard?.onHeightChange = nil
        keyboard?.removeFromSuperview()
        keyboard = nil
        // Keep the root's explicit height and scalar sizing state. Releasing
        // the expensive content must not opt back into the system's old height.
    }

    func refreshSizing() {
        sizing = metrics(for: bounds.width)
        guard heightConstraint?.constant != sizing.height else { return }
        heightConstraint?.constant = sizing.height
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func metrics(for proposedWidth: CGFloat) -> KeyboardMetrics {
        let width = proposedWidth.isFinite && proposedWidth > 0 ? proposedWidth : sizing.width
        return KeyboardMetrics(width: width, compact: keyboard?.compact ?? sizing.compact,
            showsFooter: keyboard?.showsFooter ?? sizing.showsFooter,
            heightFactor: keyboard?.heightFactor ?? sizing.heightFactor, pad: keyboard?.pad ?? sizing.pad)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: metrics(for: bounds.width).height)
    }

    // Fitting, intrinsic size and Auto Layout share the same height policy.
    // The host supplies width; its previous keyboard height is not an input.
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        let width = targetSize.width.isFinite && targetSize.width > 0 ? targetSize.width : bounds.width
        let metrics = metrics(for: width)
        return CGSize(width: metrics.width, height: metrics.height)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority) -> CGSize {
        let width = horizontalFittingPriority == .required && targetSize.width > 0
            ? targetSize.width : bounds.width
        return systemLayoutSizeFitting(CGSize(width: width, height: targetSize.height))
    }
    override func layoutSubviews() {
        refreshSizing()
        super.layoutSubviews()
    }
}
