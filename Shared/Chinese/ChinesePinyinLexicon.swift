import CRime
import Foundation

/// The readings of every single character in Vime's pinyin dictionary, read
/// from Rime's compiled table (`vime_pinyin.table.bin`), so generation spells
/// characters exactly as Rime's dictionary does.
///
/// A character can be typed as one of its syllables, as the first letter of
/// one, or as zh, ch or sh when the syllable begins with them.
nonisolated final class ChinesePinyinLexicon: @unchecked Sendable {
    /// Toneless syllables (lowercase a–z, ü written v) of each character.
    let readings: [Unicode.Scalar: Set<String>]
    /// What each character may be typed as, as ASCII bytes.
    private let spellings: [Unicode.Scalar: [[UInt8]]]
    /// The characters each spelling types.
    private let characters: [[UInt8]: [Unicode.Scalar]]
    /// Every distinct spelling, longest first.
    let inventory: [[UInt8]]

    init(readings: [Unicode.Scalar: Set<String>]) {
        self.readings = readings
        var spellings: [Unicode.Scalar: [[UInt8]]] = [:]
        var characters: [[UInt8]: [Unicode.Scalar]] = [:]
        for (character, syllables) in readings {
            var own = Set<[UInt8]>()
            for syllable in syllables {
                let bytes = Array(syllable.utf8)
                guard !bytes.isEmpty, bytes.allSatisfy({ (97...122).contains($0) }) else { continue }
                own.insert(bytes)
                own.insert([bytes[0]])
                if bytes.count > 2, [[122, 104], [99, 104], [115, 104]].contains(Array(bytes.prefix(2))) {
                    own.insert(Array(bytes.prefix(2)))
                }
            }
            let sorted = own.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1) }
            spellings[character] = sorted
            for spelling in sorted { characters[spelling, default: []].append(character) }
        }
        self.spellings = spellings
        self.characters = characters
        inventory = characters.keys.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1) }
    }

    /// Lines of "character<TAB>syllable", one per reading.
    convenience init?(lines: String) {
        var readings: [Unicode.Scalar: Set<String>] = [:]
        for line in lines.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, parts[0].unicodeScalars.count == 1, let scalar = parts[0].unicodeScalars.first
            else { continue }
            readings[scalar, default: []].insert(String(parts[1]))
        }
        guard !readings.isEmpty else { return nil }
        self.init(readings: readings)
    }

    /// Reads a compiled Rime table; nil when it cannot be read.
    convenience init?(table: URL) {
        guard let raw = vime_rime_character_readings(table.path) else { return nil }
        defer { vime_rime_string_free(raw) }
        self.init(lines: String(cString: raw))
    }

    /// The bundled pinyin dictionary, read once.
    static let bundled: ChinesePinyinLexicon? = RimeEngine.bundledData.flatMap {
        ChinesePinyinLexicon(table: $0.appendingPathComponent("vime_pinyin.table.bin"))
    }

    func contains(_ character: Unicode.Scalar) -> Bool { spellings[character] != nil }
    func spellings(of character: Unicode.Scalar) -> [[UInt8]] { spellings[character] ?? [] }
    func characters(spelled spelling: [UInt8]) -> [Unicode.Scalar] { characters[spelling] ?? [] }
}

/// The keys typed, as generation reads them: lowercase letters, with
/// apostrophes as syllable breaks no character may span.
nonisolated struct ChinesePinyinKeys: Equatable, Sendable {
    /// The letters, without apostrophes.
    let letters: [UInt8]
    /// `breaks[i]`: an apostrophe stood right before letter `i`.
    let breaks: [Bool]

    /// Nil for anything but ASCII letters and apostrophes, or no letters.
    init?(_ keys: String) {
        var letters: [UInt8] = [], breaks: [Bool] = []
        var pending = false
        for byte in keys.utf8 {
            switch byte {
            case 39: pending = true
            case 65...90, 97...122:
                letters.append(byte | 0x20); breaks.append(pending); pending = false
            default: return nil
            }
        }
        guard !letters.isEmpty else { return nil }
        self.letters = letters
        self.breaks = breaks
    }

    var count: Int { letters.count }

    /// Whether `spelling` can be typed from letter `start`.
    func matches(_ spelling: [UInt8], at start: Int) -> Bool {
        guard start + spelling.count <= letters.count else { return false }
        for offset in spelling.indices {
            if letters[start + offset] != spelling[offset] { return false }
            if offset > 0, breaks[start + offset] { return false }
        }
        return true
    }
}
