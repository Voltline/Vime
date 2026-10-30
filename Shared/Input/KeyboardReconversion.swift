import Foundation

/// Reconversion (再変換): selected Japanese text returns to its reading, which
/// replaces the selection as marked text and is converted again.
enum KeyboardReconversion {
    static let maximumLength = 24

    /// The hiragana reading of `text`, or nil when it is not short Japanese
    /// text the keyboard can type back.
    static func reading(for text: String) -> String? {
        guard (1...maximumLength).contains(text.count), text.contains(where: isJapanese),
              text.allSatisfy({ isJapanese($0) || isKana($0) }) else { return nil }
        if text.allSatisfy(isKana) { return RomajiConverter.hiragana(text) }
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: (text as NSString).length),
            kCFStringTokenizerUnitWord, Locale(identifier: "ja_JP") as CFLocale)
        var reading = ""
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if token.allSatisfy(isKana) { reading += RomajiConverter.hiragana(token); continue }
            guard let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
                  let kana = latin.applyingTransform(.latinToHiragana, reverse: false) else { return nil }
            reading += kana
        }
        return !reading.isEmpty && reading.allSatisfy(isKana) ? reading : nil
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) || $0 == "ー" }
    }
    /// Kanji and the iteration mark; kana are checked separately.
    private static func isJapanese(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) || $0 == "々" }
            || isKana(character)
    }
}
