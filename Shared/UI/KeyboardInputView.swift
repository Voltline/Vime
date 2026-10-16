import UIKit

/// The actual input view must enable Apple's standard input clicks, rather than
/// only a descendant view. Used by both the keyboard extension and the sandbox.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    private final class WeakInputView {
        weak var value: KeyboardInputView?
        init(_ value: KeyboardInputView) { self.value = value }
    }
    // A weak, bounded pool lets a subsequent controller reuse a retired root
    // if UIKit keeps its private input-view wrappers alive. Never move a root
    // away from a live controller, window or superview.
    private static var retiredInputs: [WeakInputView] = []
    private weak var owningController: UIViewController?

    static func acquire(keyboard: KeyboardView, owner: UIViewController) -> KeyboardInputView {
        retiredInputs.removeAll { $0.value == nil }
        if let index = retiredInputs.firstIndex(where: {
            guard let input = $0.value else { return false }
            return input.owningController == nil && input.keyboard == nil
                && input.window == nil && input.superview == nil
        }), let input = retiredInputs.remove(at: index).value {
            input.owningController = owner
            input.attachKeyboard(keyboard)
            return input
        }
        let input = KeyboardInputView(keyboard: keyboard)
        input.owningController = owner
        return input
    }

    func offerForReuse() {
        guard keyboard == nil, !Self.retiredInputs.contains(where: { $0.value === self }) else { return }
        Self.retiredInputs.removeAll { $0.value == nil }
        if Self.retiredInputs.count == 2 { Self.retiredInputs.removeFirst() }
        Self.retiredInputs.append(WeakInputView(self))
    }
    // UIKit can retain old input views after their controller is deallocated.
    // The subview hierarchy owns the keyboard only while it is attached.
    private(set) weak var keyboard: KeyboardView?
    // Hosts can measure a retired input before viewWillAppear reattaches its
    // contents. Retain only scalar geometry so that releasing the keyboard
    // hierarchy does not turn the next fitting request into a default height.
    private var detachedMetrics: KeyboardMetrics?
    var enableInputClicksWhenVisible: Bool { keyboard?.enableInputClicksWhenVisible ?? false }

    init(keyboard: KeyboardView) {
        self.keyboard = keyboard
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: keyboard.bounds.width,
            height: keyboard.preferredHeight(for: keyboard.bounds.width))), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        attachKeyboard(keyboard)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func attachKeyboard(_ keyboard: KeyboardView) {
        self.keyboard = keyboard
        detachedMetrics = nil
        if keyboard.superview !== self { addSubview(keyboard) }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
    func detachKeyboard() {
        if let keyboard {
            detachedMetrics = KeyboardMetrics(width: bounds.width > 0 ? bounds.width : 440,
                compact: keyboard.compact, showsFooter: keyboard.showsFooter, heightFactor: keyboard.heightFactor)
        }
        keyboard?.removeFromSuperview()
        keyboard = nil
        invalidateIntrinsicContentSize()
    }
    override var intrinsicContentSize: CGSize {
        guard let height = preferredHeight(for: bounds.width) else { return super.intrinsicContentSize }
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }
    private func preferredHeight(for width: CGFloat) -> CGFloat? {
        if let keyboard { return keyboard.preferredHeight(for: width) }
        guard let detachedMetrics else { return nil }
        return KeyboardMetrics(width: width > 0 ? width : detachedMetrics.width,
            compact: detachedMetrics.compact, showsFooter: detachedMetrics.showsFooter,
            heightFactor: detachedMetrics.heightFactor).height
    }
    // With allowsSelfSizing UIKit asks the root for its fitting size. Its
    // proposed height can be the previous keyboard's height after reconnecting;
    // use our preference rather than accepting that stale proposal.
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        let width = targetSize.width > 0 ? targetSize.width : bounds.width
        guard let height = preferredHeight(for: width) else { return super.systemLayoutSizeFitting(targetSize) }
        return CGSize(width: width, height: height)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority) -> CGSize {
        guard keyboard != nil || detachedMetrics != nil else {
            return super.systemLayoutSizeFitting(targetSize,
                withHorizontalFittingPriority: horizontalFittingPriority,
                verticalFittingPriority: verticalFittingPriority)
        }
        let width = horizontalFittingPriority == .required && targetSize.width > 0
            ? targetSize.width : bounds.width
        return systemLayoutSizeFitting(CGSize(width: width, height: targetSize.height))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let keyboard, keyboard.bounds.width != bounds.width { invalidateIntrinsicContentSize() }
        keyboard?.frame = bounds
    }
}
