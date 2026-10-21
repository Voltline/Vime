import UIKit

// Feedback, scroll styling, skins and theme.
extension KeyboardView {
    func playFeedback() {
        if preferences.sound && hasFullAccess {
            // Apple documents audio (including input clicks) as an open-access
            // capability for extensions. Never invoke a denied audio path that
            // could stall input. Visual feedback and haptic attempts are separate.
            UIDevice.current.playInputClick()
        }
        let intensity = preferences.hapticIntensity
        guard intensity > 0 else { return }
        // Keep one feedback style across the range so intermediate values do not
        // jump when crossing a style boundary
        let generator = impactGenerators[1] ?? UIImpactFeedbackGenerator(style: .heavy)
        impactGenerators[1] = generator
        generator.impactOccurred(intensity: CGFloat(intensity))
        generator.prepare()
    }

    @objc func toolbarFeedback() { playFeedback() }

    func configureScroll(_ scroll: UIScrollView) {
        scroll.backgroundColor = KeyboardTouchBacking.color
        scroll.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            // Candidate text is foreground content, not content behind a toolbar.
            for edge in [scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect] {
                edge.isHidden = true
            }
        }
    }

    func applyKeySkins() {
        for (key, _) in rows.flatMap({ $0 }) {
            let identifier = key.accessibilityIdentifier?.replacingOccurrences(of: "vime.key.", with: "") ?? ""
            let semantic: String
            if key === shiftKey { semantic = "shift" }
            else if key === returnKey { semantic = "return" }
            else if letterKeys.contains(where: { $0 === key }) { semantic = "letter." + identifier }
            else if key.repeats { semantic = "backspace" }
            else if key.accessibilityIdentifier == "vime.number.emoji" { semantic = "emoji" }
            else if ["123", "ABC", "#+="].contains(key.title(for: .normal) ?? "") { semantic = "numbers" }
            else { semantic = identifier }
            key.applySkin(KeyboardPalette.skin, key: semantic)
        }
        invalidateKeyGrid()
    }
    func applyTheme() {
        KeyboardPalette.theme = preferences.theme
        let document = preferences.theme == .custom ? try? KeyboardSkinStore().load(preferences.customSkinID) : nil
        KeyboardPalette.skin = document.map { KeyboardSkinAppearance($0, reusing: skinCanvas.appearance) }
        skinCanvas.appearance = KeyboardPalette.skin
        brandArtwork.image = KeyboardPalette.skin?.image(for: "brand")
        brandButton.setImage(brandArtwork.image == nil ? KeyboardGlyphs.logo() : nil, for: .normal)
        applyKeySkins()
        overrideUserInterfaceStyle = preferences.theme == .midnight ? .dark : .unspecified
        backgroundColor = document.map { KeyboardSkinAppearance.color($0.palette.background) } ?? preferences.theme.background
        header.backgroundColor = document.map { KeyboardSkinAppearance.color($0.palette.key).withAlphaComponent(0.88) } ?? .clear
        setNeedsLayout()
        for row in rows {
            for (key, _) in row {
                key.fillColor = key.isUtility ? KeyboardPalette.utility : KeyboardPalette.key
                key.setTitleColor(KeyboardPalette.text, for: .normal)
                key.tintColor = KeyboardPalette.text
            }
        }
        for button in stripButtons + spareCandidateButtons { button.applyTheme() }
        for button in panelCandidates + sparePanelButtons {
            button.applyTheme()
            button.tintColor = KeyboardPalette.text
        }
        for button in [brandButton, undoButton, modeButton, expandButton] { button.backgroundColor = KeyboardPalette.key }
        clipboardSuggestion.applyTheme()
        quickCandidates.applyTheme()
        numberSymbolRail?.applyTheme()
        clipboardHistoryPanel?.applyTheme()
        undoButton.tintColor = KeyboardPalette.accent
        deletePrompt.applyTheme()
        panelTitle.textColor = KeyboardPalette.text
        gestureHint.textColor = KeyboardPalette.text
        settingsPanel?.applyTheme()
        symbolPanel?.applyTheme()
        refresh()
    }
}
