import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// azooKey supplies the table and kana editing. Keep the second n available
/// when a following vowel/y turns nn into ん + an n syllable.
nonisolated enum RomajiConverter {
    static func insert(_ text: String, into composing: inout ComposingText) {
        for character in text {
            let tail = composing.input.suffix(2)
            if "aiueoy".contains(character), composing.convertTarget.hasSuffix("ん"),
               tail.count == 2, tail.allSatisfy({ $0.inputStyle == .roman2kana && $0.piece == .character("n") }) {
                var elements = Array(composing.input.dropLast(2))
                elements += [.init(character: "n", inputStyle: .roman2kana),
                             .init(piece: .compositionSeparator, inputStyle: .roman2kana),
                             .init(character: "n", inputStyle: .roman2kana)]
                composing = ComposingText()
                composing.insertAtCursorPosition(elements)
            }
            composing.insertAtCursorPosition(String(character), inputStyle: .roman2kana)
        }
    }

    static func katakana(_ hiragana: String) -> String {
        String(String.UnicodeScalarView(hiragana.unicodeScalars.map { scalar in
            (0x3041...0x3096).contains(scalar.value) ? UnicodeScalar(scalar.value + 0x60)! : scalar
        }))
    }

}
