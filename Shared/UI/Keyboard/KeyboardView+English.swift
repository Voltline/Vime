import UIKit

extension KeyboardView {
    /// Two spaces released within this window after a word become ". ".
    static let doubleSpaceInterval: TimeInterval = 0.6

    func space(at now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        let quick = now - lastSpaceTap < Self.doubleSpaceInterval
        lastSpaceTap = now
        if quick, appliedPreferences?.doubleSpacePeriod == true, session.inputTraits.isEnglish, !session.isComposing,
           let context = leftContextProvider?(), context.hasSuffix(" "),
           let word = context.dropLast().last, word.isLetter || word.isNumber {
            lastSpaceTap = 0
            apply(session.backspace() + session.insertLiteral(". "))
            return
        }
        // Shift then space inserts the other width in Japanese mode, like a letter consumes it.
        let alternate = shifted && !session.inputTraits.isEnglish && !session.isComposing
        if alternate && !capsLocked { shifted = false; updateKeyLabels() }
        apply(session.space(alternateWidth: alternate))
    }

    /// Follows the field's capitalization while typing English. Only edits
    /// and host changes re-evaluate it, so a manual Shift stays until used.
    func updateAutoCapitalization() {
        guard appliedPreferences?.autoCapitalize == true, session.inputTraits.isEnglish, !capsLocked,
              !session.isComposing, page == .letters else { return }
        let wanted = Self.capitalizes(after: leftContextProvider?() ?? "", type: autocapitalizationType)
        guard wanted != shifted else { return }
        shifted = wanted
        updateKeyLabels()
    }

    static func capitalizes(after text: String, type: UITextAutocapitalizationType) -> Bool {
        switch type {
        case .allCharacters: return true
        case .words: return text.last?.isWhitespace ?? true
        case .sentences:
            guard let last = text.last else { return true }
            guard last.isWhitespace else { return false }
            if last.isNewline { return true }
            guard let end = text.last(where: { !$0.isWhitespace }) else { return true }
            return ".!?".contains(end)
        default: return false
        }
    }

    /// Stores the host's text replacements; kana shortcuts join conversion
    /// while the setting is on, Latin ones are offered as English words.
    func setTextReplacements(_ pairs: [(shortcut: String, phrase: String)]) {
        // The lexicon is requested on every appearance and rarely changes.
        guard !pairs.elementsEqual(systemTextReplacements, by: { $0 == $1 }) else { return }
        systemTextReplacements = pairs
        applyTextReplacements()
    }

    func applyTextReplacements() {
        JapaneseSystemShortcuts.update(appliedPreferences?.textReplacements == true ? systemTextReplacements : [])
        refresh()
    }

    /// The word before the caret, for completions and Latin shortcuts.
    static func trailingWord(in text: String) -> String {
        String(text.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" }.reversed())
    }

    /// Suggestions for the English word before the caret: the user's iOS text
    /// replacements first, then spelling completions. Choosing one replaces
    /// the word and adds a space.
    func englishWordItems() -> [KeyboardQuickCandidate] {
        guard session.inputTraits.isEnglish, page == .letters, panel == .keyboard, !session.isComposing,
              let preferences = appliedPreferences, preferences.textReplacements || preferences.englishCompletion,
              onReplaceText != nil, let anchor = learningContextProvider?(), !anchor.hasSelection,
              let before = anchor.before else { return [] }
        let word = Self.trailingWord(in: before)
        guard !word.isEmpty else { return [] }
        var titles: [String] = []
        if preferences.textReplacements {
            titles += systemTextReplacements.filter { $0.shortcut.caseInsensitiveCompare(word) == .orderedSame }.map(\.phrase)
        }
        if preferences.englishCompletion { titles += completions(for: word) }
        var seen: Set<String> = [word]
        return titles.filter { seen.insert($0).inserted }.prefix(8).map {
            .init(title: $0, action: .replacement(KeyboardTextReplacement(anchor: anchor, markedText: nil,
                committedSuffix: word, text: $0 + " ")))
        }
    }

    /// Up to three spelling completions in the word's own case.
    func completions(for word: String) -> [String] {
        guard word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" }), word.allSatisfy(\.isASCII) else { return [] }
        if let cached = completionCache, cached.word == word { return cached.values }
        let found = UITextChecker().completions(forPartialWordRange: NSRange(location: 0, length: word.utf16.count),
            in: word, language: "en_US") ?? []
        let values = found.prefix(3).map { value -> String in
            if word.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return value.uppercased() }
            if word.first?.isUppercase == true { return value.prefix(1).uppercased() + value.dropFirst() }
            return value
        }
        completionCache = (word, values)
        return values
    }
}
