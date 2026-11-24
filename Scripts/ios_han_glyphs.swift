// Lists the Han code points the iOS system font cascade can draw, for
// Scripts/ios_han_glyphs.txt. Run it inside a booted iOS simulator:
//
//   xcrun -sdk iphonesimulator swiftc -O -target arm64-apple-ios18.0-simulator Scripts/ios_han_glyphs.swift -o /tmp/ios_han_glyphs
//   xcrun simctl spawn booted /tmp/ios_han_glyphs > ranges.txt
//
// A character counts when the font the system picks for it, starting from
// the Simplified Chinese UI font, is not LastResort and has a glyph for it.
import CoreText
import Foundation

let base = CTFontCreateUIFontForLanguage(.system, 17, "zh-Hans" as CFString)!
let blocks: [ClosedRange<UInt32>] = [0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF,
                                     0x2A700...0x2EE5F, 0x2F800...0x2FA1F, 0x30000...0x323AF]
var drawn: [UInt32] = []
for block in blocks {
    for value in block {
        guard let scalar = Unicode.Scalar(value) else { continue }
        let text = String(Character(scalar))
        let font = CTFontCreateForString(base, text as CFString, CFRange(location: 0, length: text.utf16.count))
        if (CTFontCopyPostScriptName(font) as String).hasPrefix("LastResort") { continue }
        var units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        if CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), glyphs[0] != 0 {
            drawn.append(value)
        }
    }
}
var start = drawn.first ?? 0
var last = start
for value in drawn.dropFirst() {
    if value == last + 1 { last = value; continue }
    print(String(format: "%X-%X", start, last))
    (start, last) = (value, value)
}
if !drawn.isEmpty { print(String(format: "%X-%X", start, last)) }
