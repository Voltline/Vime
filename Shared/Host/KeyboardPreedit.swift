import Foundation

/// UIKit selection offsets are UTF-16. Native byte offsets must be converted
/// explicitly; neither Swift Character counts nor UTF-8 bytes are NSRange units.
nonisolated struct KeyboardPreedit: Equatable, Sendable {
    let text: String
    let selectedRange: NSRange

    init(text: String) {
        self.text = text
        selectedRange = NSRange(location: text.utf16.count, length: 0)
    }

    init?(text: String, selectedRange: NSRange) {
        guard selectedRange.location >= 0, selectedRange.length >= 0,
              selectedRange.location <= text.utf16.count,
              selectedRange.length <= text.utf16.count - selectedRange.location else { return nil }
        let start = text.utf16.index(text.utf16.startIndex, offsetBy: selectedRange.location)
        let end = text.utf16.index(start, offsetBy: selectedRange.length)
        guard String.Index(start, within: text) != nil, String.Index(end, within: text) != nil else { return nil }
        self.text = text; self.selectedRange = selectedRange
    }

    static func fromUTF8(_ text: String, selectedRange: NSRange) -> Self? {
        guard selectedRange.location >= 0, selectedRange.length >= 0,
              selectedRange.location <= text.utf8.count,
              selectedRange.length <= text.utf8.count - selectedRange.location else { return nil }
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: selectedRange.location)
        let end = text.utf8.index(start, offsetBy: selectedRange.length)
        guard let lower = String.Index(start, within: text), let upper = String.Index(end, within: text) else { return nil }
        return Self(text: text, selectedRange: NSRange(lower..<upper, in: text))
    }
}
