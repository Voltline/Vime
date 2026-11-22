import UIKit

/// Shared character-safe navigation and deletion. The App uses real text view
/// geometry; the extension estimates wrapped lines with KeyboardProxyCursorLayout.
enum KeyboardTextNavigation {
    static func horizontalOffset(before: String, after: String, steps: Int) -> Int {
        steps < 0 ? -before.suffix(-steps).utf16.count : after.prefix(steps).utf16.count
    }

    static func move(in view: UITextView, horizontal: Int, vertical: Int, preferredX: inout CGFloat?) {
        if horizontal == 0 && vertical == 0 { preferredX = nil; return }
        guard let range = view.selectedTextRange else { return }
        var caret = range.end
        if horizontal != 0 {
            preferredX = nil
            let before = view.textRange(from: view.beginningOfDocument, to: caret).flatMap { view.text(in: $0) } ?? ""
            let after = view.textRange(from: caret, to: view.endOfDocument).flatMap { view.text(in: $0) } ?? ""
            let offset = horizontalOffset(before: before, after: after, steps: horizontal)
            caret = view.position(from: caret, offset: offset) ?? caret
        }
        if vertical != 0 {
            let rect = view.caretRect(for: caret)
            let x = preferredX ?? rect.midX; preferredX = x
            let point = CGPoint(x: x, y: rect.midY + CGFloat(vertical) * max(rect.height, view.font?.lineHeight ?? 20))
            caret = view.closestPosition(to: point) ?? caret
        }
        view.selectedTextRange = view.textRange(from: caret, to: caret)
        view.scrollRangeToVisible(view.selectedRange)
    }

    @discardableResult
    static func deleteLinePrefix(in view: UITextView) -> String {
        guard let selection = view.selectedTextRange,
              let prefixRange = view.textRange(from: view.beginningOfDocument, to: selection.start),
              let before = view.text(in: prefixRange) else { return "" }
        let prefixStart = before.lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
        let prefix = before[prefixStart...]
        guard !prefix.isEmpty || !selection.isEmpty,
              let start = view.position(from: selection.start, offset: -prefix.utf16.count),
              let range = view.textRange(from: start, to: selection.end) else { return "" }
        let deleted = view.text(in: range) ?? ""
        view.replace(range, withText: "")
        return deleted
    }

    /// Number of characters to remove in one word-delete step during accelerated backspace.
    /// Removes trailing spaces plus one word (ASCII/Latin/digits) or a short CJK chunk (up to 2 chars),
    /// stopping at newlines and punctuation boundaries.
    nonisolated static func trailingWordDeletionCount(in before: String) -> Int {
        guard !before.isEmpty else { return 1 }
        var index = before.endIndex
        var count = 0
        // Consume a single newline on its own.
        let last = before[before.index(before: index)]
        if last.isNewline { return 1 }
        // Consume any trailing horizontal whitespace first.
        while index > before.startIndex {
            let prev = before.index(before: index)
            let ch = before[prev]
            if ch.isWhitespace && !ch.isNewline {
                index = prev
                count += 1
            } else {
                break
            }
        }
        guard index > before.startIndex else { return max(1, count) }
        let anchor = before[before.index(before: index)]
        let isLatinWord: (Character) -> Bool = { ch in
            ch.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII } || ch == "'" || ch == "_"
        }
        if isLatinWord(anchor) {
            while index > before.startIndex {
                let prev = before.index(before: index)
                if isLatinWord(before[prev]) {
                    index = prev
                    count += 1
                } else {
                    break
                }
            }
            return max(1, count)
        }
        let isCJK: (Character) -> Bool = { ch in
            ch.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
        }
        if isCJK(anchor) {
            var taken = 0
            while index > before.startIndex && taken < 2 {
                let prev = before.index(before: index)
                if isCJK(before[prev]) {
                    index = prev
                    count += 1
                    taken += 1
                } else {
                    break
                }
            }
            return max(1, count)
        }
        // Single punctuation / emoji / symbol grapheme cluster.
        return max(1, count + 1)
    }
}

/// A proxy provides text, not host layout. Estimate soft wraps using a reusable
/// TextKit view; this is approximate when the host uses a different width/font.
final class KeyboardProxyCursorLayout {
    private let layout = UITextView()
    private var text = ""
    private var width: CGFloat = 80
    private var laidOut = false
    private var gestureCaret: Int?
    private var gestureX: CGFloat?
    init() {
        layout.font = .systemFont(ofSize: 17)
        layout.textContainerInset = .zero
        layout.textContainer.lineFragmentPadding = 0
    }
    /// Starting a gesture only records the text: wrapping is laid out on the
    /// first vertical step, so a horizontal drag never pays for TextKit.
    func beginGesture(before: String, after: String, width: CGFloat) {
        text = before + after
        self.width = max(80, width)
        laidOut = false
        gestureCaret = before.utf16.count
        gestureX = nil
    }
    /// Keep text passed by the caret during this gesture. Some proxies return
    /// nil/truncated after-context after moving upward; rebuilding each step
    /// would make the new position the apparent document end and block down.
    func moveInGesture(horizontal: Int, vertical: Int) -> Int {
        guard let caret = gestureCaret else { return 0 }
        if vertical == 0 {
            // Whole characters over the recorded text, without layout.
            gestureX = nil
            let start = String.Index(utf16Offset: caret, in: text)
            let limit = horizontal < 0 ? text.startIndex : text.endIndex
            let end = text.index(start, offsetBy: horizontal, limitedBy: limit) ?? limit
            gestureCaret = end.utf16Offset(in: text)
            return gestureCaret! - caret
        }
        if !laidOut {
            layout.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
            layout.text = text
            layout.layoutManager.ensureLayout(for: layout.textContainer)
            laidOut = true
        }
        layout.selectedRange = NSRange(location: caret, length: 0)
        KeyboardTextNavigation.move(in: layout, horizontal: horizontal, vertical: vertical, preferredX: &gestureX)
        gestureCaret = layout.selectedRange.location
        return layout.selectedRange.location - caret
    }
}
