import Foundation

/// Owns only the active marked range. UIKit replaces that range atomically;
/// no reconstruction or backward deletion of the surrounding document is used.
final class KeyboardHostConnection {
    private let setMarkedText: (String, NSRange) -> Void
    private let unmarkText: () -> Void
    private let insertText: (String) -> Void
    private let deleteBackward: () -> Void
    private(set) var markedText: String?

    init(setMarkedText: @escaping (String, NSRange) -> Void,
         unmarkText: @escaping () -> Void,
         insertText: @escaping (String) -> Void,
         deleteBackward: @escaping () -> Void) {
        self.setMarkedText = setMarkedText
        self.unmarkText = unmarkText
        self.insertText = insertText
        self.deleteBackward = deleteBackward
    }

    func updateMarkedText(_ text: String?) {
        guard let text, !text.isEmpty else { clearMarkedText(); return }
        guard text != markedText else { return }
        setMarkedText(text, NSRange(location: text.utf16.count, length: 0))
        markedText = text
    }

    func apply(_ edits: [KeyboardEdit]) {
        guard !edits.isEmpty else { return }
        clearMarkedText()
        for edit in edits {
            switch edit {
            case .insert(let text): insertText(text)
            case .deleteBackward: deleteBackward()
            case .returnKey: insertText("\n")
            }
        }
    }

    /// Called after an external caret/document change. UIKit has already ended
    /// the old mark; forgetting ownership must not edit the new input location.
    func abandon() { markedText = nil }

    private func clearMarkedText() {
        guard markedText != nil else { return }
        setMarkedText("", NSRange(location: 0, length: 0))
        unmarkText()
        markedText = nil
    }
}
