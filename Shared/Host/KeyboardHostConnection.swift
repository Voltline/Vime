import Foundation

struct KeyboardUndoAnchor: Equatable {
    let document: String
    let before: String?
    let after: String?
    let selection: String?
}

/// Owns only the active marked range. UIKit replaces that range atomically;
/// no reconstruction or backward deletion of the surrounding document is used.
final class KeyboardHostConnection {
    private let setMarkedText: (String, NSRange) -> Void
    private let unmarkText: () -> Void
    private let insertText: (String) -> Void
    private let deleteBackward: () -> Void
    private let moveCursor: (Int, Int) -> Void
    private let deleteToLineStart: () -> String
    private let undoAnchor: () -> KeyboardUndoAnchor?
    private var deletedLine: (text: String, anchor: KeyboardUndoAnchor?)?
    var onUndoAvailabilityChange: ((Bool) -> Void)?
    var canUndoLineDeletion: Bool { deletedLine != nil && deletedLine?.anchor == undoAnchor() }
    private var markedPreedit: KeyboardPreedit?
    var markedText: String? { markedPreedit?.text }

    init(setMarkedText: @escaping (String, NSRange) -> Void,
         unmarkText: @escaping () -> Void,
         insertText: @escaping (String) -> Void,
         deleteBackward: @escaping () -> Void,
         moveCursor: @escaping (Int, Int) -> Void = { _, _ in },
         deleteToLineStart: @escaping () -> String = { "" },
         undoAnchor: @escaping () -> KeyboardUndoAnchor? = { nil }) {
        self.setMarkedText = setMarkedText
        self.unmarkText = unmarkText
        self.insertText = insertText
        self.deleteBackward = deleteBackward
        self.moveCursor = moveCursor
        self.deleteToLineStart = deleteToLineStart
        self.undoAnchor = undoAnchor
    }

    func updateMarkedText(_ text: String?) {
        updatePreedit(text.map { KeyboardPreedit(text: $0) })
    }

    func updatePreedit(_ preedit: KeyboardPreedit?) {
        guard let preedit, !preedit.text.isEmpty else { clearMarkedText(); return }
        guard preedit != markedPreedit else { return }
        discardDeletionUndo()
        setMarkedText(preedit.text, preedit.selectedRange)
        markedPreedit = preedit
    }

    func apply(_ edits: [KeyboardEdit]) {
        guard !edits.isEmpty else { return }
        clearMarkedText()
        for edit in edits {
            if case .undoLineDeletion = edit {} else { discardDeletionUndo() }
            switch edit {
            case .insert(let text): insertText(text)
            case .deleteBackward: deleteBackward()
            case .returnKey: insertText("\n")
            case .moveCursor(let horizontal, let vertical): moveCursor(horizontal, vertical)
            case .deleteToLineStart:
                let removed = deleteToLineStart()
                if !removed.isEmpty { deletedLine = (removed, undoAnchor()); onUndoAvailabilityChange?(true) }
            case .undoLineDeletion:
                if canUndoLineDeletion, let deletedLine { insertText(deletedLine.text) }
                discardDeletionUndo()
            }
        }
    }

    /// Called after an external caret/document change. UIKit has already ended
    /// the old mark; forgetting ownership must not edit the new input location.
    func abandon() { markedPreedit = nil; discardDeletionUndo() }

    private func discardDeletionUndo() {
        guard deletedLine != nil else { return }
        deletedLine = nil; onUndoAvailabilityChange?(false)
    }

    private func clearMarkedText() {
        guard markedText != nil else { return }
        setMarkedText("", NSRange(location: 0, length: 0))
        unmarkText()
        markedPreedit = nil
    }
}
