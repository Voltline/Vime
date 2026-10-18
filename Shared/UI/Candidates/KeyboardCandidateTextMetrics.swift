import UIKit
import CoreText

/// Core Text measures a single candidate without initializing NSStringDrawing's
/// drawing stack on the first keystroke. The bounded cache is shared by pooled
/// buttons, including candidates that move between the strip and expanded panel.
/// Immutable font/text layout may run on a worker; no view crosses queues.
nonisolated enum KeyboardCandidateTextMetrics {
    private struct Key: Hashable {
        let text: String
        let font: UIFont
    }
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var widths: [Key: CGFloat] = [:]
        private var order: [Key] = []
        private var preparingFonts = false
        func beginFontPreparation() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !preparingFonts else { return false }
            preparingFonts = true; return true
        }
        func width(for key: Key) -> CGFloat? {
            lock.lock(); defer { lock.unlock() }
            return widths[key]
        }
        func insert(_ width: CGFloat, for key: Key) {
            lock.lock(); defer { lock.unlock() }
            // Another worker may have measured the same text while the lock
            // was released. Never duplicate its entry in the eviction queue.
            guard widths[key] == nil else { return }
            if order.count == 256 { widths.removeValue(forKey: order.removeFirst()) }
            widths[key] = width; order.append(key)
        }
    }
    private static let cache = Cache()
    static let fontQueue = DispatchQueue(label: "com.Voltline.Vime.candidateFonts", qos: .userInitiated)

    static func prepareFonts() {
        guard cache.beginFontPreparation() else { return }
        let fonts = [UIFont.systemFont(ofSize: 18), UIFont.systemFont(ofSize: 18, weight: .medium),
            UIFont.systemFont(ofSize: 10)]
        fontQueue.async {
            // UIFont is immutable and Sendable; Core Text supports background
            // layout. The cache lock is never held during Core Text calls.
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

    static func prepare(_ presentation: CandidatePresentation, first: Bool) {
        _ = width(of: presentation.text, font: .systemFont(ofSize: 18))
        // Supplements retain the displayed order. A newly proposed first item
        // may instead be appended, so cache its regular weight as well.
        if first { _ = width(of: presentation.text, font: .systemFont(ofSize: 18, weight: .medium)) }
        if let note = presentation.annotation { _ = width(of: note, font: .systemFont(ofSize: 10)) }
    }

    static func width(of text: String, font: UIFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let lookupStarted = KeyboardPerformance.start()
        let key = Key(text: text, font: font)
        let cached = cache.width(for: key)
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
            cache.insert(width, for: key)
        }
        KeyboardPerformance.record(.candidateWidthCacheInsert, since: insertStarted)
        return width
    }
}
