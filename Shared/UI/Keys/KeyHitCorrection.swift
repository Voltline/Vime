import CoreGraphics
import Foundation

/// Moves a letter tap that lands near the edge of a key to its neighbour when
/// the touched letter cannot continue the input and the neighbour can (kyp →
/// kyo, zhanf stays). Only implausible letters are ever replaced, and only by
/// a key whose painted body the touch nearly reached.
nonisolated enum KeyHitCorrection {
    /// How plausible a letter is next, from 0 (impossible) to 1 (as likely as
    /// the best letter).
    typealias Prior = (Character) -> Double

    struct Key {
        let letter: Character
        let body: CGRect
    }

    /// The touched letter is replaced only below this plausibility.
    static let implausible = 0.15
    /// A replacement must be fully plausible.
    static let plausible = 0.9
    /// How far outside a neighbour's body a touch may land, in key widths and
    /// heights. Keys are about five times as wide as the gap between them, so
    /// this reaches roughly the outer fifth of the touched key.
    static let reach = CGSize(width: 0.45, height: 0.35)
    /// Each initial typed as an abbreviation (wm for 微卖) makes a pinyin
    /// reading this much less likely than spelling the syllable out.
    static let abbreviationWeight = 0.05

    /// The neighbouring letter this touch should type instead, or nil.
    static func replacement(at point: CGPoint, touched: Key, neighbours: [Key], prior: () -> Prior?) -> Character? {
        let near = neighbours
            .filter { $0.letter != touched.letter }
            .compactMap { key in distance(from: point, to: key.body).map { (key.letter, $0) } }
            .sorted { $0.1 < $1.1 }
        guard !near.isEmpty, let prior = prior(), prior(touched.letter) < implausible else { return nil }
        return near.first { prior($0.0) >= plausible }?.0
    }

    /// Normalized distance from a key's body, or nil when out of reach.
    static func distance(from point: CGPoint, to body: CGRect) -> Double? {
        guard body.width > 0, body.height > 0 else { return nil }
        let dx = max(0, abs(point.x - body.midX) - body.width / 2) / body.width / reach.width
        let dy = max(0, abs(point.y - body.midY) - body.height / 2) / body.height / reach.height
        let value = Double(dx * dx + dy * dy)
        return value <= 1 ? value : nil
    }

    // MARK: - Romaji

    /// Romaji spellings roman2kana accepts, with the small kana forms.
    static let romajiSyllables: Set<String> = {
        var set = Set("a i u e o nn n' ya yu yo ye yi wa wi wu we wo wyi wye wha whi whu whe who".split(separator: " ").map(String.init))
        for c in "kgsztdnhbpmrfvjqclx" {
            for v in "aiueo" { set.insert("\(c)\(v)"); set.insert("\(c)y\(v)") }
        }
        for head in ["sh", "ch", "ts", "th", "dh", "wh", "kw", "gw", "tw", "dw", "fw", "qw", "sw", "zw", "lw", "xw", "cy"] {
            for v in "aiueo" { set.insert(head + String(v)) }
        }
        for small in ["tu", "tsu", "ka", "ke", "ya", "yu", "yo", "wa", "n"] { set.insert("l" + small); set.insert("x" + small) }
        return set
    }()

    static let romajiPrefixes: Set<String> = prefixes(of: romajiSyllables)

    /// Letters that can continue romaji input, from what has been typed.
    /// nil when the input is not romaji (capitals, English words).
    static func romajiPrior(after raw: String) -> Prior? {
        let letters = Array(raw)
        guard letters.allSatisfy({ !$0.isLetter || ("a"..."z").contains($0) }) else { return nil }
        // reachable[i]: the input before i splits into whole kana.
        var reachable = Array(repeating: false, count: letters.count + 1)
        reachable[0] = true
        for i in letters.indices where reachable[i] {
            let c = letters[i]
            if !c.isLetter { reachable[i + 1] = true; continue }
            for length in 1...4 where i + length <= letters.count {
                if romajiSyllables.contains(String(letters[i..<i + length])) { reachable[i + length] = true }
            }
            let next = i + 1 < letters.count ? letters[i + 1] : nil
            // っ before a doubled consonant, ん before another consonant.
            if let next, next == c, !"aiueon".contains(c) { reachable[i + 1] = true }
            if c == "n", let next, !"aiueoyn'".contains(next) { reachable[i + 1] = true }
        }
        var tails: [String] = []
        for start in reachable.indices where reachable[start] {
            let tail = String(letters[start...])
            if tail.isEmpty || romajiPrefixes.contains(tail) { tails.append(tail) }
        }
        guard !tails.isEmpty else { return nil }
        return { letter in
            tails.contains { tail in
                romajiPrefixes.contains(tail + String(letter))
                    || (tail.count == 1 && tail.first == letter && !"aiueon".contains(letter))
                    || (tail == "n" && !"aiueoy".contains(letter))
            } ? 1 : 0
        }
    }

    // MARK: - Pinyin

    static let pinyinPrefixes: Set<String> = prefixes(of: PinyinSpellingCorrection.syllables)

    /// Letters that can continue pinyin input. Initials typed as abbreviations
    /// (wm for 微卖) are allowed but count against a reading.
    static func pinyinPrior(after raw: String) -> Prior? {
        let letters = Array(raw)
        guard letters.allSatisfy({ $0 == "'" || ("a"..."z").contains($0) }) else { return nil }
        // cost[i]: fewest abbreviations that split the input before i.
        var cost: [Int?] = Array(repeating: nil, count: letters.count + 1)
        cost[0] = 0
        func reach(_ index: Int, _ value: Int) { if cost[index].map({ value < $0 }) ?? true { cost[index] = value } }
        for i in letters.indices {
            guard let base = cost[i] else { continue }
            if letters[i] == "'" { reach(i + 1, base); continue }
            for length in 1...6 where i + length <= letters.count {
                let piece = String(letters[i..<i + length])
                if PinyinSpellingCorrection.syllables.contains(piece) { reach(i + length, base) }
                else if PinyinSpellingCorrection.abbreviations.contains(piece) { reach(i + length, base + 1) }
            }
        }
        var tails: [(String, Int)] = []
        for start in cost.indices {
            guard let value = cost[start] else { continue }
            let tail = String(letters[start...])
            if tail.isEmpty || pinyinPrefixes.contains(tail) { tails.append((tail, value)) }
        }
        guard let best = tails.map(\.1).min() else { return nil }
        return { letter in
            let fewest = tails.filter { pinyinPrefixes.contains($0.0 + String(letter)) }.map(\.1).min()
            return fewest.map { pow(abbreviationWeight, Double($0 - best)) } ?? 0
        }
    }

    private static func prefixes(of words: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for word in words { for end in word.indices { result.insert(String(word[...end])) } }
        return result
    }
}
