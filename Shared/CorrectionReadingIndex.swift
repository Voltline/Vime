import Foundation

/// Compact immutable lexical hints derived from the same pinned dictionary.
/// Hash collisions cannot invent candidates: final converter evidence is required.
nonisolated struct CorrectionReadingIndex {
    struct Entry {
        let value: Double
        let lcid: Int
        let rcid: Int
    }
    private let data: Data
    private let count: Int
    var isAvailable: Bool { count > 0 }
    init() {
        guard let url = Bundle.main.url(forResource: "CorrectionReadings", withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 8,
              String(decoding: data.prefix(4), as: UTF8.self) == "VCR2" else {
            self.data = Data(); count = 0; return
        }
        let count = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
        guard count <= (data.count - 8) / 20 else { self.data = Data(); self.count = 0; return }
        self.data = data; self.count = count
    }
    func entry(for reading: String) -> Entry? {
        guard count > 0 else { return nil }
        var hash: UInt64 = 14695981039346656037
        for byte in RomajiConverter.katakana(reading).utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return data.withUnsafeBytes { bytes in
            var lower = 0, upper = count
            while lower < upper {
                let mid = (lower + upper) / 2
                let key = bytes.loadUnaligned(fromByteOffset: 8 + mid * 20, as: UInt64.self).littleEndian
                if key < hash { lower = mid + 1 } else { upper = mid }
            }
            guard lower < count,
                  bytes.loadUnaligned(fromByteOffset: 8 + lower * 20, as: UInt64.self).littleEndian == hash else { return nil }
            let bits = bytes.loadUnaligned(fromByteOffset: 16 + lower * 20, as: UInt32.self).littleEndian
            let lcid = bytes.loadUnaligned(fromByteOffset: 20 + lower * 20, as: UInt16.self).littleEndian
            let rcid = bytes.loadUnaligned(fromByteOffset: 22 + lower * 20, as: UInt16.self).littleEndian
            return Entry(value: Double(Float(bitPattern: bits)), lcid: Int(lcid), rcid: Int(rcid))
        }
    }
}
