import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Local keyboard errors and bounded pairs of sound errors. These are sound
/// rules, never whole-word replacements; the engine verifies lexical evidence.
nonisolated enum KeyboardCorrectionVariants {
    struct Variant {
        let reading: String
        let suggestion: CorrectionSuggestion
    }
    static let maximumInputCount = 64
    static let maximumReadingCount = 40
    static let maximumVariants = 768
    static let maximumPhoneticPairs = 32 // Keep only the best dictionary-guided hypotheses.
    static let maximumSearchVariants = maximumVariants + maximumPhoneticPairs
    static let pairedSoundSurcharge = 0.5 // Two changes need stronger evidence than one.
    /// Paired sounds belong to one word; distant pairs in a long reading would
    /// multiply lookups without new candidates.
    static let maximumPairDistance = 7
    static let prolongedSoundCost = 0.8 // The optional ー key sits beside L.
    private static let soundGroups = ["かが", "きぎ", "くぐ", "けげ", "こご", "さざ", "しじ", "すず", "せぜ", "そぞ",
                                     "ただ", "ちぢじ", "つづず", "てで", "とど", "はばぱ", "ひびぴ", "ふぶぷ", "へべぺ", "ほぼぽ",
                                     "やゃ", "ゆゅ", "よょ", "つっ"]
    private static func soundCost(from: Character, to: Character) -> Double {
        from == "つ" && to == "ず" ? 0.75 : 1.0
    }

    static func generate(for query: ComposingText, cancelled: () -> Bool = { false }) -> [Variant] {
        let original = query.convertTarget
        let elements = query.input
        let originalInput = elements.compactMap { if case .character(let c) = $0.piece { return String(c) }; return nil }.joined()
        // A trailing Roman consonant is unfinished input, except a stray l from
        // the neighbouring ー key, which the l→ー edit below can repair.
        let pending = original.reversed().prefix { $0.isASCII }
        guard (2...maximumReadingCount).contains(original.count), elements.count <= maximumInputCount,
              pending.allSatisfy({ $0 == "l" }) else { return [] }
        var variants: [Variant] = []
        var seen: Set<String> = [original]
        func append(_ reading: String, roman: String?, kind: CorrectionKind, offset: Int, length: Int,
                    unit: CorrectionSuggestion.Unit, cost: Double) {
            guard variants.count < maximumVariants, !cancelled(),
                  reading.count >= 2, !reading.unicodeScalars.contains(where: { $0.isASCII }),
                  seen.insert(reading).inserted else { return }
            variants.append(.init(reading: reading, suggestion: .init(originalReading: original,
                suggestedReading: reading, correctedRomanInput: roman, kind: kind,
                rangeOffset: offset, rangeLength: length, rangeUnit: unit, errorCost: cost, originalInput: originalInput)))
        }
        var kana = Array(original)
        for i in kana.indices where original.count > 2 {
            guard !cancelled() else { return variants }
            let old = kana[i]
            for group in soundGroups where group.contains(old) {
                for next in group where next != old {
                    kana[i] = next
                    append(String(kana), roman: nil, kind: .phonetic, offset: i, length: 1,
                        unit: .kanaReading, cost: soundCost(from: old, to: next))
                }
            }
            kana[i] = old
        }
        // Roman edits touch letters only. Separators, ー and direct kana stay
        // in place because each edit is applied to the input elements.
        let indexed = elements.indices.compactMap { index -> (Int, Character)? in
            guard elements[index].inputStyle == .roman2kana, case .character(let c) = elements[index].piece,
                  c.isASCII && c.isLetter else { return nil }
            return (index, c)
        }
        guard indexed.count >= 4, !cancelled() else { return variants }
        let reader = LocalReader(elements: elements, reading: original)
        func letter(_ c: Character) -> ComposingText.InputElement { .init(character: c, inputStyle: .roman2kana) }
        func roman(_ range: Range<Int>, _ replacement: [ComposingText.InputElement], kind: CorrectionKind, length: Int, cost: Double) {
            guard variants.count < maximumVariants, !cancelled() else { return }
            guard let reading = reader.reading(replacing: range, with: replacement), !seen.contains(reading) else { return }
            var edited = elements; edited.replaceSubrange(range, with: replacement)
            let text = edited.compactMap { if case .character(let c) = $0.piece { return String(c) }; return nil }.joined()
            append(reading, roman: text, kind: kind, offset: range.lowerBound, length: length, unit: .romanInput, cost: cost)
        }
        // Each stray l is a ー; replace them all at once so コlヒl can become
        // コーヒー, then one at a time for a single slip.
        let strayL = indexed.filter { $0.1 == "l" }.map(\.0)
        if strayL.count > 1, let first = strayL.first, let last = strayL.last {
            let replacement = elements[first...last].map { element -> ComposingText.InputElement in
                element.piece == .character("l") && element.inputStyle == .roman2kana
                    ? .init(character: "ー", inputStyle: .roman2kana) : element
            }
            roman(first..<last + 1, replacement, kind: .neighboringKey, length: last - first + 1,
                  cost: prolongedSoundCost * Double(strayL.count))
        }
        // Repeated-letter deletion and adjacent transposition first.
        for (i, (index, c)) in indexed.enumerated() where original.count > 2 {
            guard !cancelled() else { return variants }
            let repeated = (i > 0 && indexed[i - 1].1 == c) || (i + 1 < indexed.count && indexed[i + 1].1 == c)
            roman(index..<index + 1, [], kind: .extraLetter, length: 1, cost: repeated ? 0.7 : 1.5)
            if i + 1 < indexed.count, indexed[i + 1].0 == index + 1, indexed[i + 1].1 != c {
                roman(index..<index + 2, [letter(indexed[i + 1].1), letter(c)], kind: .transposition, length: 2, cost: 1.05)
            }
        }
        func letter(at index: Int) -> Character? {
            guard elements.indices.contains(index), case .character(let c) = elements[index].piece else { return nil }
            return c
        }
        for (index, c) in indexed {
            guard !cancelled() else { return variants }
            if c == "l" {
                roman(index..<index + 1, [.init(character: "ー", inputStyle: .roman2kana)], kind: .neighboringKey,
                      length: 1, cost: prolongedSoundCost)
            }
            for (next, distance) in neighbors(of: c) where fits(next, after: letter(at: index - 1), before: letter(at: index + 1)) {
                guard !cancelled() else { return variants }
                let vowelPair = "aiueo".contains(c) && "aiueo".contains(next)
                roman(index..<index + 1, [letter(next)], kind: .neighboringKey, length: 1, cost: distance + (vowelPair ? -0.1 : 0.1))
            }
        }
        // A missing vowel often leaves an internal unresolved consonant. Try
        // vowels before consonants, rejecting variants that still cannot parse.
        let insertionPoints = indexed.map(\.0) + [indexed[indexed.count - 1].0 + 1]
        for next in "aiueokstnhmyrwgzdbpfvcjqlx" where original.count > 2 {
            for point in insertionPoints {
                guard !cancelled() else { return variants }
                guard fits(next, after: letter(at: point - 1), before: letter(at: point)) else { continue }
                roman(point..<point, [letter(next)], kind: .missingLetter, length: 0, cost: "aiueo".contains(next) ? 1.15 : 1.6)
            }
        }
        return variants
    }

    /// Cheap Roman syllable check before converting: a consonant needs a
    /// vowel, y, a digraph partner or its own double after it. Edits that
    /// fail this leave an unresolved letter and would be rejected anyway.
    /// After a consonant other than n, only y, the same letter or a digraph
    /// partner (sh, ch, ts, kw…) continues the syllable.
    static func fits(_ letter: Character, after previous: Character?, before following: Character?) -> Bool {
        if let previous, previous.isLetter, !"aiueon".contains(previous), !"aiueoy".contains(letter), letter != previous,
           !isDigraph(previous, letter) { return false }
        if "aiueon".contains(letter) { return true }
        guard let following else { return false }
        return "aiueoy".contains(following) || following == letter || isDigraph(letter, following)
    }

    private static func isDigraph(_ first: Character, _ second: Character) -> Bool {
        switch (first, second) {
        case ("s", "h"), ("c", "h"), ("t", "h"), ("d", "h"), ("w", "h"), ("t", "s"), ("k", "w"), ("g", "w"),
             ("x", "t"), ("l", "t"), ("x", "w"), ("l", "w"):
            return true
        default: return false
        }
    }

    /// Re-reads only the syllables an edit touches. The input is split once
    /// after each vowel (and after ー or other non-Roman elements); a Roman
    /// syllable is complete at its vowel, so the pieces convert independently.
    /// If they do not add up to the whole reading, the split is not trusted
    /// and every edit re-reads from the start.
    struct LocalReader {
        private let elements: [ComposingText.InputElement]
        private let reading: [Character]
        private var boundaries: [Int] = [0]
        private var offsets: [Int: Int] = [0: 0]

        init(elements: [ComposingText.InputElement], reading: String) {
            self.elements = elements; self.reading = Array(reading)
            var start = 0, offset = 0
            for end in 1...max(1, elements.count) where end == elements.count || Self.endsSyllable(elements[end - 1]) {
                let chunk = Self.convert(elements[start..<end])
                guard end == elements.count || Self.isKana(chunk),
                      self.reading.count >= offset + chunk.count,
                      self.reading[offset..<offset + chunk.count].elementsEqual(chunk) else { continue }
                offset += chunk.count
                boundaries.append(end); offsets[end] = offset
                start = end
            }
            if offset != self.reading.count {
                boundaries = [0, elements.count]; offsets = [0: 0, elements.count: self.reading.count]
            }
        }

        private static func endsSyllable(_ element: ComposingText.InputElement) -> Bool {
            guard element.inputStyle == .roman2kana, case .character(let c) = element.piece, c.isASCII, c.isLetter else {
                return true
            }
            return "aiueo".contains(c)
        }

        private static func isKana(_ value: String) -> Bool {
            !value.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        }

        private static func convert(_ elements: some Sequence<ComposingText.InputElement>) -> String {
            var text = ComposingText(); text.insertAtCursorPosition(Array(elements)); return text.convertTarget
        }

        /// The window ends at a syllable boundary after a vowel (or the end of
        /// input), so nothing in it can combine with the next syllable. Nil
        /// when two boundaries do not resolve the edit; such a reading would
        /// keep Roman letters and be rejected anyway.
        func reading(replacing range: Range<Int>, with replacement: [ComposingText.InputElement]) -> String? {
            let start = boundaries.last { $0 <= range.lowerBound } ?? 0
            var tries = 0
            for end in boundaries where end >= range.upperBound {
                let tail = elements[range.upperBound..<end]
                guard let last = tail.last ?? replacement.last ?? elements[start..<range.lowerBound].last else {
                    if end == elements.count || end > range.upperBound { continue }
                    return String(reading[..<offsets[start]!]) + String(reading[offsets[end]!...])
                }
                guard end == elements.count || Self.endsSyllable(last) else { continue }
                let window = Self.convert(elements[start..<range.lowerBound] + replacement + tail)
                if end == elements.count { return String(reading[..<offsets[start]!]) + window }
                if Self.isKana(window) {
                    return String(reading[..<offsets[start]!]) + window + String(reading[offsets[end]!...])
                }
                tries += 1
                if tries == 2 { return nil }
            }
            return nil
        }
    }

    /// Explore distinct original positions, retaining a small beam by lexical
    /// priority. The intermediate one-edit reading need not be a dictionary word.
    /// No Roman reconstruction: separators and literal characters stay intact.
    static func phoneticPairs(for query: ComposingText, priority: (Variant) -> Double,
                              cancelled: () -> Bool = { false }) -> [Variant] {
        let original = query.convertTarget
        guard (3...maximumReadingCount).contains(original.count), query.input.count <= maximumInputCount,
              original.last?.isASCII == false, !cancelled() else { return [] }
        let input = query.input.compactMap { if case .character(let c) = $0.piece { return String(c) }; return nil }.joined()
        let kana = Array(original)
        let positions = kana.indices.compactMap { index -> (Int, [Character])? in
            let replacements = soundGroups.filter { $0.contains(kana[index]) }
                .flatMap { $0.filter { $0 != kana[index] } }
            return replacements.isEmpty ? nil : (index, replacements)
        }
        guard positions.count > 1 else { return [] }
        var beam: [(Variant, Double)] = []
        for first in 0..<(positions.count - 1) {
            for second in (first + 1)..<positions.count {
                let (i, left) = positions[first], (j, right) = positions[second]
                if j - i > maximumPairDistance { break }
                for a in left {
                    for b in right {
                        if cancelled() { return beam.map(\.0) }
                        var changed = kana; changed[i] = a; changed[j] = b
                        let reading = String(changed)
                        guard !reading.unicodeScalars.contains(where: { $0.isASCII }) else { continue }
                        var suggestion = CorrectionSuggestion(originalReading: original, suggestedReading: reading,
                            correctedRomanInput: nil, kind: .phonetic, rangeOffset: i, rangeLength: j - i + 1,
                            rangeUnit: .kanaReading,
                            errorCost: soundCost(from: kana[i], to: a) + soundCost(from: kana[j], to: b) + pairedSoundSurcharge,
                            originalInput: input, method: "phoneticPair")
                        suggestion.soundEdits = [.init(offset: i, original: String(kana[i]), replacement: String(a)),
                                                 .init(offset: j, original: String(kana[j]), replacement: String(b))]
                        let variant = Variant(reading: reading, suggestion: suggestion)
                        let score = priority(variant)
                        let index = beam.firstIndex { score < $0.1 || (score == $0.1 && reading < $0.0.reading) } ?? beam.count
                        if index < maximumPhoneticPairs {
                            beam.insert((variant, score), at: index)
                            if beam.count > maximumPhoneticPairs { beam.removeLast() }
                        }
                    }
                }
            }
        }
        return beam.map(\.0)
    }

    private static let positions: [Character: (Double, Double)] = {
        var values: [Character: (Double, Double)] = [:]
        for (row, text, inset) in [(0, "qwertyuiop", 0.0), (1, "asdfghjkl", 0.5), (2, "zxcvbnm", 1.4)] {
            for (column, letter) in text.enumerated() { values[letter] = (Double(column) + inset, Double(row)) }
        }
        return values
    }()
    private static func neighbors(of letter: Character) -> [(Character, Double)] {
        guard let origin = positions[letter] else { return [] }
        return positions.compactMap { key, point -> (Character, Double)? in
            let distance = hypot(point.0 - origin.0, point.1 - origin.1)
            return distance > 0 && distance <= 1.25 ? (key, distance) : nil
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
    }
}
