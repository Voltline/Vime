import UIKit

// Publishes session and panel state to the toolbar, strip, panels and keys.
extension KeyboardView {
    /// Which toolbar controls are visible. Pure: derived only from its inputs,
    /// so the visibility rules can be read (and tested) apart from UIKit.
    struct ChromeState: Equatable {
        let showsQuick: Bool
        let showsClipboard: Bool
        /// Any candidate content occupies the toolbar.
        let strip: Bool
        let hidesQuick: Bool
        let hidesNeuralStatus: Bool
        let hidesHeader: Bool
        let hidesUndo: Bool
        let hidesBrand: Bool
        let hidesMode: Bool
        let hidesCandidateScroll: Bool
        let hidesDivider: Bool
        let hidesPanelTitle: Bool
        let hidesRangeControls: Bool
        /// Next-word suggestions after a commit take the whole row, with a
        /// close button where the dismiss-keyboard button was.
        let showsNextWords: Bool

        init(panel: Panel, page: Page, composing: Bool, sessionStrip: Bool, quickAvailable: Bool,
             clipboardOffered: Bool, neuralPaused: Bool, canUndo: Bool, supportsPrimaryVariant: Bool,
             hasConversionRange: Bool, emojiSearch: Bool = false) {
            let keyboard = panel == .keyboard
            // Composition candidates and LM suggestions share the strip.
            showsQuick = quickAvailable
            showsClipboard = clipboardOffered && !composing && !quickAvailable && keyboard
            strip = sessionStrip || showsQuick || showsClipboard
            hidesQuick = !showsQuick || !keyboard
            hidesNeuralStatus = !neuralPaused || strip || !keyboard
            hidesHeader = panel == .symbols || panel == .clipboardHistory
            hidesUndo = !canUndo || strip || !keyboard
            showsNextWords = keyboard && sessionStrip && !composing && !showsQuick && !showsClipboard
            let idleToolbar = (showsQuick || showsClipboard) && !composing
            hidesBrand = (keyboard && (page != .letters || (strip && !idleToolbar) || emojiSearch))
                || (panel == .candidates || panel == .symbols || panel == .clipboardHistory)
            hidesMode = strip || page != .letters || !keyboard || !supportsPrimaryVariant
            hidesCandidateScroll = !strip || showsQuick || showsClipboard || !keyboard
            hidesDivider = !strip || showsClipboard || !keyboard
            hidesPanelTitle = panel != .candidates && panel != .settings
            hidesRangeControls = panel != .candidates || !hasConversionRange
        }
    }

