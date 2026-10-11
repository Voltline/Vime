import Foundation

/// A proxy may report a committed insertion after insertText has returned.
/// Recognize only the exact partial commit we issued, not an arbitrary grace
/// period during which caret/document changes would be ignored.
nonisolated struct KeyboardPartialCommitReceipt {
    let document: String
    private let prefix: String
    private let after: String?
    private var markedTails: [String]

    init?(document: String, before: String?, after: String?, selection: String?,
          ownedMark: String?, edits: [KeyboardEdit], preedit: KeyboardPreedit?) {
        guard let before, selection?.isEmpty != false,
              let ownedMark, !ownedMark.isEmpty, before.hasSuffix(ownedMark),
              let preedit, !preedit.text.isEmpty, edits.count == 1,
              case let .insert(text) = edits[0] else { return nil }
        self.document = document
        prefix = String(before.dropLast(ownedMark.count)) + text
        self.after = after
        markedTails = [preedit.text]
    }

    mutating func updatePreedit(_ preedit: KeyboardPreedit) {
        if markedTails.last != preedit.text {
            markedTails.append(preedit.text)
            if markedTails.count > 2 { markedTails.removeFirst() }
        }
    }

    func acknowledges(document: String, before: String?, after: String?, selection: String?) -> Bool {
        guard document == self.document, after == self.after, selection?.isEmpty != false,
              let before else { return false }
        // The host can acknowledge the committed prefix before exposing the new
        // mark. Bounded suffix comparison respects the proxy's context window.
        return ([prefix] + markedTails.map { prefix + $0 }).contains {
            String(before.suffix(96)) == String($0.suffix(96))
        }
    }

    func hasFinalAcknowledgement(before: String?) -> Bool {
        guard let before, let mark = markedTails.last else { return false }
        return String(before.suffix(96)) == String((prefix + mark).suffix(96))
    }
}
