import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Local keyboard errors and bounded pairs of sound errors. These are sound
/// rules, never whole-word replacements; the engine verifies lexical evidence.
nonisolated enum KeyboardCorrectionVariants {
    struct Variant {
        let reading: String
        let suggestion: CorrectionSuggestion
    }
    static let maximumInputCount = 40
    static let maximumVariants = 384
    static let maximumPhoneticPairs = 32 // Keep only the best dictionary-guided hypotheses.
    static let maximumSearchVariants = maximumVariants + maximumPhoneticPairs
    static let pairedSoundSurcharge = 0.5 // Two changes need stronger evidence than one.
    private static let soundGroups = ["かが", "きぎ", "くぐ", "けげ", "こご", "さざ", "しじ", "すず", "せぜ", "そぞ",
                                     "ただ", "ちぢじ", "つづず", "てで", "とど", "はばぱ", "ひびぴ", "ふぶぷ", "へべぺ", "ほぼぽ",
                                     "やゃ", "ゆゅ", "よょ", "つっ"]
    private static func soundCost(from: Character, to: Character) -> Double {
        from == "つ" && to == "ず" ? 0.75 : 1.0
    }

    static func generate(for query: ComposingText, cancelled: () -> Bool = { false }) -> [Variant] {
        let original = query.convertTarget
        let originalInput = query.input.compactMap { if case .character(let c) = $0.piece { return String(c) }; return nil }.joined()
        guard (3...24).contains(original.count), query.input.count <= maximumInputCount,
              let last = original.last, !last.isASCII else { return [] }
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
        for i in kana.indices {
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
        let indexed = query.input.enumerated().compactMap { index, element -> (Int, Character)? in
            guard element.inputStyle == .roman2kana, case .character(let c) = element.piece,
                  c.isASCII && c.isLetter else { return nil }
            return (index, c)
        }
        // Direct kana and mixed literal input can use sound rules, but must not
        // silently lose separators/symbols through a reconstructed Roman query.
        guard indexed.count == query.input.filter({ if case .compositionSeparator = $0.piece { return false }; return true }).count,
              indexed.count >= 4 else { return variants }
        let raw = indexed.map(\.1)
        func roman(_ value: [Character], kind: CorrectionKind, index: Int, length: Int, cost: Double) {
            guard variants.count < maximumVariants, !cancelled() else { return }
            var composition = ComposingText()
            let text = String(value)
            RomajiConverter.insert(text, into: &composition)
            append(composition.convertTarget, roman: text, kind: kind,
                offset: index < indexed.count ? indexed[index].0 : query.input.count,
                length: length, unit: .romanInput, cost: cost)
        }
        // Repeated-letter deletion and adjacent transposition first.
        for i in raw.indices {
            var value = raw; value.remove(at: i)
            let repeated = (i > 0 && raw[i - 1] == raw[i]) || (i + 1 < raw.count && raw[i + 1] == raw[i])
            roman(value, kind: .extraLetter, index: i, length: 1, cost: repeated ? 0.7 : 1.5)
            if i + 1 < raw.count, raw[i] != raw[i + 1] {
                var swapped = raw; swapped.swapAt(i, i + 1)
                roman(swapped, kind: .transposition, index: i, length: 2, cost: 1.05)
            }
        }
        for i in raw.indices {
            for (letter, distance) in neighbors(of: raw[i]) {
                var value = raw; value[i] = letter
                let vowelPair = "aiueo".contains(raw[i]) && "aiueo".contains(letter)
                roman(value, kind: .neighboringKey, index: i, length: 1, cost: distance + (vowelPair ? -0.1 : 0.1))
            }
        }
        // A missing vowel often leaves an internal unresolved consonant. Try
        // vowels before consonants, rejecting variants that still cannot parse.
        for letter in "aiueokstnhmyrwgzdbpfvcjqlx" {
            for i in 0...raw.count {
                var value = raw; value.insert(letter, at: i)
                roman(value, kind: .missingLetter, index: i, length: 0, cost: "aiueo".contains(letter) ? 1.15 : 1.6)
            }
        }
        return variants
    }

    /// Explore distinct original positions, retaining a small beam by lexical
    /// priority. The intermediate one-edit reading need not be a dictionary word.
    /// No Roman reconstruction: separators and literal characters stay intact.
    static func phoneticPairs(for query: ComposingText, priority: (Variant) -> Double,
                              cancelled: () -> Bool = { false }) -> [Variant] {
        let original = query.convertTarget
        guard (3...24).contains(original.count), query.input.count <= maximumInputCount,
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
