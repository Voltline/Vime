import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Literal input is always parsed by azooKey. Alternate n boundaries are
/// candidate queries only and must never alter the live preedit.
nonisolated enum RomajiConverter {
    static func insert(_ text: String, into composing: inout ComposingText) {
        composing.insertAtCursorPosition(text, inputStyle: .roman2kana)
    }

    static func nReadingAlternatives(for composing: ComposingText) -> [ComposingText] {
        let input = composing.input
        var alternatives: [ComposingText] = []
        var seen: Set<String> = [composing.convertTarget]
        func isN(_ index: Int) -> Bool {
            input.indices.contains(index) && input[index].inputStyle == .roman2kana
                && input[index].piece == .character("n")
        }
        func isVowelOrY(_ index: Int) -> Bool {
            guard input.indices.contains(index), input[index].inputStyle == .roman2kana,
                  case .character(let c) = input[index].piece else { return false }
            return "aiueoy".contains(c)
        }
        func append(_ elements: [ComposingText.InputElement]) {
            guard alternatives.count < 4 else { return }
            var value = ComposingText(); value.insertAtCursorPosition(elements)
            guard !value.convertTarget.unicodeScalars.contains(where: { (97...122).contains($0.value) }),
                  seen.insert(value.convertTarget).inserted else { return }
            alternatives.append(value)
        }
        let separator = ComposingText.InputElement(piece: .compositionSeparator, inputStyle: .roman2kana)
        for i in input.indices where isN(i) && !isN(i - 1) {
            if isN(i + 1), isVowelOrY(i + 2) {
                var elements = input; elements.insert(separator, at: i + 1)
                append(elements)
            } else if isVowelOrY(i + 1) {
                var boundary = input; boundary.insert(separator, at: i + 1)
                append(boundary)
                var nasal = input
                nasal.insert(contentsOf: [separator, .init(character: "n", inputStyle: .roman2kana)], at: i + 1)
                append(nasal)
            }
        }
        return alternatives
    }

    static func katakana(_ hiragana: String) -> String {
        String(String.UnicodeScalarView(hiragana.unicodeScalars.map { scalar in
            (0x3041...0x3096).contains(scalar.value) ? UnicodeScalar(scalar.value + 0x60)! : scalar
        }))
    }

}
