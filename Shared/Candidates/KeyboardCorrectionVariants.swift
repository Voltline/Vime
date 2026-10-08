import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// One local error only. These are character/sound rules, never whole-word
/// replacements. Dictionary evidence is evaluated by the candidate engine.
nonisolated enum KeyboardCorrectionVariants {
    struct Variant {
        let reading: String
        let suggestion: CorrectionSuggestion
    }
    static let maximumInputCount = 40
    static let maximumVariants = 384

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
        let soundGroups = ["かが", "きぎ", "くぐ", "けげ", "こご", "さざ", "しじ", "すず", "せぜ", "そぞ",
                           "ただ", "ちぢじ", "つづず", "てで", "とど", "はばぱ", "ひびぴ", "ふぶぷ", "へべぺ", "ほぼぽ",
                           "やゃ", "ゆゅ", "よょ", "つっ"]
        for i in kana.indices {
            let old = kana[i]
            for group in soundGroups where group.contains(old) {
                for next in group where next != old {
                    kana[i] = next
                    append(String(kana), roman: nil, kind: .phonetic, offset: i, length: 1,
                        unit: .kanaReading, cost: old == "つ" && next == "ず" ? 0.75 : 1.0)
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
