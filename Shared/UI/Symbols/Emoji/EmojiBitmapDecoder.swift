import CoreGraphics
import Foundation
import Compression

/// EMJ1 layout/predictors documented by EmojiFonts (MIT); see
/// Docs/ThirdParty/EmojiBitmapDecoding.md for sources and attribution.
/// Unknown versions, truncated streams and invalid dimensions fail safely.
nonisolated enum EmojiBitmapDecoder {
    @inline(__always) private static func normalized(_ value: Int) -> Int {
        let remainder = value % 257
        return remainder < 0 ? remainder + 257 : remainder
    }
    static func decode(_ data: Data) -> CGImage? {
        guard data.uint32(at: 0) == 0x656d6a31,
              let version = data.uint16(at: 4, littleEndian: true), [0, 256].contains(version),
              data.uint16(at: 6, littleEndian: true) == 0xa101,
              let width = data.uint16(at: 8, littleEndian: true), let height = data.uint16(at: 10, littleEndian: true),
              width > 0, height > 0, width <= 512, height <= 512,
              let appendix = data.uint16(at: 12, littleEndian: true), data.count > 16 else { return nil }
        let pixels = width * height, components = pixels * 3
        let expected = pixels * 4 + height + appendix
        var decoded = [UInt8](repeating: 0, count: expected)
        let count = data.withUnsafeBytes { source in
            decoded.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, expected,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: 16), data.count - 16, nil, COMPRESSION_LZFSE)
            }
        }
        guard count == expected else { return nil }
        var channels = [Int](repeating: 0, count: components)
        var position = 0
        for byte in decoded.suffix(appendix) {
            position += Int(byte >> 2)
            guard position < components else { return nil }
            channels[position] = Int(byte & 3) * 128; position += 1
        }
        var output = [UInt8](repeating: 0, count: pixels * 4)
        // Dimensions and stream lengths were validated above. Buffer access
        // avoids repeated Array bounds/COW checks in the pixel predictor loop.
        let valid = decoded.withUnsafeBufferPointer { decoded in
            channels.withUnsafeMutableBufferPointer { channels in
                output.withUnsafeMutableBufferPointer { output -> Bool in
                    for row in 0..<height {
                        let filter = decoded[pixels + row]
                        guard filter <= 4 else { return false }
                        for column in 0..<width {
                            let pixel = row * width + column, index = pixel * 3
                            let left = column > 0 ? index - 3 : nil
                            let upper = row > 0 ? index - width * 3 : nil
                            var predictor: Int?
                            if filter == 1 {
                                if let left, let upper {
                                    let diagonal = channels[upper - 3]
                                    predictor = abs(channels[left] - diagonal) < abs(channels[upper] - diagonal) ? upper : left
                                } else { predictor = left ?? upper }
                            } else if filter == 2 { predictor = left }
                            else if filter == 3 { predictor = upper }
                            for channel in 0..<3 {
                                let encoded = Int(decoded[pixels + height + index + channel])
                                var value = encoded & 1 == 0 ? (encoded >> 1) + channels[index + channel] : -(encoded >> 1) - channels[index + channel]
                                if let predictor { value += channels[predictor + channel] }
                                else if filter == 4 {
                                    if let left, let upper { value += (channels[left + channel] + channels[upper + channel] + 1) / 2 }
                                    else if let neighbor = left ?? upper { value += channels[neighbor + channel] }
                                }
                                channels[index + channel] = value
                            }
                            let base = channels[index], p = channels[index + 1], q = channels[index + 2]
                            let red = base + (p >= 0 ? (p + 1) >> 1 : p >> 1) - (q >= 0 ? q >> 1 : (q + 1) >> 1)
                            let green = base + (q >= 0 ? (q + 1) >> 1 : q >> 1)
                            let blue = base - (p >= 0 ? p >> 1 : (p + 1) >> 1) - (q >= 0 ? q >> 1 : (q + 1) >> 1)
                            let b = normalized(blue), g = normalized(green), r = normalized(red)
                            guard b < 256, g < 256, r < 256 else { return false }
                            output[pixel * 4] = UInt8(b)
                            output[pixel * 4 + 1] = UInt8(g)
                            output[pixel * 4 + 2] = UInt8(r)
                            output[pixel * 4 + 3] = decoded[pixel]
                        }
                    }
                    return true
                }
            }
        }
        guard valid else { return nil }
        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
