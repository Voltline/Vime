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
        apply(session.space())
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
}
