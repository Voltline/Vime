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
        let input = KeyboardInputView(keyboard: keyboard)
        context.coordinator.keyboard = keyboard
        context.coordinator.input = input
        context.coordinator.host = KeyboardHostConnection(
            setMarkedText: { [weak view] in view?.setMarkedText($0, selectedRange: $1) },
            unmarkText: { [weak view] in view?.unmarkText() },
            insertText: { [weak view] in view?.insertText($0) },
            deleteBackward: { [weak view] in view?.deleteBackward() },
            moveCursor: { [weak view, weak coordinator = context.coordinator] horizontal, vertical in
                guard let view, let coordinator else { return }
                KeyboardTextNavigation.move(in: view, horizontal: horizontal, vertical: vertical, preferredX: &coordinator.cursorX)
            },
            deleteToLineStart: { [weak view] in view.map { KeyboardTextNavigation.deleteLinePrefix(in: $0) } ?? "" },
            undoAnchor: { [weak view] in
                guard let view else { return nil }
                let range = view.selectedRange
                let text = view.text as NSString
                return KeyboardUndoAnchor(document: String(describing: ObjectIdentifier(view)),
                    before: text.substring(to: range.location), after: text.substring(from: NSMaxRange(range)),
                    selection: range.length == 0 ? nil : text.substring(with: range))
            }
        )
        context.coordinator.host?.onUndoAvailabilityChange = { [weak keyboard] in keyboard?.canUndoLineDeletion = $0 }
        keyboard.onHeightChange = { [weak input, weak view] in
            input?.invalidateIntrinsicContentSize()
            input?.setNeedsLayout()
            view?.reloadInputViews()
        }
        keyboard.leftContextProvider = { [weak view] in
            guard let view else { return nil }
            let end = view.markedTextRange?.start ?? view.selectedTextRange?.start ?? view.endOfDocument
            let range = view.textRange(from: view.beginningOfDocument, to: end)
            return range.flatMap { view.text(in: $0) }
        }
        keyboard.learningContextProvider = { [weak view] in
            guard let view else { return nil }
            let start = view.markedTextRange?.start ?? view.selectedTextRange?.start ?? view.endOfDocument
            let end = view.markedTextRange?.end ?? view.selectedTextRange?.end ?? view.endOfDocument
            return KeyboardLearningContext(document: String(describing: ObjectIdentifier(view)),
                before: view.textRange(from: view.beginningOfDocument, to: start).flatMap { view.text(in: $0) },
                after: view.textRange(from: end, to: view.endOfDocument).flatMap { view.text(in: $0) },
                hasSelection: view.markedTextRange == nil && view.selectedRange.length > 0)
        }
        keyboard.deletionAvailabilityProvider = { [weak view] in
            guard let view else { return false }
            return view.selectedRange.length > 0 || view.selectedRange.location > 0
        }
        keyboard.onEdit = { [weak view, weak coordinator = context.coordinator] edits in
            guard let view, let coordinator else { return }
            coordinator.performKeyboardEdit(in: view) { coordinator.host?.apply(edits) }
        }
        keyboard.onPreeditChange = { [weak view, weak coordinator = context.coordinator] preedit in
            guard let view, let coordinator else { return }
            coordinator.performKeyboardEdit(in: view) { coordinator.host?.updatePreedit(preedit) }
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
        context.coordinator.keyboard?.reloadHeightPreference()
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
        var input: KeyboardInputView?
        var editingFromKeyboard = false
        var lastFocusRequest = 0
        var knownSelection = NSRange(location: 0, length: 0)
        var cursorX: CGFloat?
        init(_ parent: KeyboardSandbox) { self.parent = parent }

        func performKeyboardEdit(in view: UITextView, _ edit: () -> Void) {
            editingFromKeyboard = true
            edit()
            parent.text = view.text
            knownSelection = view.selectedRange
            editingFromKeyboard = false
        }

        func textViewDidChange(_ textView: UITextView) {
            if !editingFromKeyboard { host?.abandon(); keyboard?.resetComposition() }
            parent.text = textView.text
        }
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
