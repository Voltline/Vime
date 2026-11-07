import Foundation

/// Finds Japanese kanji words by their Mandarin reading (中日混输).
///
/// Every character of a word is matched by one of its pinyin syllables or by a
/// romaji spelling of its own kana segment, so jiancha (pinyin), jiansatsu
/// (pinyin + romaji) and kencha (romaji + pinyin) all find 検察 (けん|さつ). The
/// last character may be incomplete (jianch). A word typed entirely in romaji
/// is ordinary Japanese input and is never returned.
///
/// The data is PinyinKanjiLookup.bin, built by Scripts/build_pinyin_kanji_lookup.py.
/// It is memory-mapped and read in place: a query touches only the trie nodes
/// it visits, so the keyboard extension never holds the whole table.
///
/// Layout (little-endian): "VPK1", version 2, section count, then (offset, length)
/// per section. Node k > 0 is the target of edge k - 1 (breadth-first order),
/// and node n's edges are edgeStart[n] ..< edgeStart[n + 1]. Root edges are
/// bucketed by the first two letters of their spellings (26 × 27; index 26 of
/// the second letter holds one-letter spellings such as a and o).
nonisolated final class PinyinKanjiLookup: @unchecked Sendable {
    /// How one character of a word was typed.
    enum Mode: Equatable, Sendable {
        /// One of the character's Mandarin syllables.
        case pinyin
        /// A romaji spelling of the character's kana reading.
        case romaji
        /// A kana character inside the word (okurigana), typed in romaji.
        case kana
    }

    struct Part: Equatable, Sendable {
        let character: String
        /// The letters this character consumed.
        let letters: String
        let mode: Mode
    }

    struct Match: Equatable, Sendable {
        let surface: String
        /// The word's whole reading in hiragana.
        let reading: String
        let parts: [Part]
        /// The last character's syllable was incomplete (jianch → 検察).
        let partial: Bool
        /// Changes between pinyin and romaji from one kanji to the next.
        let switches: Int
        /// Mozc word cost (lower is more common), with the proper-noun penalty
        /// applied by the generator, plus `historicalReadingPenalty` for each
        /// character matched only by a historical (kHanyuPinyin) syllable.
        let cost: Int
        let properNoun: Bool
        var usesRomaji: Bool { parts.contains { $0.mode == .romaji } }
        /// Which characters used pinyin, e.g. 検[jian]察[satu] → "検·察" with
        /// pinyin on 検 only; for diagnostics and tests.
        var matchDescription: String {
            parts.map { "\($0.character)[\($0.letters)\($0.mode == .pinyin ? "" : $0.mode == .romaji ? ":ja" : ":kana")]" }.joined()
        }

        /// The order within one tier: complete before partial last syllable,
        /// then fewer pinyin/romaji switches, then lower word cost, then the
        /// surface for a stable order.
        static func ranks(_ a: Match, before b: Match) -> Bool {
            if a.partial != b.partial { return !a.partial }
            if a.switches != b.switches { return a.switches < b.switches }
            if a.cost != b.cost { return a.cost < b.cost }
            return a.surface < b.surface
        }
    }

    static let historicalReadingPenalty = 1500
    private static let formatVersion: UInt32 = 2
    private static let bucketCount = 26 * 27
    /// Longer input is not a word; letting it through only costs time.
    static let maximumInputLength = 32
    private static let noSegment: UInt16 = 0xFFFF
    private static let notTerminal: UInt16 = 0xFFFF
    private static let secondary: UInt16 = 0x8000

    private static let loadLock = NSLock()
    nonisolated(unsafe) private static var loaded: PinyinKanjiLookup??
    /// The bundled table, mapped on first use. nil when the resource is missing.
    static var shared: PinyinKanjiLookup? {
        loadLock.lock(); defer { loadLock.unlock() }
        if let loaded { return loaded }
        let value = Bundle.main.url(forResource: "PinyinKanjiLookup", withExtension: "bin").flatMap(PinyinKanjiLookup.init(url:))
        loaded = .some(value)
        return value
    }

    private struct Section { let offset: Int; let count: Int }
    private let data: Data
    private let spellings: Section, spellingText: Section, characters: Section, segments: Section
    private let idList: Section, edgeStart: Section, nodeCost: Section, nodeFlags: Section, edges: Section
    private let bucketOffsets: Section, bucketEdges: Section, readings: Section, text: Section
    let nodeCount: Int
    var byteCount: Int { data.count }

    convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard data.count >= 12, data.prefix(4).elementsEqual("VPK1".utf8) else { return nil }
        let sections: [(Int, Int)]? = data.withUnsafeBytes { bytes in
            guard bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian == Self.formatVersion else { return nil }
            let count = Int(bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian)
            guard count == 13, data.count >= 12 + count * 8 else { return nil }
            var result: [(Int, Int)] = []
            for index in 0..<count {
                let offset = Int(bytes.loadUnaligned(fromByteOffset: 12 + index * 8, as: UInt32.self).littleEndian)
                let length = Int(bytes.loadUnaligned(fromByteOffset: 16 + index * 8, as: UInt32.self).littleEndian)
                guard offset % 4 == 0, offset + length <= data.count else { return nil }
                result.append((offset, length))
            }
            return result
        }
        guard let sections else { return nil }
        // Element sizes, in section order.
        let sizes = [4, 1, 8, 8, 2, 4, 2, 1, 4, 4, 4, 8, 1]
        guard zip(sections, sizes).allSatisfy({ $0.0.1 % $0.1 == 0 }) else { return nil }
        let s = zip(sections, sizes).map { Section(offset: $0.0.0, count: $0.0.1 / $0.1) }
        self.data = data
        (spellings, spellingText, characters, segments) = (s[0], s[1], s[2], s[3])
        (idList, edgeStart, nodeCost, nodeFlags, edges) = (s[4], s[5], s[6], s[7], s[8])
        (bucketOffsets, bucketEdges, readings, text) = (s[9], s[10], s[11], s[12])
        nodeCount = nodeCost.count
        guard nodeCount > 0, edgeStart.count == nodeCount + 1, nodeFlags.count == nodeCount,
              edges.count == nodeCount - 1, bucketOffsets.count == Self.bucketCount + 1 else { return nil }
    }

    /// Words whose characters spell `input`, best first by `Match.ranks`.
    /// `input` is the raw typed letters; ü may be typed as v (or ü).
    func matches(for input: String, limit: Int = 24) -> [Match] {
        var letters: [UInt8] = []
        letters.reserveCapacity(input.utf8.count)
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A: letters.append(UInt8(scalar.value))
            case 0x41...0x5A: letters.append(UInt8(scalar.value + 0x20))
            case 0xFC, 0xDC: letters.append(UInt8(ascii: "v"))
            default: return []
            }
        }
        guard letters.count >= 2, letters.count <= Self.maximumInputLength else { return [] }
        return data.withUnsafeBytes { bytes in
            var search = Search(lookup: self, bytes: bytes, input: letters)
            search.run()
            return search.results(limit: limit)
        }
    }

    // MARK: Search

    private struct Search {
        let lookup: PinyinKanjiLookup
        let bytes: UnsafeRawBufferPointer
        let input: [UInt8]
        // The path being explored, one entry per character.
        var characterIDs: [Int] = []
        var segmentIDs: [UInt16] = []
        var modes: [Mode] = []
        var ends: [Int] = []
        var historical = 0
        var best: [String: Match] = [:]
        /// Surfaces reachable by romaji alone: plain Japanese input.
        var romajiOnly: Set<String> = []
        /// Bounds pathological input; real queries visit a few hundred edges.
        var budget = 200_000

        init(lookup: PinyinKanjiLookup, bytes: UnsafeRawBufferPointer, input: [UInt8]) {
            self.lookup = lookup; self.bytes = bytes; self.input = input
        }

        func u32(_ section: Section, _ index: Int) -> Int {
            Int(bytes.loadUnaligned(fromByteOffset: section.offset + index * 4, as: UInt32.self).littleEndian)
        }
        func u16(_ section: Section, _ index: Int) -> UInt16 {
            bytes.loadUnaligned(fromByteOffset: section.offset + index * 2, as: UInt16.self).littleEndian
        }

        mutating func run() {
            // The first character's spelling either starts with the first two
            // letters or is one letter long. An edge in both buckets (亜: a, ya)
            // is visited once per bucket; `best` keeps one match per surface.
            let first = (Int(input[0]) - 0x61) * 27
            for bucket in [first + Int(input[1]) - 0x61, first + 26] {
                let start = u32(lookup.bucketOffsets, bucket), end = u32(lookup.bucketOffsets, bucket + 1)
                for index in start..<end { visit(edge: u32(lookup.bucketEdges, index), at: 0) }
            }
        }

        /// Tries every way edge `edge` (one character) can start at `position`.
        mutating func visit(edge: Int, at position: Int) {
            guard budget > 0 else { return }
            budget -= 1
            let packed = u32(lookup.edges, edge)
            let character = packed & 0xFFFF
            let segment = UInt16(packed >> 16)
            let characterList = u32(lookup.characters, character * 2 + 1)
            for index in (characterList & 0xFFFFFF)..<((characterList & 0xFFFFFF) + (characterList >> 24)) {
                let value = u16(lookup.idList, index)
                attempt(spelling: Int(value & ~PinyinKanjiLookup.secondary), edge: edge, character: character,
                    segment: segment, mode: .pinyin, historical: value & PinyinKanjiLookup.secondary != 0, at: position)
            }
            guard segment != PinyinKanjiLookup.noSegment else { return }
            let mode: Mode = characterList >> 24 == 0 && isKana(character) ? .kana : .romaji
            let segmentList = u32(lookup.segments, Int(segment) * 2 + 1)
            for index in (segmentList & 0xFFFFFF)..<((segmentList & 0xFFFFFF) + (segmentList >> 24)) {
                attempt(spelling: Int(u16(lookup.idList, index)), edge: edge, character: character,
                    segment: segment, mode: mode, historical: false, at: position)
            }
        }

        func isKana(_ character: Int) -> Bool {
            let scalar = u32(lookup.characters, character * 2)
            return (0x3041...0x3096).contains(scalar) || (0x30A1...0x30FA).contains(scalar)
        }

        mutating func attempt(spelling: Int, edge: Int, character: Int, segment: UInt16, mode: Mode,
                            historical: Bool, at position: Int) {
            let packed = u32(lookup.spellings, spelling)
            let offset = lookup.spellingText.offset + (packed & 0xFFFFFF), length = packed >> 24
            let remaining = input.count - position
            guard length > 0, bytes[offset] == input[position] else { return }
            let compared = min(length, remaining)
            for index in 1..<max(1, compared) where bytes[offset + index] != input[position + index] { return }
            let node = edge + 1
            let partial = length > remaining
            let end = partial ? input.count : position + length
            characterIDs.append(character); segmentIDs.append(segment); modes.append(mode); ends.append(end)
            if historical { self.historical += 1 }
            defer {
                characterIDs.removeLast(); segmentIDs.removeLast(); modes.removeLast(); ends.removeLast()
                if historical { self.historical -= 1 }
            }
            if end == input.count {
                emit(node: node, partial: partial)
            } else {
                let first = u32(lookup.edgeStart, node), last = u32(lookup.edgeStart, node + 1)
                for child in first..<last { visit(edge: child, at: end) }
            }
        }

        mutating func emit(node: Int, partial: Bool) {
            let cost = u16(lookup.nodeCost, node)
            guard cost != PinyinKanjiLookup.notTerminal else { return }
            // A single kanji is too short a word to guess from a fragment.
            if partial && characterIDs.count == 1 { return }
            let pinyin = modes.contains(.pinyin)
            let surface = String(String.UnicodeScalarView(characterIDs.compactMap {
                UnicodeScalar(UInt32(u32(lookup.characters, $0 * 2)))
            }))
            guard pinyin else { romajiOnly.insert(surface); return }
            // Kana inside the word are typed in romaji, so pinyin → okurigana
            // is a switch too: 勝利 (sheng|ri) and 乗り (sheng|ri) tie on it.
            var switches = 0
            var last: Bool?
            for mode in modes {
                let pinyin = mode == .pinyin
                if let last, last != pinyin { switches += 1 }
                last = pinyin
            }
            let total = Int(cost) + historical * PinyinKanjiLookup.historicalReadingPenalty
            if let existing = best[surface], !Self.better(partial: partial, switches: switches, cost: total, than: existing) { return }
            var parts: [Part] = []
            var start = 0
            for (index, id) in characterIDs.enumerated() {
                let scalar = UnicodeScalar(UInt32(u32(lookup.characters, id * 2))).map { String(Character($0)) } ?? ""
                parts.append(Part(character: scalar, letters: String(decoding: input[start..<ends[index]], as: UTF8.self), mode: modes[index]))
                start = ends[index]
            }
            let flags = bytes[lookup.nodeFlags.offset + node]
            best[surface] = Match(surface: surface, reading: reading(node: node), parts: parts, partial: partial,
                                  switches: switches, cost: total, properNoun: flags & 1 != 0)
        }

        static func better(partial: Bool, switches: Int, cost: Int, than match: Match) -> Bool {
            if partial != match.partial { return !partial }
            if switches != match.switches { return switches < match.switches }
            return cost < match.cost
        }

        func string(_ packed: Int) -> String {
            let offset = lookup.text.offset + (packed & 0xFFFFFF)
            return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + (packed >> 24))]), as: UTF8.self)
        }

        /// Aligned words spell their reading with their segments; the others
        /// (jukujikun such as 大人) keep it in a table keyed by node.
        func reading(node: Int) -> String {
            if !segmentIDs.contains(PinyinKanjiLookup.noSegment) {
                return segmentIDs.map { string(u32(lookup.segments, Int($0) * 2)) }.joined()
            }
            var lower = 0, upper = lookup.readings.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if u32(lookup.readings, middle * 2) < node { lower = middle + 1 } else { upper = middle }
            }
            guard lower < lookup.readings.count, u32(lookup.readings, lower * 2) == node else { return "" }
            return string(u32(lookup.readings, lower * 2 + 1))
        }

        func results(limit: Int) -> [Match] {
            let values = best.values.filter { !romajiOnly.contains($0.surface) }
            return Array(values.sorted(by: Match.ranks).prefix(limit))
        }
    }
}
