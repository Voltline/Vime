import UIKit

// Toolbar navigation between the keyboard, symbol and settings panels.
extension KeyboardView {
    func configureGlobe() {
        globeButton.removeTarget(nil, action: nil, for: .allTouchEvents)
        if needsGlobe, let target = inputModeListTarget, let selector = inputModeListAction {
            globeButton.addTarget(target, action: selector, for: .allTouchEvents)
        } else { globeButton.addTarget(self, action: #selector(switchKeyboard), for: .touchUpInside) }
        // Configuring the system input-mode selector removes old touch targets;
        // reinstall feedback each time so the globe still has a native click.
        globeButton.addTarget(self, action: #selector(toolbarFeedback), for: .touchDown)
    }

    @objc func switchKeyboard() { confirmComposition(); onSwitchKeyboard?() }

    @objc func headerArrow() {
        if panel != .keyboard {
            panel = .keyboard; refresh()
        } else if emojiSearchActive { endEmojiSearch() }
        else if showsNextWordClose { session.dismissSuggestions(); refresh() }
        else if session.isComposing { toggleExpanded() }
        else { onDismiss?() }
    }

    /// The emoji key's tap, unless the guard reads it as a graze while typing.
    func tapEmojiKey() {
        guard consumeEmojiKeyGuardDecision().shouldAct else { return }
        toggleEmoji()
    }

    func toggleEmoji() {
        openSymbolPanel(mode: .emoji)
    }

    func openSymbolPanel(mode: KeyboardSymbolPanel.Mode) {
        emojiSearchActive = false
        apply(session.confirm())
        panel = .symbols
        panelScroll.setContentOffset(.zero, animated: false)
        // Set up the panel before it shows, so it opens on `mode` in one go.
        showSymbolPanel()
        symbolPanel?.chineseSymbols = session.inputTraits.language == .chinese
        symbolPanel?.selectMode(mode)
        refresh()
    }

    /// Typing searches emoji by reading until a result is chosen or the
    /// search is closed. The reading stays marked text until then.
    func beginEmojiSearch() {
        emojiSearchActive = true
        panel = .keyboard
        refresh()
    }

    /// Closing keeps any typed reading as ordinary composition.
    func endEmojiSearch() {
        emojiSearchActive = false
        refresh()
    }

    func emojiSearchItems() -> [KeyboardQuickCandidate] {
        guard session.isComposing else {
            return [.init(title: String(localized: "输入读音搜索表情"), action: .prompt)]
                + preferences.emojiRecents.map { .init(title: $0, action: .emoji($0)) }
        }
        let results = KeyboardEmojiSearch.results(reading: session.composition, typed: session.raw)
        return results.isEmpty ? [.init(title: String(localized: "没有找到表情"), action: .prompt)]
            : results.map { .init(title: $0, action: .emoji($0)) }
    }

    /// Returns from the symbol/emoji panel directly to the main input page
    /// rather than leaving the number pad open underneath.
    func closeSymbolPanelToInput() {
        let needsLetters = page != .letters
        if needsLetters { page = .letters }
        panel = .keyboard
        if needsLetters { rebuildKeys() }
        refresh()
    }

    func showSymbolPanel() {
        if symbolPanel == nil {
            let panel = KeyboardSymbolPanel()
            panel.onFeedback = { [weak self] in self?.playFeedback() }
            panel.onSelect = { [weak self, weak panel] text in
                guard let self else { return }
                self.playFeedback()
                let composes = self.session.isComposing && self.session.inputTraits.compositionInputSymbols.contains(text)
                if composes { self.apply(self.session.type(text)) } else { self.insertSymbol(text) }
                if panel?.displayedMode == .symbols {
                    self.closeSymbolPanelToInput()
                }
            }
            panel.onClose = { [weak self] in self?.closeSymbolPanelToInput() }
            panel.onEmojiUse = { [weak self] in self?.preferences.recordEmoji($0) }
            panel.onSearch = { [weak self] in self?.beginEmojiSearch() }
            panel.onDelete = { [weak self] in
                guard let self else { return }
                guard self.hasDeletableContent else { self.apply([.deleteBackward]); return }
                self.kanaToggle = nil
                self.apply(self.session.backspace())
            }
            addSubview(panel); symbolPanel = panel
            panel.applyTheme()
        }
        symbolPanel?.isHidden = false
        setNeedsLayout()
    }

    @objc func toggleKana() {
        apply(session.togglePrimaryVariant())
        let traits = session.inputTraits
        if traits.language == .chinese, traits.traditionalChinese != preferences.traditionalChinese {
            preferences.traditionalChinese = traits.traditionalChinese
        }
        rebuildKeys()
    }

    @objc func toggleSettings() {
        panel = panel == .settings ? .keyboard : .settings
        if settingsPanel == nil { createSettingsPanel() }
        refresh()
    }

    func createSettingsPanel() {
        let view = KeyboardSettingsPanel(preferences: preferences)
        configureScroll(view)
        view.onHistory = { [weak self] in self?.openClipboardHistory() }
        view.onOpenAppSettings = { [weak self] in self?.onOpenAppSettings?() }
        view.onFeedback = { [weak self] in self?.playFeedback() }
        view.onNumberLayoutChange = { [weak self] in self?.rebuildKeys() }
        view.onOneHandedChange = { [weak self] in self?.reloadPreferences() }
        view.onLiveConversionChange = { [weak self] in self?.reloadPreferences() }
        view.enabledLanguages = enabledPrimaryLanguages
        view.showsInputLanguage = enabledPrimaryLanguages.count > 1 && followsInputLanguage
        view.onInputLanguageChange = { [weak self] in self?.switchInputLanguage(to: $0) }
        view.showsChineseLayout = session is ChineseInputSession
        view.onChineseLayoutChange = { [weak self] in self?.reloadPreferences() }
        view.onRetryNeural = { [weak self] in
            guard let self else { return }
            self.preferences.requestNeuralRetry()
            self.reloadPreferences()
        }
        addSubview(view)
        settingsPanel = view
    }
}
