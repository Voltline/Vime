import UIKit

/// The actual input view must enable Apple's standard input clicks, rather than
/// only a descendant view. Used by both the keyboard extension and the sandbox.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    let keyboard: KeyboardView
    var enableInputClicksWhenVisible: Bool { keyboard.enableInputClicksWhenVisible }

    init(keyboard: KeyboardView) {
        self.keyboard = keyboard
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: keyboard.bounds.width,
            height: keyboard.preferredHeight(for: keyboard.bounds.width))), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        addSubview(keyboard)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { keyboard.intrinsicContentSize }
    override func layoutSubviews() { super.layoutSubviews(); keyboard.frame = bounds }
}
