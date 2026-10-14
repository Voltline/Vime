import CoreText
import Foundation
import ImageIO

/// Read-only reference to the installed font table, obtained through CoreText.
/// The large sbix table is never copied; only requested glyph bytes are read.
/// sbix: https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6sbix.html
nonisolated final class EmojiBitmapFont {
    struct Strike { let offset: Int; let end: Int; let ppem: CGFloat }
    struct Bitmap { let image: CGImage; let origin: CGPoint; let flipped: Bool; let ppem: CGFloat }
    private let data: Data
    private let glyphCount: Int
    private let strikes: [Strike]

    init?(font: CTFont) {
        // CoreText returns a retained table reference, not a copy (Apple docs).
        // Keep that owner alive for the exact lifetime of this read-only view.
        // No font path, TTC face assumptions or whole-table Data bridge/copy.
        guard let table = CTFontCopyTable(font, CTFontTableTag(0x73626978), CTFontTableOptions(rawValue: 0)),
              let pointer = CFDataGetBytePtr(table) else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer),
            count: CFDataGetLength(table), deallocator: .custom { _, _ in withExtendedLifetime(table) {} })
        let sbix = 0..<data.count, glyphCount = CTFontGetGlyphCount(font)
        guard glyphCount > 0, data.uint16(at: 0) == 1,
              let count = data.uint32(at: 4), count > 0, count <= 16, 8 + count * 4 <= data.count else { return nil }
        var strikes = [Strike]()
        for index in 0..<count {
            guard let relative = data.uint32(at: sbix.lowerBound + 8 + index * 4), relative < sbix.count else { return nil }
            let offset = sbix.lowerBound + relative
            guard let ppem = data.uint16(at: offset), ppem > 0,
                  4 + (glyphCount + 1) * 4 <= sbix.upperBound - offset else { return nil }
            strikes.append(Strike(offset: offset, end: sbix.upperBound, ppem: CGFloat(ppem)))
        }
        self.data = data; self.glyphCount = glyphCount; self.strikes = strikes.sorted { $0.ppem < $1.ppem }
    }
    func strike(for pixels: CGFloat) -> Strike { strikes.first { $0.ppem >= pixels } ?? strikes.last! }
    func hasBitmap(glyph: Int) -> Bool {
        guard glyph >= 0, glyph < glyphCount else { return false }
        return strikes.contains {
            guard let start = data.uint32(at: $0.offset + 4 + glyph * 4),
                  let end = data.uint32(at: $0.offset + 4 + (glyph + 1) * 4) else { return false }
            return end > start
        }
    }
    func bitmap(glyph: Int, strike: Strike) -> Bitmap? {
        if let bitmap = bitmap(glyph: glyph, strike: strike, visited: []) { return bitmap }
        // Some system-font strikes omit individual glyphs. Decode another
        // embedded resolution instead of falling back to CoreText drawing.
        for alternative in strikes.sorted(by: { abs($0.ppem - strike.ppem) < abs($1.ppem - strike.ppem) }) where alternative.ppem != strike.ppem {
            if let bitmap = bitmap(glyph: glyph, strike: alternative, visited: []) { return bitmap }
        }
        return nil
    }
    private func bitmap(glyph: Int, strike: Strike, visited: Set<Int>) -> Bitmap? {
        guard glyph >= 0, glyph < glyphCount, !visited.contains(glyph), visited.count < 8,
              let start = data.uint32(at: strike.offset + 4 + glyph * 4),
              let end = data.uint32(at: strike.offset + 4 + (glyph + 1) * 4), end >= start + 8,
              end <= strike.end - strike.offset else { return nil }
        let offset = strike.offset + start
        guard let x = data.uint16(at: offset), let y = data.uint16(at: offset + 2), let type = data.uint32(at: offset + 4) else { return nil }
        let origin = CGPoint(x: CGFloat(Int16(bitPattern: UInt16(x))), y: CGFloat(Int16(bitPattern: UInt16(y))))
        if type == 0x64757065 || type == 0x666c6970 { // dupe / horizontal flip
            guard end - start >= 10, let reference = data.uint16(at: offset + 8),
                  let base = bitmap(glyph: reference, strike: strike, visited: visited.union([glyph])) else { return nil }
            return Bitmap(image: base.image, origin: origin, flipped: base.flipped != (type == 0x666c6970), ppem: strike.ppem)
        }
        let payload = data.subdata(in: (offset + 8)..<(strike.offset + end))
        let image: CGImage?
        if type == 0x656d6a63 { image = EmojiBitmapDecoder.decode(payload) } // emjc
        else if [0x706e6720, 0x6a706720, 0x74696666].contains(type), let source = CGImageSourceCreateWithData(payload as CFData, nil) {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else { image = nil }
        guard let image else { return nil }
        return Bitmap(image: image, origin: origin, flipped: false, ppem: strike.ppem)
    }
}

nonisolated extension Data {
    fileprivate func integer(at offset: Int, length: Int, littleEndian: Bool = false) -> Int? {
        guard offset >= 0, offset <= count - length else { return nil }
        return withUnsafeBytes { bytes in
            var value = 0
            for index in 0..<length {
                value = (value << 8) | Int(bytes[offset + (littleEndian ? length - 1 - index : index)])
            }
            return value
        }
    }
    func uint16(at offset: Int, littleEndian: Bool = false) -> Int? { integer(at: offset, length: 2, littleEndian: littleEndian) }
    func uint32(at offset: Int) -> Int? { integer(at: offset, length: 4) }
}
