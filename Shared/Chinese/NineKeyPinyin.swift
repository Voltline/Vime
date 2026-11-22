/// Pinyin on the nine-key pad, where 2–9 each stand for three or four letters
/// (vime_t9). Rime's preedit shows the digits, so the reading shown comes from
/// the lead candidate's spelling hint; syllables picked from the bar stand in
/// the input as letters followed by a break.
nonisolated enum NineKeyPinyin {
    /// The digit for each letter; ü goes on v's key.
    static func digit(for letter: Character) -> Character? {
        switch letter {
        case "a", "b", "c": "2"
        case "d", "e", "f": "3"
        case "g", "h", "i": "4"
        case "j", "k", "l": "5"
        case "m", "n", "o": "6"
        case "p", "q", "r", "s": "7"
        case "t", "u", "v", "ü": "8"
        case "w", "x", "y", "z": "9"
        default: nil
        }
    }

    static func digits(for letters: String) -> String {
        String(letters.lowercased().compactMap(digit(for:)))
    }

    static func isDigit(_ character: Character) -> Bool { ("2"..."9").contains(character) }

    /// The open input's pieces: syllables picked as letters, then digits.
    /// A picked syllable ends at a break; digits run to a break or the end.
    static func segments(_ input: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            segments.append(current.allSatisfy(isDigit) ? .digits(current) : .letters(current))
            current = ""
        }
        for character in input {
            if character == "'" || character == " " { flush(); continue }
            // Letters after digits (or digits after letters) start a new piece.
            if let last = current.last, isDigit(last) != isDigit(character) { flush() }
            current.append(character)
        }
        flush()
        return segments
    }

    enum Segment: Equatable {
        case letters(String)
        case digits(String)
    }

    /// The reading the open input shows: picked syllables as they are, the
    /// digits spelled by `hint` (the lead candidate's pinyin, syllables
    /// spaced) as far as it matches them, a syllable's start where the input
    /// has only that much of it, and the digits no syllable matched as typed.
    static func reading(of input: String, hint: String?) -> [String] {
        var syllables = (hint ?? "").split(separator: " ").map { String($0).lowercased() }[...]
        var result: [String] = []
        for segment in segments(input) {
            switch segment {
            case .letters(let letters):
                result.append(letters)
                // The hint spells picked syllables too.
                if syllables.first == letters { syllables.removeFirst() }
            case .digits(let digits):
                let lengths = split(Array(digits), among: Array(syllables))
                for (syllable, length) in zip(syllables, lengths) { result.append(String(syllable.prefix(length))) }
                syllables.removeFirst(lengths.count)
                let matched = lengths.reduce(0, +)
                if matched < digits.count {
                    result.append(String(digits.dropFirst(matched)))
                    syllables = []
                }
            }
        }
        return result
    }

    /// How many digits each of the first syllables takes, each at least one
    /// and no more than it spells: as many syllables as can match, then as
    /// many digits (94 for zhong guo is z g, not zh).
    private static func split(_ digits: [Character], among syllables: [String]) -> [Int] {
        let spelled = syllables.map { Array(Self.digits(for: $0)) }
        var memo: [Int: (syllables: Int, digits: Int, lengths: [Int])] = [:]
        func best(_ index: Int, _ position: Int) -> (syllables: Int, digits: Int, lengths: [Int]) {
            guard index < spelled.count, position < digits.count else { return (0, 0, []) }
            let key = index * (digits.count + 1) + position
            if let known = memo[key] { return known }
            var found: (syllables: Int, digits: Int, lengths: [Int]) = (0, 0, [])
            let common = zip(spelled[index], digits[position...]).prefix { $0 == $1 }.count
            for length in stride(from: common, through: 1, by: -1) {
                let rest = best(index + 1, position + length)
                let option = (rest.syllables + 1, rest.digits + length, [length] + rest.lengths)
                if option.0 > found.syllables || (option.0 == found.syllables && option.1 > found.digits) { found = option }
            }
            memo[key] = found
            return found
        }
        return best(0, 0).lengths
    }

    /// The pinyin `input` commits as letters (Return): its reading with the
    /// syllables run together, digits no syllable matched as typed.
    static func letters(of input: String, hint: String?) -> String {
        reading(of: input, hint: hint).joined()
    }

    /// The first run of digits in `input`, after the syllables already picked.
    static func openDigits(_ input: String) -> String? {
        for segment in segments(input) { if case .digits(let digits) = segment { return digits } }
        return nil
    }

    /// The syllables the digits can start with: whole syllables, longest
    /// first, then the initials of the first key for an abbreviation;
    /// `natural` (Rime's own reading) leads.
    static func options(for digits: String, preferring natural: String? = nil) -> [String] {
        let digits = Array(digits)
        guard !digits.isEmpty, digits.allSatisfy(isDigit) else { return [] }
        var found: [String] = []
        for length in (1...min(PinyinLeadingSyllable.longest, digits.count)).reversed() {
            let prefix = String(digits[..<length])
            let matching = syllables(spelledBy: prefix)
            found.append(contentsOf: matching)
        }
        for initial in initials(on: digits[0]) where !found.contains(initial) { found.append(initial) }
        if let natural, let index = found.firstIndex(of: natural), index > 0 {
            found.remove(at: index)
            found.insert(natural, at: 0)
        }
        return found
    }

    /// `input` with its first run of digits starting with `syllable` as
    /// letters and a break after it; the digits after that stay.
    static func input(_ input: String, picking syllable: String) -> String? {
        let segments = segments(input)
        guard let index = segments.firstIndex(where: { if case .digits = $0 { true } else { false } }),
              case .digits(let digits) = segments[index] else { return nil }
        let spelled = Self.digits(for: syllable)
        guard digits.hasPrefix(spelled) else { return nil }
        var pieces: [String] = segments[..<index].map {
            switch $0 { case .letters(let text), .digits(let text): text }
        }
        pieces.append(syllable)
        let rest = String(digits.dropFirst(spelled.count))
        if !rest.isEmpty { pieces.append(rest) }
        pieces += segments[(index + 1)...].map {
            switch $0 { case .letters(let text), .digits(let text): text }
        }
        // A trailing break keeps a picked syllable picked while nothing follows.
        return pieces.joined(separator: "'") + (rest.isEmpty && index == segments.count - 1 ? "'" : "")
    }

    /// `input` with its last picked syllable typed again as digits, when
    /// nothing but breaks follows it; nil otherwise.
    static func unpickingLast(_ input: String) -> String? {
        var trimmed = Substring(input)
        while trimmed.last == "'" { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last, !isDigit(last), case .letters(let letters)? = segments(input).last else { return nil }
        return String(trimmed.dropLast(letters.count)) + digits(for: letters)
    }

    // MARK: Tables

    /// Whole syllables by the digits that spell them.
    private static let byDigits: [String: [String]] = {
        var table: [String: [String]] = [:]
        for syllable in PinyinSpellingCorrection.syllables.sorted()
        where syllable.contains(where: { "aeiouv".contains($0) }) {
            table[digits(for: syllable), default: []].append(syllable)
        }
        return table
    }()

    private static func syllables(spelledBy digits: String) -> [String] {
        (byDigits[digits] ?? []).sorted { rank($0) < rank($1) || (rank($0) == rank($1) && $0 < $1) }
    }

    /// Common syllables first among those one key sequence spells.
    private static func rank(_ syllable: String) -> Int {
        common.firstIndex(of: syllable) ?? common.count
    }

    /// The syllables most text uses, so they lead their key sequence.
    private static let common = ["de", "shi", "yi", "bu", "le", "zai", "ren", "you", "wo", "ta", "zhe", "ge", "men",
                                 "zhong", "lai", "shang", "da", "wei", "he", "guo", "di", "dao", "yao", "jiu", "chu",
                                 "dui", "sheng", "hui", "ke", "ni", "na", "hao", "mei", "xiang", "ji", "qi", "xin",
                                 "zi", "ye", "jin", "ri", "ba", "ma", "pa", "fa", "gong", "kan", "jia", "zuo", "nian"]

    /// Initials that may start an abbreviation on a key: not i, u or ü.
    private static func initials(on key: Character) -> [String] {
        "bpmfdtnlgkhjqxrzcsyw".filter { digit(for: $0) == key }.map(String.init)
    }
}
