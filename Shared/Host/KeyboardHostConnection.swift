import Foundation

struct KeyboardUndoAnchor: Equatable {
    let document: String
    let before: String?
    let after: String?
    let selection: String?
}

/// Tracks the preedit sent to the host. Each setMarkedText replaces its range;
/// compound writes through a remote proxy are not an atomic transaction.
/// Ordinary commits do not reconstruct or delete surrounding text.
final class KeyboardHostConnection {
    private let setMarkedText: (String, NSRange) -> Void
    private let unmarkText: () -> Void
    private let insertText: (String) -> Void
    private let deleteBackward: () -> Void
    private let moveCursor: (Int, Int) -> Void
    private let adjustInsertionPosition: (Int) -> Void
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
         adjustInsertionPosition: @escaping (Int) -> Void = { _ in },
         deleteToLineStart: @escaping () -> String = { "" },
         undoAnchor: @escaping () -> KeyboardUndoAnchor? = { nil }) {
        self.setMarkedText = setMarkedText
        self.unmarkText = unmarkText
        self.insertText = insertText
        self.deleteBackward = deleteBackward
        self.moveCursor = moveCursor
        self.adjustInsertionPosition = adjustInsertionPosition
        self.deleteToLineStart = deleteToLineStart
        self.undoAnchor = undoAnchor
    }

    func updatePreedit(_ preedit: KeyboardPreedit?) {
        guard let preedit, !preedit.text.isEmpty else { clearMarkedText(); return }
        guard preedit != markedPreedit else { return }
        discardDeletionUndo()
        setMarkedText(preedit.text, preedit.selectedRange)
        markedPreedit = preedit
    }

    func apply(_ edits: [KeyboardEdit]) {
        apply(edits, keepsMarkedSession: false)
    }

    /// A remote proxy can deliver unmarkText after subsequent setMarkedText
    /// writes. While continuing a segmented conversion, replace the old mark
    /// without ending the marked session; otherwise that delayed unmark commits
    /// the new suffix and the next selection appends a duplicate.
    func apply(_ edits: [KeyboardEdit], preedit: KeyboardPreedit?) {
        apply(edits, keepsMarkedSession: preedit?.text.isEmpty == false)
        updatePreedit(preedit)
    }

    /// Verify before touching the mark; delete a fixed, known suffix exactly
    /// once. Never loop on a proxy context that may lag behind remote writes.
    @discardableResult
    func replaceText(_ replacement: KeyboardTextReplacement) -> Bool {
        guard let snapshot = undoAnchor(), snapshot.selection?.isEmpty != false,
              snapshot.document == replacement.anchor.document,
              !replacement.anchor.hasSelection,
              snapshot.after == replacement.anchor.after,
              markedText == replacement.markedText,
              let before = snapshot.before, let expected = replacement.anchor.before else { return false }
        let mark = markedText ?? ""
        let committed = !mark.isEmpty && before.hasSuffix(mark) ? String(before.dropLast(mark.count)) : before
        guard committed == expected, committed.hasSuffix(replacement.committedSuffix),
              replacement.committedSuffix.count + mark.count <= KeyboardCalculation.maximumCharacters else { return false }
        // Commit the owned mark before deleting the known expression. An empty
        // setMarkedText can be deferred remotely; deleting a live marked range
        // can remove the whole mark rather than a single character.
        if markedPreedit != nil { unmarkText() }
        markedPreedit = nil
        discardDeletionUndo()
        for _ in replacement.committedSuffix + mark { deleteBackward() }
        insertText(replacement.text)
        return true
    }

    private func apply(_ edits: [KeyboardEdit], keepsMarkedSession: Bool) {
        guard !edits.isEmpty else { return }
        clearMarkedText(endsSession: !keepsMarkedSession)
        for edit in edits {
            if case .undoLineDeletion = edit {} else { discardDeletionUndo() }
            switch edit {
            case .insert(let text): insertText(text)
            case .insertPair(let opening, let closing):
                insertText(opening + closing)
                adjustInsertionPosition(-closing.utf16.count)
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

    private func clearMarkedText(endsSession: Bool = true) {
        guard markedText != nil else { return }
        setMarkedText("", NSRange(location: 0, length: 0))
        if endsSession { unmarkText() }
        markedPreedit = nil
    }
}
