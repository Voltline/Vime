import Foundation

/// Recognizes the finite document states produced by a candidate commit. UIKit
/// writes and proxy context notifications need not arrive in the same turn.
/// Keep the transaction through later candidate publications: observing the
/// final mark once does not prove all earlier write notifications were drained.
/// No time window or arbitrary context change is accepted.
nonisolated struct KeyboardPartialCommitReceipt {
    let document: String
    private let originalBefore: String
    private let left: String
    private let prefix: String
    private let after: String?
    private var markedTails: [String]

    init?(document: String, before: String?, after: String?, selection: String?,
          ownedMark: String?, edits: [KeyboardEdit], preedit: KeyboardPreedit?) {
        guard selection?.isEmpty != false, edits.count == 1,
              case let .insert(text) = edits[0] else { return nil }
        // A proxy can exclude its owned mark and expose nil at an empty left
        // boundary. Its later nonnil committed suffix is still a valid receipt.
        let before = before ?? ""
        self.document = document
        originalBefore = before
        // Some proxies return context outside the marked range. Do not require
        // them to echo the owned preedit as part of their left context.
        let mark = ownedMark ?? ""
        left = !mark.isEmpty && before.hasSuffix(mark) ? String(before.dropLast(mark.count)) : before
        prefix = left + text
        self.after = after
        markedTails = preedit.map { [$0.text] } ?? []
    }

    mutating func updatePreedit(_ preedit: KeyboardPreedit) {
        if markedTails.last != preedit.text {
            markedTails.append(preedit.text)
            if markedTails.count > 2 { markedTails.removeFirst() }
        }
    }

    func acknowledges(document: String, before: String?, after: String?, selection: String?) -> Bool {
        guard document == self.document, (after ?? "") == (self.after ?? ""), selection?.isEmpty != false,
              let before else { return false }
        // old mark -> empty mark -> committed prefix -> new mark. Context can
        // exclude the new mark entirely. Bounded suffixes match proxy windows.
        return ([originalBefore, left, prefix] + markedTails.map { prefix + $0 }).contains {
            expected in
            guard !before.isEmpty, !expected.isEmpty else { return before == expected }
            // Deleting/replacing a mark changes how much older text fits in the
            // host's context window. Compare only the shared known suffix.
            let count = min(96, before.count, expected.count)
            return before.suffix(count) == expected.suffix(count)
        }
    }
}
