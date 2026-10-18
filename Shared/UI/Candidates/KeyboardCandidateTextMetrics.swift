import UIKit
import CoreText

/// Core Text measures a single candidate without initializing NSStringDrawing's
/// drawing stack on the first keystroke. The bounded cache is shared by pooled
/// buttons, including candidates that move between the strip and expanded panel.
@MainActor
enum KeyboardCandidateTextMetrics {
    private struct Key: Hashable {
        let text: String
        let font: UIFont
    }
    private static var widths: [Key: CGFloat] = [:]
    private static var order: [Key] = []
    private static var preparingFonts = false
    nonisolated static let fontQueue = DispatchQueue(label: "com.Voltline.Vime.candidateFonts", qos: .userInitiated)

    static func prepareFonts() {
        guard !preparingFonts else { return }
        preparingFonts = true
        let fonts = [UIFont.systemFont(ofSize: 18), UIFont.systemFont(ofSize: 18, weight: .medium),
            UIFont.systemFont(ofSize: 10)]
        fontQueue.async {
            // UIFont is immutable and Sendable; Core Text supports background
            // layout. Views and the width cache stay on the main actor.
            autoreleasepool {
                for font in fonts {
                    // Small katakana extensions use another fallback path:
                    // the first ㇱ alone took >40 ms in a cold simulator process.
                    // Include annotation and keycap/symbol coverage as well.
                    let text = NSAttributedString(string: "あいうえおアイウエオㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ日本語漢字、。→ABC0123🙂2️⃣",
                        attributes: [.font: font])
                    _ = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)
                }
            }
        }
    }

    static func width(of text: String, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let lookupStarted = KeyboardPerformance.start()
        let key = Key(text: text, font: font)
        let cached = widths[key]
        KeyboardPerformance.record(.candidateWidthCacheLookup, since: lookupStarted)
        if let cached { return cached }
        // Candidate labels normally have one line. Preserve the widest-line
        // sizing for user phrases containing line breaks as well.
        let layoutStarted = KeyboardPerformance.start()
        let width = text.components(separatedBy: .newlines).reduce(CGFloat.zero) { width, line in
            let attributed = NSAttributedString(string: line, attributes: [.font: font])
            return max(width, CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)))
        }
        KeyboardPerformance.record(.candidateTextLayout, since: layoutStarted)
        let insertStarted = KeyboardPerformance.start()
        if text.utf8.count <= 1024 {
            if order.count == 256 { widths.removeValue(forKey: order.removeFirst()) }
            widths[key] = width
            order.append(key)
        }
        KeyboardPerformance.record(.candidateWidthCacheInsert, since: insertStarted)
        return width
    }
}
