import UIKit

// Hit correction: which letters can continue the input, per language.
extension KeyboardView {
    func hitCorrectionPrior(held: String) -> KeyHitCorrection.Prior? {
        guard panel == .keyboard, page == .letters, !kanaLayoutActive, !capsLocked,
              !(shifted && shiftTypesCapitals) else { return nil }
        switch session.inputTraits.language {
        case .japanese: return KeyHitCorrection.romajiPrior(after: session.raw + held)
        case .chinese: return KeyHitCorrection.pinyinPrior(after: session.raw + held)
        case .english:
            let word = Self.trailingWord(in: session.leftContextProvider?() ?? "") + held
            return englishPrior(after: word)
        }
    }

    /// Letters that keep the word a prefix of some English word. Only when the
    /// word so far is one, so names and slang are left alone.
    func englishPrior(after word: String) -> KeyHitCorrection.Prior? {
        guard !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isLetter }), beginsEnglishWord(word) else { return nil }
        return { [weak self] letter in
            guard let self else { return 1 }
            return self.beginsEnglishWord(word + String(letter)) ? 1 : 0
        }
    }

    private func beginsEnglishWord(_ text: String) -> Bool {
        if let cached = englishPrefixCache[text] { return cached }
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = text.count < 2
            || checker.rangeOfMisspelledWord(in: text, range: range, startingAt: 0, wrap: false, language: "en_US").location == NSNotFound
            || !(checker.completions(forPartialWordRange: range, in: text, language: "en_US") ?? []).isEmpty
        if englishPrefixCache.count > 512 { englishPrefixCache.removeAll() }
        englishPrefixCache[text] = result
        return result
    }
}