    func refresh() {
        let uiStartedAt = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.candidateUIUpdate, since: uiStartedAt) }
        // Any switch between Japanese and English (language key, mode button,
        // host keyboard type) swaps the flick pad and QWERTY.
        if !rebuildingKeys && page == .letters && kanaLayoutActive != usesKanaLayout { rebuildKeys(); return }
        let traits = session.inputTraits
        let composing = session.isComposing
        refreshLanguageKey(traits)
        refreshToolbar(traits, composing: composing)
        refreshCandidateStrip()
        refreshPanels(composing: composing)
        refreshActionKeys(traits, composing: composing)
        setNeedsLayout()
    }

    func refreshLanguageKey(_ traits: KeyboardInputTraits) {
        if displayedLanguage != traits.language || displayedAlternateLanguage != traits.alternateLanguage {
            traitCollection.performAsCurrent {
                languageKey?.setImage(KeyboardGlyphs.language(active: traits.language, other: traits.alternateLanguage), for: .normal)
            }
            displayedLanguage = traits.language
            displayedAlternateLanguage = traits.alternateLanguage
        }
        languageKey?.accessibilityValue = traits.language.accessibilityName
        languageKey?.accessibilityLabel = traits.languageSwitchAccessibilityLabel
    }

    func refreshToolbar(_ traits: KeyboardInputTraits, composing: Bool) {
        let quick = quickCandidateItems()
        let neuralPaused = session.neuralModeSuspendedForMemoryPressure
        let rangeDescription = session.conversionRangeDescription
        let state = ChromeState(panel: panel, page: page, composing: composing, sessionStrip: session.showsStrip,
            quickAvailable: !quick.isEmpty,
            clipboardOffered: clipboard.text != nil && preferences.clipboardSuggestions && hasFullAccess && clipboardActive,
            neuralPaused: neuralPaused, canUndo: canUndoLineDeletion,
            supportsPrimaryVariant: traits.supportsPrimaryVariant, hasConversionRange: rangeDescription != nil,
            emojiSearch: emojiSearchActive)
        quickCandidates.present(quick)
        quickCandidates.isHidden = state.hidesQuick
        clipboardSuggestion.present(state.showsClipboard ? clipboard.text : nil)
        clipboardSuggestion.isHidden = !state.showsClipboard
        neuralStatusLabel.isHidden = state.hidesNeuralStatus
        settingsPanel?.update(hasFullAccess: hasFullAccess, neuralPaused: neuralPaused)
        header.isHidden = state.hidesHeader
        undoButton.isHidden = state.hidesUndo
        brandButton.isHidden = state.hidesBrand
        modeButton.isHidden = state.hidesMode
        modeButton.accessibilityLabel = traits.primaryVariantAccessibilityLabel
        candidateScroll.isHidden = state.hidesCandidateScroll
        expandButton.isHidden = state.showsClipboard
        showsNextWordClose = state.showsNextWords || (emojiSearchActive && panel == .keyboard)
        modeButton.setTitle(traits.modeLabel, for: .normal)
        accessibilityValue = composing ? String(localized: "输入中：\(session.markedText?.text ?? "")") : traits.modeLabel
        expandButton.backgroundColor = composing ? KeyboardTouchBacking.color : KeyboardPalette.key
        divider.isHidden = state.hidesDivider
        divider.backgroundColor = .separator
        panelTitle.isHidden = state.hidesPanelTitle
        panelTitle.text = panel == .settings ? String(localized: "快捷设置") : rangeDescription ?? String(localized: "候选词")
        for control in [shortenRange, lengthenRange, wholeRange] { control.isHidden = state.hidesRangeControls }
    }

    /// Reuses strip buttons in place and keeps the scroll position when the
    /// new list only extends the displayed one.
    func refreshCandidateStrip() {
        let presentations = Array(session.stripPresentations.prefix(max(20, (session.selectedIndex ?? 0) + 1)))
        let candidatesChanged = displayedCandidates != presentations
        let preservesCandidatePositions = !displayedCandidates.isEmpty && presentations.count >= displayedCandidates.count
            && zip(displayedCandidates, presentations).allSatisfy { pair in
                pair.0.text == pair.1.text && pair.0.consumedInputCount == pair.1.consumedInputCount
                    && pair.0.selectionToken == pair.1.selectionToken
            }
        let selectionChanged = displayedSelection != session.selectedIndex
        if candidatesChanged || selectionChanged {
            displayedCandidates = presentations
            displayedSelection = session.selectedIndex
            while stripButtons.count > displayedCandidates.count {
                let button = stripButtons.removeLast()
                button.removeFromSuperview()
                spareCandidateButtons.append(button)
            }
            while stripButtons.count < displayedCandidates.count {
                let index = stripButtons.count
                let button = spareCandidateButtons.popLast() ?? candidateButton(displayedCandidates[index], index: index)
                stripButtons.append(button)
                candidateRow.addSubview(button)
            }
            for (index, button) in stripButtons.enumerated() {
                presentCandidate(button, presentation: displayedCandidates[index], index: index)
            }
            // Frames and label layout are published here and included in timing.
            // A one-dimensional strip needs no changing Auto Layout graph.
            layoutCandidateStrip()
        }
        if let index = session.selectedIndex, stripButtons.indices.contains(index), selectionChanged {
            candidateScroll.scrollRectToVisible(stripButtons[index].frame, animated: true)
        } else if candidatesChanged && !preservesCandidatePositions && session.selectedIndex == nil {
            candidateScroll.setContentOffset(.zero, animated: false)
        }
        // The retained list may belong to the previous input revision. Keep
        // its appearance, but never let a stale tap discard the newer letters.
        stripButtons.forEach { $0.isUserInteractionEnabled = session.candidatesAreCurrent && $0.selectionToken != nil }
    }

    func refreshPanels(composing: Bool) {
        let panelOpen = panel != .keyboard
        let glyph = showsNextWordClose ? Self.closeMark : panelOpen ? Self.chevronUp : Self.chevronDown
        if expandButton.image(for: .normal) !== glyph { expandButton.setImage(glyph, for: .normal) }
        // The close mark matches the clipboard preview's: no key backing.
        if showsNextWordClose { expandButton.backgroundColor = .clear }
        expandButton.accessibilityLabel = showsNextWordClose
            ? (emojiSearchActive ? String(localized: "关闭表情搜索") : String(localized: "关闭联想"))
            : panelOpen ? String(localized: "返回键盘") : composing ? String(localized: "展开候选词") : String(localized: "收起键盘")
        expandButton.accessibilityIdentifier = showsNextWordClose
            ? (emojiSearchActive ? "vime.emojiSearch.close" : "vime.suggestions.close")
            : panelOpen ? "vime.panel.close" : "vime.candidates.expand"
        numberSymbolRail?.isHidden = panelOpen || !usesNumberPad
        if panelOpen { keysContainer.cancelAllPresses() }
        keysContainer.isHidden = panelOpen
        panelScroll.isHidden = panel != .candidates
        symbolPanel?.isHidden = panel != .symbols
        settingsPanel?.isHidden = panel != .settings
        clipboardHistoryPanel?.isHidden = panel != .clipboardHistory
        if panel == .candidates { rebuildCandidatePanel() }
        else if panel == .symbols { showSymbolPanel() }
    }

    func refreshActionKeys(_ traits: KeyboardInputTraits, composing: Bool) {
        spaceKey?.setTitle(usesNumberPad ? "空格" : composing ? traits.compositionSpaceTitle
            : kanaLayoutActive ? String(localized: "空格") : "", for: .normal)
        returnKey?.setTitle(composing ? traits.compositionReturnTitle : returnTitle, for: .normal)
        let actionReturn = !composing && [.send, .search, .go, .done, .next, .join, .route, .continue].contains(returnKeyType)
        returnKey?.fillColor = actionReturn ? UIColor(cgColor: VimeLogo.blue) : KeyboardPalette.utility
        returnKey?.setTitleColor(actionReturn ? .white : KeyboardPalette.text, for: .normal)
        if returnKey?.hasSkinArtwork == true {
            returnKey?.fillColor = KeyboardPalette.key
            returnKey?.setTitleColor(KeyboardPalette.text, for: .normal)
        }
        if let numberBackKey, !numberBackKey.hasSkinArtwork {
            numberBackKey.fillColor = KeyboardPalette.accent
            numberBackKey.setTitleColor(.white, for: .normal)
        }
    }

    static let chevronUp = UIImage(systemName: "chevron.up")
    static let chevronDown = UIImage(systemName: "chevron.down")
    static let closeMark = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium))
}
