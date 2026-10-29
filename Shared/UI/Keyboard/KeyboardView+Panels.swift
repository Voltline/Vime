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

    func toggleEmoji() {
        openSymbolPanel(mode: .emoji)
    }

    func openSymbolPanel(mode: KeyboardSymbolPanel.Mode) {
        emojiSearchActive = false
        apply(session.confirm())
        panel = .symbols
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
        symbolPanel?.recents = preferences.emojiRecents
        symbolPanel?.selectMode(mode)
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

    func showSymbolPanel() {
        if symbolPanel == nil {
            let panel = KeyboardSymbolPanel()
            panel.onFeedback = { [weak self] in self?.playFeedback() }
            panel.onSelect = { [weak self] text in
                guard let self else { return }
                self.playFeedback()
                let composes = self.session.isComposing && self.session.inputTraits.compositionInputSymbols.contains(text)
                if composes { self.apply(self.session.type(text)) } else { self.insertSymbol(text) }
            }
            panel.onClose = { [weak self] in self?.headerArrow() }
            panel.onEmojiUse = { [weak self] in self?.preferences.recordEmoji($0) }
            panel.onSearch = { [weak self] in self?.beginEmojiSearch() }
            addSubview(panel); symbolPanel = panel
            panel.applyTheme()
        }
        symbolPanel?.isHidden = false
        setNeedsLayout()
    }

    @objc func toggleKana() {
        apply(session.togglePrimaryVariant())
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
        view.onRetryNeural = { [weak self] in
            guard let self else { return }
            self.preferences.requestNeuralRetry()
            self.reloadPreferences()
        }
        addSubview(view)
        settingsPanel = view
    }
}
