import Foundation

/// Memory-mapped sorted binary Korean lexicon and next-word bigram store (`VKL1`).
///
/// Design invariants:
/// - Never loaded unless Korean input is active (lazy `ensureLoaded()`).
/// - Uses `.mappedIfSafe` and binary search directly over mapped bytes; never
///   materializes the lexicon into a Swift `Dictionary` or `Array`.
/// - `release()` unmaps the backing `Data` immediately when leaving Korean mode.
nonisolated final class KoreanLexicon: @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let surface: String
        let freq: UInt16
        let flags: UInt8

        var isNoun: Bool { (flags & 0x01) != 0 }
        var isVerbOrAdj: Bool { (flags & 0x02) != 0 }
        var isCommonWord: Bool { (flags & 0x04) != 0 }
    }

    struct NextWord: Equatable, Sendable {
        let surface: String
        let score: UInt16
    }

    /// Must match `SIPHASH_K0` / `SIPHASH_K1` in `Scripts/build_korean_lexicon.py`.
    static let hashKey: (UInt64, UInt64) = (0x564B_4C31_4B4F_5230, 0x9E37_79B9_7F4A_7C15)

    static let shared = KoreanLexicon(bundle: .main, resource: "KoreanLexicon")

    private let lock = NSLock()
    private let bundle: Bundle?
    private let resourceName: String?
    private let fixedData: Data?

    private var mappedData: Data?
    private var wordCount = 0
    private var bigramCount = 0
    private var wordsOffset = 0
    private var bigramsOffset = 0
    private var stringsOffset = 0

    init(bundle: Bundle, resource: String = "KoreanLexicon") {
        self.bundle = bundle
        self.resourceName = resource
        self.fixedData = nil
    }

    init(data: Data) {
        self.bundle = nil
        self.resourceName = nil
        self.fixedData = data
        lock.lock()
        _ = parseLocked(data)
        lock.unlock()
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return mappedData != nil
    }

    /// Releases the memory-mapped file so zero Korean pages remain resident.
    func release() {
        lock.lock()
        if fixedData == nil {
            mappedData = nil
            wordCount = 0
            bigramCount = 0
            wordsOffset = 0
            bigramsOffset = 0
            stringsOffset = 0
        }
        lock.unlock()
    }

    private func ensureLoadedLocked() -> Data? {
        if let data = mappedData { return data }
        if let fixed = fixedData {
            return parseLocked(fixed) ? fixed : nil
        }
        guard let bundle, let resourceName,
              let url = bundle.url(forResource: resourceName, withExtension: "bin"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return parseLocked(data) ? data : nil
    }

    private func parseLocked(_ data: Data) -> Bool {
        guard data.count >= 32, data.prefix(4) == Data("VKL1".utf8) else { return false }
        let (version, wCount, bCount, wOff, bOff, sOff) = data.withUnsafeBytes { raw in
            (
                raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian,
                Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian),
                Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian),
                Int(raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian),
                Int(raw.loadUnaligned(fromByteOffset: 20, as: UInt32.self).littleEndian),
                Int(raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian)
            )
        }
        guard version == 1,
              wOff >= 32,
              bOff == wOff + wCount * 16,
              sOff == bOff + bCount * 16,
              sOff <= data.count else {
            return false
        }
        self.mappedData = data
        self.wordCount = wCount
        self.bigramCount = bCount
        self.wordsOffset = wOff
        self.bigramsOffset = bOff
        self.stringsOffset = sOff
        return true
    }

    // MARK: - Queries

    /// Exact lookup by decomposed 2-beolsik jamo string. O(log W).
    func exactMatch(jamo: String) -> Entry? {
        guard !jamo.isEmpty else { return nil }
        let keyBytes = Array(jamo.utf8)
        lock.lock()
        defer { lock.unlock() }
        guard let data = ensureLoadedLocked(), wordCount > 0 else { return nil }
        return data.withUnsafeBytes { raw in
            let index = lowerBoundWord(raw: raw, target: keyBytes)
            guard index < wordCount, compareWordJamo(raw: raw, index: index, to: keyBytes) == 0 else {
                return nil
            }
            return readWordEntry(raw: raw, index: index)
        }
    }

    /// Exact lookup by precomposed Hangul surface string. O(log W).
    func exactMatch(surface: String) -> Entry? {
        guard !surface.isEmpty else { return nil }
        let jamo = String(HangulComposer.decomposeToJamo(surface))
        let keyBytes = Array(jamo.utf8)
        lock.lock()
        defer { lock.unlock() }
        guard let data = ensureLoadedLocked(), wordCount > 0 else { return nil }
        return data.withUnsafeBytes { raw in
            var index = lowerBoundWord(raw: raw, target: keyBytes)
            while index < wordCount, compareWordJamo(raw: raw, index: index, to: keyBytes) == 0 {
                let entry = readWordEntry(raw: raw, index: index)
                if entry.surface == surface { return entry }
                index += 1
            }
            return nil
        }
    }

    /// Whether any lexicon word's decomposed jamo starts with `jamoPrefix`. O(log W).
    func hasPrefix(jamoPrefix: String) -> Bool {
        guard !jamoPrefix.isEmpty else { return true }
        let prefixBytes = Array(jamoPrefix.utf8)
        lock.lock()
        defer { lock.unlock() }
        guard let data = ensureLoadedLocked(), wordCount > 0 else { return false }
        return data.withUnsafeBytes { raw in
            let index = lowerBoundWord(raw: raw, target: prefixBytes)
            guard index < wordCount else { return false }
            return wordJamoHasPrefix(raw: raw, index: index, prefix: prefixBytes)
        }
    }

    /// Prefix completions for a decomposed 2-beolsik jamo prefix, returning the global
    /// top `limit` highest-frequency words across the entire matching prefix range.
    ///
    /// Scans only the 2-byte `freq` field per record inside the binary-searched
    /// `[start, end)` range and decodes UTF-8 surfaces only for the final winners.
    func completions(forJamoPrefix jamoPrefix: String, limit: Int = 12) -> [Entry] {
        guard !jamoPrefix.isEmpty, limit > 0 else { return [] }
        let prefixBytes = Array(jamoPrefix.utf8)
        lock.lock()
        defer { lock.unlock() }
        guard let data = ensureLoadedLocked(), wordCount > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let start = lowerBoundWord(raw: raw, target: prefixBytes)
            guard start < wordCount, wordJamoHasPrefix(raw: raw, index: start, prefix: prefixBytes) else {
                return []
            }
            let end = upperBoundPrefix(raw: raw, from: start, prefix: prefixBytes)
            guard end > start else { return [] }

            // Maintain a bounded top-`limit` list (smallest element at index 0 via min-heap
            // or simple insertion when limit is small, typically <= 12).
            var top: [(freq: UInt16, surfLen: UInt16, index: Int)] = []
            top.reserveCapacity(limit)
            var minFreq: UInt16 = 0
            var minPos = 0

            for i in start..<end {
                let recBase = wordsOffset + i * 16
                let freq = raw.loadUnaligned(fromByteOffset: recBase + 12, as: UInt16.self).littleEndian
                if top.count < limit {
                    let surfLen = raw.loadUnaligned(fromByteOffset: recBase + 6, as: UInt16.self).littleEndian
                    top.append((freq, surfLen, i))
                    if top.count == limit {
                        minPos = 0
                        minFreq = top[0].freq
                        for k in 1..<limit {
                            if top[k].freq < minFreq || (top[k].freq == minFreq && top[k].surfLen > top[minPos].surfLen) {
                                minFreq = top[k].freq
                                minPos = k
                            }
                        }
                    }
                } else if freq >= minFreq {
                    let surfLen = raw.loadUnaligned(fromByteOffset: recBase + 6, as: UInt16.self).littleEndian
                    if freq > minFreq || surfLen < top[minPos].surfLen {
                        top[minPos] = (freq, surfLen, i)
                        minPos = 0
                        minFreq = top[0].freq
                        for k in 1..<limit {
                            if top[k].freq < minFreq || (top[k].freq == minFreq && top[k].surfLen > top[minPos].surfLen) {
                                minFreq = top[k].freq
                                minPos = k
                            }
                        }
                    }
                }
            }

            top.sort { lhs, rhs in
                if lhs.freq != rhs.freq { return lhs.freq > rhs.freq }
                if lhs.surfLen != rhs.surfLen { return lhs.surfLen < rhs.surfLen }
                return lhs.index < rhs.index
            }
            return top.map { readWordEntry(raw: raw, index: $0.index) }
        }
    }

    /// Next-word bigram suggestions following `previousWord`. O(log B).
    func nextWords(after previousWord: String, limit: Int = 8) -> [NextWord] {
        guard !previousWord.isEmpty, limit > 0 else { return [] }
        let targetHash = Self.hash(previousWord)
        lock.lock()
        defer { lock.unlock() }
        guard let data = ensureLoadedLocked(), bigramCount > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            var low = 0
            var high = bigramCount
            while low < high {
                let mid = (low + high) / 2
                let h = raw.loadUnaligned(fromByteOffset: bigramsOffset + mid * 16, as: UInt64.self).littleEndian
                if h < targetHash { low = mid + 1 } else { high = mid }
            }
            var results: [NextWord] = []
            results.reserveCapacity(limit)
            var i = low
            while i < bigramCount && results.count < limit {
                let base = bigramsOffset + i * 16
                let h = raw.loadUnaligned(fromByteOffset: base, as: UInt64.self).littleEndian
                if h != targetHash { break }
                let wordIdx = Int(raw.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self).littleEndian)
                let score = raw.loadUnaligned(fromByteOffset: base + 12, as: UInt16.self).littleEndian
                if wordIdx < wordCount {
                    let entry = readWordEntry(raw: raw, index: wordIdx)
                    results.append(NextWord(surface: entry.surface, score: score))
                }
                i += 1
            }
            return results
        }
    }

    // MARK: - Stem + Particle (조사) Expansion

    /// Common Korean nominal particles paired by batchim (받침) phonology.
    private static let particlesNoBatchim = ["는", "가", "를", "에", "에서", "로", "도", "의", "와", "만", "부터", "까지", "처럼", "보다", "한테"]
    private static let particlesWithBatchim = ["은", "이", "을", "에", "에서", "으로", "도", "의", "과", "만", "부터", "까지", "처럼", "보다", "한테"]
    private static let particlesRieulBatchim = ["은", "이", "을", "에", "에서", "로", "도", "의", "과", "만", "부터", "까지", "처럼", "보다", "한테"]

    /// Generates phonologically valid `stem + particle` completions for the current word.
    ///
    /// Handles both:
    /// 1. Complete noun stem typed (`학교` -> `학교에`, `학교에서`, `학교는`, `학교를`)
    /// 2. Noun stem + partial particle jamo (`학교ㅇㅔㅅ` -> `학교에서`, `시간ㅇㅡ` -> `시간은`, `시간을`, `시간으로`)
    func particleCompletions(forComposed text: String, jamoPrefix: String, limit: Int = 6) -> [String] {
        guard !text.isEmpty, limit > 0 else { return [] }
        var results: [String] = []
        var seen: Set<String> = [text]

        // Case 1: The full composed text itself is a tagged noun -> suggest top particles.
        if text.count >= 1,
           let entry = exactMatch(surface: text), entry.isNoun,
           let particles = Self.particles(forStem: text) {
            for p in particles {
                let candidate = text + p
                if seen.insert(candidate).inserted {
                    results.append(candidate)
                    if results.count >= limit { return results }
                }
            }
        }

        // Case 2: Leading syllables form a tagged noun, and trailing jamo are a prefix of a particle.
        let chars = Array(text)
        if chars.count >= 2 {
            let minStem = max(1, chars.count - 2)
            let maxStem = chars.count - 1
            for stemLen in stride(from: maxStem, through: minStem, by: -1) {
                let stem = String(chars[0..<stemLen])
                guard let entry = exactMatch(surface: stem), entry.isNoun,
                      let particles = Self.particles(forStem: stem) else { continue }
                let stemJamo = String(HangulComposer.decomposeToJamo(stem))
                guard jamoPrefix.hasPrefix(stemJamo) else { continue }
                let tailJamo = String(jamoPrefix.dropFirst(stemJamo.count))
                guard !tailJamo.isEmpty else { continue }
                for p in particles {
                    let pJamo = String(HangulComposer.decomposeToJamo(p))
                    if pJamo.hasPrefix(tailJamo) {
                        let candidate = stem + p
                        if seen.insert(candidate).inserted {
                            results.append(candidate)
                            if results.count >= limit { return results }
                        }
                    }
                }
            }
        }
        return results
    }

    /// Whether `word` can be parsed as a known noun stem + valid Korean particle.
    /// Used by the error corrector to avoid flagging valid inflected nouns as typos.
    func isValidNounWithParticle(_ word: String) -> Bool {
        let chars = Array(word)
        guard chars.count >= 2 else { return false }
        for suffixLen in 1...min(2, chars.count - 1) {
            let stem = String(chars[0..<(chars.count - suffixLen)])
            let suffix = String(chars[(chars.count - suffixLen)...])
            guard let particles = Self.particles(forStem: stem), particles.contains(suffix),
                  let entry = exactMatch(surface: stem), entry.isNoun else { continue }
            return true
        }
        return false
    }

    private static func particles(forStem stem: String) -> [String]? {
        guard let batchim = HangulComposer.hasBatchim(stem) else { return nil }
        if !batchim { return particlesNoBatchim }
        if HangulComposer.hasRieulBatchim(stem) { return particlesRieulBatchim }
        return particlesWithBatchim
    }

    // MARK: - Low-level mmap helpers

    private func lowerBoundWord(raw: UnsafeRawBufferPointer, target: [UInt8]) -> Int {
        var low = 0
        var high = wordCount
        while low < high {
            let mid = (low + high) / 2
            if compareWordJamo(raw: raw, index: mid, to: target) < 0 {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// Binary search for the exclusive upper bound of words whose jamo starts with `prefix`.
    private func upperBoundPrefix(raw: UnsafeRawBufferPointer, from start: Int, prefix: [UInt8]) -> Int {
        var low = start
        var high = wordCount
        while low < high {
            let mid = (low + high) / 2
            if wordJamoHasPrefix(raw: raw, index: mid, prefix: prefix) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func compareWordJamo(raw: UnsafeRawBufferPointer, index: Int, to target: [UInt8]) -> Int {
        let recBase = wordsOffset + index * 16
        let jamoOff = Int(raw.loadUnaligned(fromByteOffset: recBase, as: UInt32.self).littleEndian)
        let jamoLen = Int(raw.loadUnaligned(fromByteOffset: recBase + 4, as: UInt16.self).littleEndian)
        let start = stringsOffset + jamoOff
        let minLen = min(jamoLen, target.count)
        for i in 0..<minLen {
            let a = raw[start + i]
            let b = target[i]
            if a != b { return a < b ? -1 : 1 }
        }
        if jamoLen == target.count { return 0 }
        return jamoLen < target.count ? -1 : 1
    }

    private func wordJamoHasPrefix(raw: UnsafeRawBufferPointer, index: Int, prefix: [UInt8]) -> Bool {
        let recBase = wordsOffset + index * 16
        let jamoOff = Int(raw.loadUnaligned(fromByteOffset: recBase, as: UInt32.self).littleEndian)
        let jamoLen = Int(raw.loadUnaligned(fromByteOffset: recBase + 4, as: UInt16.self).littleEndian)
        guard jamoLen >= prefix.count else { return false }
        let start = stringsOffset + jamoOff
        for i in 0..<prefix.count {
            if raw[start + i] != prefix[i] { return false }
        }
        return true
    }

    private func readWordEntry(raw: UnsafeRawBufferPointer, index: Int) -> Entry {
        let recBase = wordsOffset + index * 16
        let surfLen = Int(raw.loadUnaligned(fromByteOffset: recBase + 6, as: UInt16.self).littleEndian)
        let surfOff = Int(raw.loadUnaligned(fromByteOffset: recBase + 8, as: UInt32.self).littleEndian)
        let freq = raw.loadUnaligned(fromByteOffset: recBase + 12, as: UInt16.self).littleEndian
        let flags = raw[recBase + 14]
        let start = stringsOffset + surfOff
        let slice = UnsafeBufferPointer(
            start: raw.baseAddress?.advanced(by: start).assumingMemoryBound(to: UInt8.self),
            count: surfLen
        )
        let surface = String(decoding: slice, as: UTF8.self)
        return Entry(surface: surface, freq: freq, flags: flags)
    }

    static func hash(_ text: String) -> UInt64 {
        let bytes = Array(text.utf8)
        return SipHash24.hash(bytes[...], k0: hashKey.0, k1: hashKey.1)
    }
}
