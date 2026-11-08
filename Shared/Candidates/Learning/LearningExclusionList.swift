import Foundation

/// Terms that must not be learned, remembered or predicted, stored as keyed
/// SipHash-2-4 values (`LearningExclusions.bin`, built by
/// `Scripts/build_learning_exclusions.py`). The terms themselves never ship.
/// Typing is never blocked; callers only skip learning and suggestions.
nonisolated struct LearningExclusionList: Sendable {
    static let shared = LearningExclusionList(bundle: .main)
    /// Must match K0/K1 in the build script.
    static let key: (UInt64, UInt64) = (0xDD14_D237_F99F_C171, 0xC869_2948_6087_1512)
    /// Longest match that an everyday word cutting through it can cancel.
    static let shortMatchLength = 3

    private let blocked: [UInt64]
    private let allowed: [UInt64]
    private let blockedLengths: [Int]
    private let allowedLengths: [Int]

    var isAvailable: Bool { !blocked.isEmpty }

    init(bundle: Bundle) {
        guard let url = bundle.url(forResource: "LearningExclusions", withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            self.init(data: Data()); return
        }
        self.init(data: data)
    }

    init(data: Data) {
        let header = 28
        guard data.count >= header, data.prefix(4) == Data("VLX1".utf8) else {
            blocked = []; allowed = []; blockedLengths = []; allowedLengths = []; return
        }
        let (blockedCount, allowedCount, blockedMask, allowedMask) = data.withUnsafeBytes { raw in
            (Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian),
             Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian),
             raw.loadUnaligned(fromByteOffset: 12, as: UInt64.self).littleEndian,
             raw.loadUnaligned(fromByteOffset: 20, as: UInt64.self).littleEndian)
        }
        guard data.count == header + 8 * (blockedCount + allowedCount) else {
            blocked = []; allowed = []; blockedLengths = []; allowedLengths = []; return
        }
        let values: [UInt64] = data.withUnsafeBytes { raw in
            (0..<(blockedCount + allowedCount)).map {
                raw.loadUnaligned(fromByteOffset: header + 8 * $0, as: UInt64.self).littleEndian
            }
        }
        blocked = Array(values.prefix(blockedCount))
        allowed = Array(values.dropFirst(blockedCount))
        blockedLengths = Self.lengths(blockedMask)
        allowedLengths = Self.lengths(allowedMask)
    }

    /// Builds a table in memory with the same layout as the bundled file.
    static func encode(blocked: [String], allowed: [String]) -> Data {
        func table(_ words: [String]) -> ([UInt64], UInt64) {
            var hashes = Set<UInt64>(), mask: UInt64 = 0
            for word in words {
                let scalars = normalized(word)
                guard !scalars.isEmpty, scalars.count < 64 else { continue }
                hashes.insert(hash(utf8(scalars)[...]))
                mask |= 1 << UInt64(scalars.count)
            }
            return (hashes.sorted(), mask)
        }
        let (b, bm) = table(blocked), (a, am) = table(allowed)
        var data = Data("VLX1".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(b.count)); append(UInt32(a.count)); append(bm); append(am)
        (b + a).forEach { append($0) }
        return data
    }

    /// Whether any blocked term occurs in `text`.
    func matches(_ text: String) -> Bool {
        guard isAvailable else { return false }
        let scalars = Self.normalized(text)
        guard !scalars.isEmpty else { return false }
        var bytes: [UInt8] = []
        var offsets = [0]
        bytes.reserveCapacity(scalars.count * 3)
        for scalar in scalars {
            UTF8.encode(scalar) { bytes.append($0) }
            offsets.append(bytes.count)
        }
        var everyday: [(start: Int, end: Int)]?
        for start in scalars.indices {
            for length in blockedLengths {
                let end = start + length
                guard end <= scalars.count else { break }
                guard Self.contains(blocked, Self.hash(bytes[offsets[start]..<offsets[end]])) else { continue }
                if length > Self.shortMatchLength { return true }
                if everyday == nil { everyday = occurrences(of: allowed, lengths: allowedLengths, bytes: bytes, offsets: offsets) }
                let cut = everyday!.contains { word in
                    (word.start < start && word.end > start && word.end < end)
                        || (word.start > start && word.start < end && word.end > end)
                }
                if !cut { return true }
            }
        }
        return false
    }

    private func occurrences(of table: [UInt64], lengths: [Int], bytes: [UInt8], offsets: [Int]) -> [(start: Int, end: Int)] {
        let count = offsets.count - 1
        var found: [(start: Int, end: Int)] = []
        for start in 0..<count {
            for length in lengths {
                let end = start + length
                guard end <= count else { break }
                if Self.contains(table, Self.hash(bytes[offsets[start]..<offsets[end]])) { found.append((start, end)) }
            }
        }
        return found
    }

    /// NFKC, then ASCII letters lowercased, as Unicode scalars.
    static func normalized(_ text: String) -> [Unicode.Scalar] {
        text.precomposedStringWithCompatibilityMapping.unicodeScalars.map {
            (65...90).contains($0.value) ? Unicode.Scalar($0.value + 32)! : $0
        }
    }

    private static func utf8(_ scalars: [Unicode.Scalar]) -> [UInt8] {
        var bytes: [UInt8] = []
        for scalar in scalars { UTF8.encode(scalar) { bytes.append($0) } }
        return bytes
    }

    private static func lengths(_ mask: UInt64) -> [Int] {
        (1..<64).filter { mask & (1 << UInt64($0)) != 0 }
    }

    private static func contains(_ sorted: [UInt64], _ value: UInt64) -> Bool {
        var lower = 0, upper = sorted.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if sorted[mid] < value { lower = mid + 1 } else { upper = mid }
        }
        return lower < sorted.count && sorted[lower] == value
    }

    static func hash(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        SipHash24.hash(bytes, k0: key.0, k1: key.1)
    }
}

/// SipHash-2-4 with a 64-bit result (Aumasson & Bernstein, 2012).
nonisolated enum SipHash24 {
    static func hash(_ bytes: ArraySlice<UInt8>, k0: UInt64, k1: UInt64) -> UInt64 {
        var v0 = k0 ^ 0x736F_6D65_7073_6575
        var v1 = k1 ^ 0x646F_7261_6E64_6F6D
        var v2 = k0 ^ 0x6C79_6765_6E65_7261
        var v3 = k1 ^ 0x7465_6462_7974_6573
        func round() {
            v0 &+= v1; v1 = v1.rotl(13); v1 ^= v0; v0 = v0.rotl(32)
            v2 &+= v3; v3 = v3.rotl(16); v3 ^= v2
            v0 &+= v3; v3 = v3.rotl(21); v3 ^= v0
            v2 &+= v1; v1 = v1.rotl(17); v1 ^= v2; v2 = v2.rotl(32)
        }
        var index = bytes.startIndex
        while bytes.endIndex - index >= 8 {
            var m: UInt64 = 0
            for i in 0..<8 { m |= UInt64(bytes[index + i]) << UInt64(8 * i) }
            v3 ^= m; round(); round(); v0 ^= m
            index += 8
        }
        var last = UInt64(truncatingIfNeeded: bytes.count) << 56
        for i in 0..<(bytes.endIndex - index) { last |= UInt64(bytes[index + i]) << UInt64(8 * i) }
        v3 ^= last; round(); round(); v0 ^= last
        v2 ^= 0xFF
        round(); round(); round(); round()
        return v0 ^ v1 ^ v2 ^ v3
    }
}

private extension UInt64 {
    nonisolated func rotl(_ shift: UInt64) -> UInt64 { (self << shift) | (self >> (64 - shift)) }
}
