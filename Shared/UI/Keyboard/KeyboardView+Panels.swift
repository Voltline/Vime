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
        } else if session.isComposing { toggleExpanded() }
        else { onDismiss?() }
    }

    func toggleEmoji() {
        openSymbolPanel(mode: .emoji)
    }

    func openSymbolPanel(mode: KeyboardSymbolPanel.Mode) {
        apply(session.confirm())
        panel = .symbols
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
        symbolPanel?.selectMode(mode)
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
