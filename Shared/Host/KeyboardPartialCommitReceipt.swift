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
    private var replacementStages: [String] = []
    private var pairedClosing: String?

    init?(document: String, before: String?, after: String?, selection: String?,
          ownedMark: String?, edits: [KeyboardEdit], preedit: KeyboardPreedit?) {
        guard selection?.isEmpty != false, !edits.isEmpty else { return nil }
        var text = ""
        for (index, edit) in edits.enumerated() {
            switch edit {
            case .insert(let value): text += value
            case .insertPair(let opening, let closing) where index == edits.count - 1:
                text += opening
                pairedClosing = closing
            default: return nil
            }
        }
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

    init?(replacement: KeyboardTextReplacement) {
        guard !replacement.anchor.hasSelection, let before = replacement.anchor.before,
              before.hasSuffix(replacement.committedSuffix),
              replacement.committedSuffix.count + (replacement.markedText?.count ?? 0) <= KeyboardCalculation.maximumCharacters else { return nil }
        document = replacement.anchor.document
        originalBefore = String(before.suffix(96)) + (replacement.markedText ?? "")
        left = String(before.dropLast(replacement.committedSuffix.count).suffix(96))
        prefix = left + replacement.text
        after = replacement.anchor.after
        markedTails = []
        let expression = replacement.committedSuffix + (replacement.markedText ?? "")
        var stage = String((before + (replacement.markedText ?? "")).suffix(96 + expression.count))
        replacementStages.append(stage)
        for _ in expression {
            stage.removeLast()
            replacementStages.append(stage)
        }
    }

    mutating func updatePreedit(_ preedit: KeyboardPreedit) {
        if markedTails.last != preedit.text {
            markedTails.append(preedit.text)
            if markedTails.count > 2 { markedTails.removeFirst() }
        }
    }

    func acknowledges(document: String, before: String?, after: String?, selection: String?) -> Bool {
        guard document == self.document, selection?.isEmpty != false,
              let before else { return false }
        // old mark -> empty mark -> committed prefix -> new mark. Context can
        // exclude the new mark entirely. Bounded suffixes match proxy windows.
        let expectedStates: [String]
        if let closing = pairedClosing, (after ?? "") == closing + (self.after ?? "") {
            expectedStates = [prefix] + markedTails.map { prefix + $0 }
        } else if (after ?? "") == (self.after ?? "") {
            expectedStates = [originalBefore, left, prefix + (pairedClosing ?? "")] + replacementStages
                + (pairedClosing == nil ? markedTails.map { prefix + $0 } : [])
        } else { return false }
        return expectedStates.contains {
            expected in
            guard !before.isEmpty, !expected.isEmpty else { return before == expected }
            // Deleting/replacing a mark changes how much older text fits in the
            // host's context window. Compare only the shared known suffix.
            let count = min(96, before.count, expected.count)
            return before.suffix(count) == expected.suffix(count)
        }
    }
}
