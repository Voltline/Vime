import KanaKanjiConverterModuleWithDefaultDictionary

/// Presentation never changes or commits the underlying input. Unresolved
/// roman suffixes (including ambiguous n) remain editable until the converter
/// resolves them; only an explicit boundary finalizes the query snapshot.
enum PreeditPresentation {
    static func text(for composing: ComposingText, mode: InputMode, selected: String? = nil) -> String? {
        guard !composing.isEmpty, mode != .english else { return nil }
        return selected ?? kana(for: composing, mode: mode)
    }

    static func kana(for composing: ComposingText, mode: InputMode) -> String {
        mode == .katakana ? RomajiConverter.katakana(composing.convertTarget) : composing.convertTarget
    }

    static func finalized(_ composing: ComposingText) -> ComposingText {
        var query = composing
        query.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: .roman2kana)])
        return query
    }
}
