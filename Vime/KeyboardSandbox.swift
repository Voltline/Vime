import SwiftUI
import UIKit

struct KeyboardSandbox: UIViewRepresentable {
    @Binding var text: String
    @Binding var composition: String
    var focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 23)
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.delegate = context.coordinator
        view.accessibilityLabel = "日语试打输入框"
        let width = view.window?.bounds.width ?? UIScreen.main.bounds.width
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width, compact: false, showsFooter: true).height))
        let input = SandboxInputView(keyboard: keyboard)
        context.coordinator.keyboard = keyboard
        context.coordinator.input = input
        context.coordinator.host = KeyboardHostConnection(
            setMarkedText: { [weak view] in view?.setMarkedText($0, selectedRange: $1) },
            unmarkText: { [weak view] in view?.unmarkText() },
            insertText: { [weak view] in view?.insertText($0) },
            deleteBackward: { [weak view] in view?.deleteBackward() }
        )
        keyboard.onEdit = { [weak view, weak coordinator = context.coordinator] edits in
            guard let view, let coordinator else { return }
            coordinator.performKeyboardEdit(in: view) { coordinator.host?.apply(edits) }
        }
        keyboard.onMarkedTextChange = { [weak view, weak coordinator = context.coordinator] text in
            guard let view, let coordinator else { return }
            coordinator.performKeyboardEdit(in: view) { coordinator.host?.updateMarkedText(text) }
        }
        keyboard.onCompositionChange = { [weak coordinator = context.coordinator] text in coordinator?.parent.composition = text }
        keyboard.onDismiss = { [weak view] in view?.resignFirstResponder() }
        keyboard.onSwitchKeyboard = { [weak view] in
            view?.inputView = nil
            view?.reloadInputViews()
        }
        view.inputView = input
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            context.coordinator.host?.abandon()
            uiView.text = text
            context.coordinator.keyboard?.resetComposition()
        }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            uiView.inputView = context.coordinator.input
            uiView.reloadInputViews()
            uiView.becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: KeyboardSandbox
        var keyboard: KeyboardView?
        var host: KeyboardHostConnection?
        var input: SandboxInputView?
        var editingFromKeyboard = false
        var lastFocusRequest = 0
        var knownSelection = NSRange(location: 0, length: 0)
        init(_ parent: KeyboardSandbox) { self.parent = parent }

        func performKeyboardEdit(in view: UITextView, _ edit: () -> Void) {
            editingFromKeyboard = true
            edit()
            parent.text = view.text
            knownSelection = view.selectedRange
            editingFromKeyboard = false
        }

        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidChangeSelection(_ textView: UITextView) {
            if !editingFromKeyboard && textView.selectedRange != knownSelection {
                host?.abandon()
                performKeyboardEdit(in: textView) { textView.unmarkText(); keyboard?.resetComposition() }
            }
            knownSelection = textView.selectedRange
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            host?.abandon()
            keyboard?.resetComposition()
            keyboard?.stopInteractions()
        }
    }
}

/// UIKit supplies the keyboard material and system shape. No painted outer frame.
final class SandboxInputView: UIInputView {
    let keyboard: KeyboardView
    init(keyboard: KeyboardView) {
        self.keyboard = keyboard
        super.init(frame: keyboard.frame, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        addSubview(keyboard)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { keyboard.intrinsicContentSize }
    override func layoutSubviews() {
        super.layoutSubviews()
        keyboard.frame = bounds
    }
}
