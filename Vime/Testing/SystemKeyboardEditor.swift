import SwiftUI
import UIKit

/// A native host field: iOS supplies its input view and loads the selected
/// keyboard extension in a separate process. Never attach KeyboardView here.
struct SystemKeyboardEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var composition: String
    var focusRequest: Int
    var clearRequest: Int = 0
    var dismissRequest: Int = 0
    var sendRequest: Int = 0
    var onSnapshot: ((SystemKeyboardSnapshot) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SystemKeyboardTextView {
        let view = SystemKeyboardTextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 4, left: 1, bottom: 12, right: 1)
        view.keyboardType = .default
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.text = text
        view.delegate = context.coordinator
        view.accessibilityLabel = String(localized: "系统键盘试打输入框")
        view.accessibilityIdentifier = "vime.extension.editor"
        view.onSnapshot = { [weak coordinator = context.coordinator] in coordinator?.publish($0) }
        return view
    }

    func updateUIView(_ view: SystemKeyboardTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // SwiftUI updates must never rewrite text/selection during composition.
        // Only an explicit user reset is allowed to replace the document.
        if clearRequest != coordinator.lastClearRequest {
            coordinator.lastClearRequest = clearRequest
            view.resignFirstResponder()
            view.text = ""
        }
#if DEBUG
        if sendRequest != coordinator.lastSendRequest {
            coordinator.lastSendRequest = sendRequest
            // A chat app clears its document without hiding the keyboard.
            view.text = ""
            view.record("send")
        }
#endif
        if dismissRequest != coordinator.lastDismissRequest {
            coordinator.lastDismissRequest = dismissRequest
            view.resignFirstResponder()
        }
        if focusRequest != coordinator.lastFocusRequest {
            coordinator.lastFocusRequest = focusRequest
            view.becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SystemKeyboardEditor
        var lastFocusRequest = 0
        var lastClearRequest = 0
        var lastDismissRequest = 0
        var lastSendRequest = 0
        init(_ parent: SystemKeyboardEditor) { self.parent = parent }
        func publish(_ snapshot: SystemKeyboardSnapshot) {
            parent.text = snapshot.text
            parent.composition = snapshot.markedText ?? ""
            parent.onSnapshot?(snapshot)
        }
        func textViewDidChange(_ view: UITextView) { (view as? SystemKeyboardTextView)?.record("textDidChange") }
        func textViewDidChangeSelection(_ view: UITextView) { (view as? SystemKeyboardTextView)?.record("selectionDidChange") }
    }
}

struct SystemKeyboardSnapshot {
    let event: String
    let text: String
    let markedText: String?
    let selection: NSRange
    let markedRange: NSRange?
    var description: String {
        "\(event) selection=\(selection) mark=\(markedRange.map { NSStringFromRange($0) } ?? "nil") text=\(text)"
    }
}

/// Observes the real host UITextInput methods without simulating a proxy or
/// altering their order, marked ranges, selection, or returned context.
final class SystemKeyboardTextView: UITextView {
    var onSnapshot: ((SystemKeyboardSnapshot) -> Void)?
    func record(_ event: String) {
        let range = markedTextRange.map {
            NSRange(location: offset(from: beginningOfDocument, to: $0.start), length: offset(from: $0.start, to: $0.end))
        }
        let snapshot = SystemKeyboardSnapshot(event: event, text: text ?? "",
            markedText: markedTextRange.flatMap { self.text(in: $0) }, selection: selectedRange, markedRange: range)
        // Delegate callbacks can run during a SwiftUI update (e.g. focus). Only
        // observe; defer publication so the view's state cannot rewrite the input.
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        record("setMarkedText(\(markedText?.utf16.count ?? 0))")
    }
    override func unmarkText() { super.unmarkText(); record("unmarkText") }
    override func insertText(_ text: String) { super.insertText(text); record("insertText(\(text.utf16.count))") }
}
