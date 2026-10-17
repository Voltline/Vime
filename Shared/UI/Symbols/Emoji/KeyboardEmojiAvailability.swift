import CoreText
import Foundation

/// Test shaping, rather than guessing support from the OS version. An older
/// system may have every scalar of a ZWJ sequence but no joined emoji cluster.
enum KeyboardEmojiAvailability {
    private static let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 30, nil)
    private static let queue = DispatchQueue(label: "com.Voltline.Vime.emoji", qos: .userInitiated)
    // Only accessed on queue; catalogs are immutable during a keyboard session.
    private static var cache: [String: [KeyboardSymbolCatalog.Item]] = [:]

    static func supports(_ text: String) -> Bool {
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        let line = CTLineCreateWithAttributedString(string)
        var clusterOrigin: CGPoint?
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName] else { return false }
            let name = CTFontCopyPostScriptName(runFont as! CTFont) as String
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            // Invisible selectors/joiners can have a separate fallback run.
            let advances = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)
            if advances == 0 { continue }
            guard !glyphs.contains(0) else { return false }
            guard name.contains("AppleColorEmoji") else { return false }
            // Apple composes mixed skin-tone handshakes/couples with multiple
            // overlaid glyphs at one origin. A glyph-count == 1 check wrongly
            // excludes those supported emoji. Decomposed ZWJ fallback advances
            // to separate origins instead.
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for position in positions {
                if let origin = clusterOrigin {
                    guard abs(position.x - origin.x) < 0.01, abs(position.y - origin.y) < 0.01 else { return false }
                } else { clusterOrigin = position }
            }
        }
        return clusterOrigin != nil
    }

    static func load(_ group: KeyboardSymbolCatalog.Group,
                     completion: @escaping ([KeyboardSymbolCatalog.Item]) -> Void) {
        queue.async {
            let items = cache[group.name] ?? group.items.filter { supports($0.text) }
            cache[group.name] = items
            DispatchQueue.main.async { completion(items) }
        }
    }
}
