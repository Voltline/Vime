import UIKit

/// Shared character-safe navigation and deletion. The App uses real text view
/// geometry; the extension estimates wrapped lines with KeyboardProxyCursorLayout.
enum KeyboardTextNavigation {
    static func horizontalOffset(before: String, after: String, steps: Int) -> Int {
        steps < 0 ? -before.suffix(-steps).utf16.count : after.prefix(steps).utf16.count
    }

    static func verticalOffset(before: String, after: String, steps: Int, column: inout Int?) -> Int {
        let text = Array(before + after)
        let caret = before.count
        let starts = [0] + text.indices.filter { text[$0].isNewline }.map { $0 + 1 }
        let row = starts.lastIndex(where: { $0 <= caret }) ?? 0
        let targetRow = min(starts.count - 1, max(0, row + steps))
        let preferred = column ?? (caret - starts[row]); column = preferred
        let end = targetRow + 1 < starts.count ? starts[targetRow + 1] - 1 : text.count
        let target = min(end, starts[targetRow] + preferred)
        return String(text.prefix(target)).utf16.count - before.utf16.count
    }

    static func move(in view: UITextView, horizontal: Int, vertical: Int, preferredX: inout CGFloat?) {
        if horizontal == 0 && vertical == 0 { preferredX = nil; return }
        guard let range = view.selectedTextRange else { return }
        var caret = range.end
        if horizontal != 0 {
            preferredX = nil
            let before = view.text(in: view.textRange(from: view.beginningOfDocument, to: caret)!) ?? ""
            let after = view.text(in: view.textRange(from: caret, to: view.endOfDocument)!) ?? ""
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
        let prefix = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
        guard !prefix.isEmpty, let start = view.position(from: selection.start, offset: -prefix.utf16.count),
              let range = view.textRange(from: start, to: selection.end) else { return "" }
        let deleted = view.text(in: range) ?? ""
        view.replace(range, withText: "")
        return deleted
    }
}

/// A proxy provides text, not host layout. Estimate soft wraps using a reusable
/// TextKit view; this is approximate when the host uses a different width/font.
final class KeyboardProxyCursorLayout {
    private let layout = UITextView()
    private var gestureCaret: Int?
    private var gestureX: CGFloat?
    init() {
        layout.font = .systemFont(ofSize: 17)
        layout.textContainerInset = .zero
        layout.textContainer.lineFragmentPadding = 0
    }
    func beginGesture(before: String, after: String, width: CGFloat) {
        layout.frame = CGRect(x: 0, y: 0, width: max(80, width), height: 2000)
        layout.text = before + after
        gestureCaret = before.utf16.count
        gestureX = nil
    }
    /// Keep text passed by the caret during this gesture. Some proxies return
    /// nil/truncated after-context after moving upward; rebuilding each step
    /// would make the new position the apparent document end and block down.
    func moveInGesture(horizontal: Int, vertical: Int) -> Int {
        guard let caret = gestureCaret else { return 0 }
        layout.selectedRange = NSRange(location: caret, length: 0)
        layout.layoutManager.ensureLayout(for: layout.textContainer)
        KeyboardTextNavigation.move(in: layout, horizontal: horizontal, vertical: vertical, preferredX: &gestureX)
        gestureCaret = layout.selectedRange.location
        return layout.selectedRange.location - caret
    }
    func verticalOffset(before: String, after: String, steps: Int, width: CGFloat, preferredX: inout CGFloat?) -> Int {
        layout.frame = CGRect(x: 0, y: 0, width: max(80, width), height: 2000)
        let text = before + after
        if layout.text != text { layout.text = text }
        layout.selectedRange = NSRange(location: before.utf16.count, length: 0)
        layout.layoutManager.ensureLayout(for: layout.textContainer)
        KeyboardTextNavigation.move(in: layout, horizontal: 0, vertical: steps, preferredX: &preferredX)
        return layout.selectedRange.location - before.utf16.count
    }
}
