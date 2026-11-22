import UIKit

// The Chinese nine-key pad: digits 2–9 spell pinyin (vime_t9), laid out as the
// number pad. The rail beside the keys lists the syllables the input can
// start with, or punctuation while nothing is typed.
extension KeyboardView {
    static let nineKeyLetters = ["ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ"]
    static let nineKeyPunctuation = ["，", "。", "？", "！", "、", "：", "；", "…", "～", "“", "”"]

    func buildChineseNineKeys() {
        if syllableRail == nil {
            let rail = KeyboardNumberSymbolRail()
            rail.editable = false
            rail.identifierPrefix = "vime.nineKey.rail."
            rail.accessibilityIdentifier = "vime.nineKey.rail"
            rail.accessibilityLabel = String(localized: "拼音和标点")
            rail.accessibilityHint = nil
            rail.onSelect = { [weak self] item in
                guard let self, self.chineseNineKeyActive, self.panel == .keyboard else { return }
                self.playFeedback()
                if self.session.isComposing { self.apply(self.session.chooseLeadingSyllable(item)) }
                else { self.apply(self.session.insertLiteral(item)) }
            }
            syllableRail = rail
            addSubview(rail)
        }
        func letters(_ digit: Int) -> (KeyboardKey, CGFloat) {
            let title = Self.nineKeyLetters[digit - 2]
            let item = key(title) { [weak self] in
                guard let self else { return }
                KeyboardPerformance.record(.touchUpToType, since: self.keysContainer.releaseStartedAt)
                self.apply(self.session.type(String(digit)))
            }
            item.0.showsPreview = previewsEnabled
            item.0.previewHold = previewHold
            item.0.accessibilityLabel = title
            item.0.accessibilityIdentifier = "vime.nineKey.\(digit)"
            letterKeys.append(item.0)
            return item
        }
        let punctuation = KeyboardKanaLayout.punctuation.map { $0 == "、" ? "，" : $0 }
        let breakKey = key("，。?!") {}
        breakKey.0.flickOutputs = punctuation
        breakKey.0.showsFlickHints = false
        breakKey.0.flickAction = { [weak self] flick in
            guard let self else { return }
            if flick == .center, self.session.isComposing { self.apply(self.session.type("'")); return }
            self.apply(self.session.insertLiteral(punctuation[flick.rawValue]))
        }
        breakKey.0.action = { [weak button = breakKey.0] in button?.flickAction?(.center) }
        breakKey.0.accessibilityIdentifier = "vime.nineKey.1"
        nineKeyBreakKey = breakKey.0
        let retype = key(String(localized: "重输"), utility: true) { [weak self] in
            guard let self, self.session.isComposing else { return }
            self.session.reset(preservingContext: true)
            self.publishPreedit()
            self.refresh()
        }
        retype.0.accessibilityIdentifier = "vime.nineKey.retype"
        let emoji = symbol("face.smiling", label: String(localized: "表情"), weight: 1) { [weak self] in self?.toggleEmoji() }
        emoji.0.accessibilityIdentifier = "vime.key.emoji"
        let numbers = key("123", utility: true) { [weak self] in
            guard let self else { return }
            self.page = .numbers
            self.rebuildKeys()
        }
        let symbols = key(String(localized: "符号"), utility: true) { [weak self] in self?.openSymbolPanel(mode: .symbols) }
        symbols.0.accessibilityIdentifier = "vime.key.symbols"
        let space = key("", utility: true) { [weak self] in self?.space() }
        space.0.accessibilityLabel = String(localized: "空格，转换候选")
        space.0.accessibilityIdentifier = "vime.key.space"
        spaceKey = space.0
        let language = key("", utility: true) { [weak self] in
            guard let self else { return }
            guard self.consumeLanguageSwitchGuardDecision().shouldToggleLanguage else { return }
            self.apply(self.session.toggleEnglish())
            self.restoresLanguageAfterLatinField = false
            self.shifted = false
            self.capsLocked = false
            self.rebuildKeys()
            self.updateAutoCapitalization()
        }
        language.0.setImage(KeyboardGlyphs.language(active: session.inputTraits.language,
                                                    other: session.inputTraits.alternateLanguage), for: .normal)
        languageKey = language.0
        language.0.accessibilityLabel = session.inputTraits.languageSwitchAccessibilityLabel
        language.0.accessibilityIdentifier = "vime.key.language"
        configureQuickSwitch(language.0)
        let enter = key(String(localized: "换行"), utility: true) { [weak self] in
            guard let self else { return }
            self.apply(self.session.enter())
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        enter.0.accessibilityIdentifier = "vime.key.return"
        configureReturnHold(enter.0)
        returnKey = enter.0
        rows = [[breakKey, letters(2), letters(3), deleteKey(weight: 1)],
                [letters(4), letters(5), letters(6), retype],
                [letters(7), letters(8), letters(9), emoji],
                [numbers, symbols, space, language, enter]]
    }

    /// The rail follows the input: the syllables its digits can start with
    /// while typing (Rime's reading marked), punctuation otherwise.
    func refreshSyllableRail() {
        guard chineseNineKeyActive, let rail = syllableRail else { return }
        let composing = session.isComposing
        let syllables = composing ? session.leadingSyllables : []
        // A list still on its way keeps the syllables shown.
        if !composing { rail.present(Self.nineKeyPunctuation) }
        else if !syllables.isEmpty { rail.present(syllables) }
        rail.highlighted = composing ? session.currentLeadingSyllable : nil
        let title = composing ? String(localized: "分词") : "，。?!"
        if nineKeyBreakKey?.title(for: .normal) != title { nineKeyBreakKey?.setTitle(title, for: .normal) }
    }
}
