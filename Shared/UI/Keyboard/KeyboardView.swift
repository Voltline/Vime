import UIKit

final class KeyboardView: UIView, UIInputViewAudioFeedback, UIScrollViewDelegate {
    var hasFullAccess = true {
        didSet {
            if oldValue != hasFullAccess { updateClipboardMonitoring() }
            if oldValue != hasFullAccess { refresh() }
        }
    }
    var enableInputClicksWhenVisible: Bool { preferences.sound }
    let preferences: KeyboardPreferences
    var appliedPreferences: KeyboardPreferences.Snapshot?
    let skinCanvas = KeyboardSkinCanvas()
    let brandArtwork = UIImageView()
    var onEdit: (([KeyboardEdit]) -> Void)?
    /// Partial commits replace the old mark and publish its remainder in one
    /// host transaction, before processing host change notifications.
    var onEditsAndPreeditChange: (([KeyboardEdit], KeyboardPreedit?) -> Void)?
    var onSwitchKeyboard: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onOpenNumberSymbolSettings: (() -> Void)?
    var onOpenAppSettings: (() -> Void)?
    var onPreeditChange: ((KeyboardPreedit?) -> Void)?
    var onHeightChange: (() -> Void)?
    var onReplaceText: ((KeyboardTextReplacement) -> Bool)?
    var deletionAvailabilityProvider: (() -> Bool)?
    /// The host's selected text, offered for reconversion.
    var selectedTextProvider: (() -> String?)?
    var heightFactor: CGFloat = 1 {
        didSet {
            guard oldValue != heightFactor else { return }
            stopInteractions(); setNeedsLayout(); invalidateIntrinsicContentSize(); onHeightChange?()
        }
    }
    var canUndoLineDeletion = false { didSet { if oldValue != canUndoLineDeletion { refresh() } } }
    func reloadPreferences() {
        let next = preferences.snapshot
        let previous = appliedPreferences
        guard next != previous else { return }
        appliedPreferences = next
        heightFactor = CGFloat(next.heightFactor)
        session.updateIntelligence(ranking: next.candidateRanking, suggestionsEnabled: next.phraseSuggestions)
        session.setUndoesCommitOnBackspace(next.undoConversionOnBackspace)
        applyNeuralRetry()
        if next.learningResetID != previous?.learningResetID {
            session.reset()
            session.prepareForInput()
            publishPreedit()
            refresh()
        }
        if next.clipboardSuggestions != previous?.clipboardSuggestions { updateClipboardMonitoring() }
        if next.nineKeyNumbers != previous?.nineKeyNumbers || next.prolongedKey != previous?.prolongedKey
            || next.kanaLayout != previous?.kanaLayout {
            rebuildKeys()
        }
        if next.oneHanded != previous?.oneHanded { setNeedsLayout() }
        if next.numberSymbols != previous?.numberSymbols { numberSymbolRail?.present(next.numberSymbols) }
        if next.autoCapitalize != previous?.autoCapitalize { updateAutoCapitalization() }
        if next.textReplacements != previous?.textReplacements { applyTextReplacements() }
        else if next.englishCompletion != previous?.englishCompletion { refresh() }
        if next.previews != previous?.previews {
            for key in letterKeys { key.showsPreview = next.previews }
        }
        if next.theme != previous?.theme || next.customSkinID != previous?.customSkinID || next.skinRevision != previous?.skinRevision { applyTheme() }
        settingsPanel?.update(hasFullAccess: hasFullAccess, neuralPaused: session.neuralModeSuspendedForMemoryPressure)
    }
    func applyNeuralRetry() {
        guard preferences.candidateRanking == .languageModel, let id = preferences.neuralRetryID else { return }
        session.retryLanguageModel(requestID: id)
    }
    weak var inputModeListTarget: AnyObject? { didSet { configureGlobe() } }
    var inputModeListAction: Selector? { didSet { configureGlobe() } }
    var needsGlobe = false { didSet { if oldValue != needsGlobe { configureGlobe() } } }
    var showsFooter = true { didSet { if oldValue != showsFooter { setNeedsLayout(); invalidateIntrinsicContentSize(); onHeightChange?() } } }
    var compact = false { didSet { if oldValue != compact { setNeedsLayout(); invalidateIntrinsicContentSize(); onHeightChange?() } } }
    /// Running on an iPad; a docked, full-width keyboard uses the iPad layout.
    var pad = false { didSet { if oldValue != pad { setNeedsLayout(); invalidateIntrinsicContentSize(); onHeightChange?() } } }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        KeyboardMetrics(width: width > 0 ? width : 440, compact: compact, showsFooter: showsFooter, heightFactor: heightFactor,
            pad: pad).height
    }
    var returnKeyType: UIReturnKeyType = .default { didSet { if oldValue != returnKeyType { refresh() } } }
    var keyboardType: UIKeyboardType = .default {
        didSet {
            guard oldValue != keyboardType else { return }
            if [.numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad, .numbersAndPunctuation].contains(keyboardType) { page = .numbers }
            else { page = .letters }
            if [.emailAddress, .URL, .asciiCapable].contains(keyboardType) { apply(session.activateEnglish()) }
            rebuildKeys()
        }
    }

    enum Page { case letters, numbers, symbols }
    let session: any KeyboardInputSession
    var displayedCandidates: [CandidatePresentation] = []
    var displayedSelection: Int?
    var pendingCandidateTiming: (startedAt: TimeInterval, token: CandidateSelectionToken)?
    var page: Page = .letters
    var shifted = false
    var capsLocked = false
    var lastShiftTap: TimeInterval = 0
    var lastSpaceTap: TimeInterval = 0
    /// Every iOS text replacement the host lexicon supplied, kana or Latin.
    var systemTextReplacements: [(shortcut: String, phrase: String)] = []
    /// Refreshes ask several times per key, so the last word's completions are kept.
    var completionCache: (word: String, values: [String])?
    var autocapitalizationType: UITextAutocapitalizationType = .sentences {
        didSet { if oldValue != autocapitalizationType { updateAutoCapitalization() } }
    }
    enum Panel { case keyboard, candidates, settings, symbols, clipboardHistory }
    var panel: Panel = .keyboard {
        didSet {
            if (oldValue == .candidates) != (panel == .candidates) {
                session.setExpandedCandidates(panel == .candidates)
            }
        }
    }
    var previewsEnabled: Bool { preferences.previews }
    var impactGenerators: [Int: UIImpactFeedbackGenerator] = [:]
    let header = UIView()
    let candidateScroll = UIScrollView()
    let candidateRow = UIView()
    let quickCandidates = KeyboardQuickCandidateStrip()
    let clipboardSuggestion = ClipboardSuggestionView()
    let clipboard: KeyboardClipboard
    var clipboardTimer: Timer?
    var clipboardActive = true
    /// The header arrow closes next-word suggestions or emoji search instead
    /// of the keyboard.
    var showsNextWordClose = false
    /// Typed readings search emoji; results replace the toolbar's candidates.
    var emojiSearchActive = false
    var clipboardHistoryPanel: ClipboardHistoryPanel?
    var historyRequest = 0
    var stripButtons: [KeyboardCandidateButton] = []
    var spareCandidateButtons: [KeyboardCandidateButton] = []
    /// Leads the next-word row after a conversion and returns it to its reading.
    var reconvertChip: UIButton?
    /// Shown after a long press on a learned candidate.
    var forgetPrompt: KeyboardForgetPrompt?
    var displayedReconversion: String?
    var displayedLanguage: KeyboardInputLanguage?
    var displayedAlternateLanguage: KeyboardInputLanguage?
    let brandButton = KeyboardToolbarButton(type: .custom)
    let globeButton = UIButton(type: .custom)
    let modeButton = KeyboardToolbarButton(type: .system)
    let neuralStatusLabel = UILabel()
    let undoButton = KeyboardToolbarButton(type: .system)
    let expandButton = KeyboardToolbarButton(type: .system)
    /// Fills the strip beside one-handed keys and restores full width.
    let oneHandedButton = UIButton(type: .system)
    let divider = UIView()
    let panelTitle = UILabel()
    let shortenRange = KeyboardToolbarButton(type: .system)
    let lengthenRange = KeyboardToolbarButton(type: .system)
    let wholeRange = KeyboardToolbarButton(type: .system)
    var panelLimit = 40
    let gestureHint = UILabel()
    let deletePrompt = KeyboardDeletePrompt()
    let previewOverlay = UIView()
    let keysContainer = KeyboardTouchSurface()
    let panelScroll = UIScrollView()
    var panelCandidates: [KeyboardCandidateButton] = []
    var sparePanelButtons: [KeyboardCandidateButton] = []
    var settingsPanel: KeyboardSettingsPanel?
    var symbolPanel: KeyboardSymbolPanel?
    var rows: [[(KeyboardKey, CGFloat)]] = []
    var rebuildingKeys = false
    /// Every candidate refresh requests layout. The key grid (frames, fonts,
    /// skin metrics, touch regions) depends only on these inputs, so it is laid
    /// out again when one changes rather than on every keystroke.
    struct KeyGridLayout: Equatable {
        let size: CGSize
        let compact: Bool
        let pad: Bool
        let showsFooter: Bool
        let heightFactor: CGFloat
        let page: Page
        let numberPad: Bool
        let kana: Bool
        let oneHanded: KeyboardOneHandedSide
        let generation: Int
    }
    var keyGridGeneration = 0
    var laidOutKeyGrid: KeyGridLayout?
    func invalidateKeyGrid() { keyGridGeneration &+= 1; setNeedsLayout() }
    var letterKeys: [KeyboardKey] = []
    var shiftKey: KeyboardKey?
    var spaceKey: KeyboardKey?
    var languageKey: KeyboardKey?
    var returnKey: KeyboardKey?
    var numberSymbolRail: KeyboardNumberSymbolRail?
    var numberBackKey: KeyboardKey?
    var usesNumberPad: Bool { page == .numbers && preferences.nineKeyNumbers }
    /// Japanese input on the flick pad; English keeps QWERTY.
    var prefersKanaLayout: Bool { preferences.kanaLayout && !session.inputTraits.isEnglish }
    var usesKanaLayout: Bool { page == .letters && prefersKanaLayout }
    /// The layout the current rows were built for.
    var kanaLayoutActive = false
    /// The last toggle-input tap: key row in KeyboardKanaLayout.keys, what it entered, and when.
    var kanaToggle: (key: Int, output: Character, time: TimeInterval)?

    override convenience init(frame: CGRect) {
        self.init(frame: frame, session: KeyboardSession(asynchronousCandidates: true))
    }

    init(frame: CGRect, session: any KeyboardInputSession, preferences: KeyboardPreferences = KeyboardPreferences(),
         clipboard: KeyboardClipboard? = nil) {
        self.session = session
        self.preferences = preferences
        self.clipboard = clipboard ?? KeyboardClipboard()
        super.init(frame: frame)
        KeyboardCandidateTextMetrics.prepareFonts()
        session.setCandidatePresentationPreparation { KeyboardCandidateTextMetrics.prepare($0, first: $1) }
        heightFactor = CGFloat(preferences.heightFactor)
        KeyboardPalette.theme = preferences.theme
        session.updateIntelligence(ranking: preferences.candidateRanking, suggestionsEnabled: preferences.phraseSuggestions)
        session.setUndoesCommitOnBackspace(preferences.undoConversionOnBackspace)
        applyNeuralRetry()
        appliedPreferences = preferences.snapshot
        session.onCommittedEdits = { [weak self] batch in
            guard let self, batch.hostEpoch == self.session.hostEpoch else { return }
            self.apply(batch.edits)
        }
        session.onCandidatesChange = { [weak self] in
            guard let self else { return }
            self.publishPreedit()
            let publicationStartedAt = KeyboardPerformance.start()
            self.refresh()
            if let startedAt = self.session.candidateInitialRequestStartedAt,
               let token = self.stripButtons.first?.selectionToken {
                self.pendingCandidateTiming = (startedAt, token)
            }
            KeyboardPerformance.record(.candidatePublication, since: publicationStartedAt)
            KeyboardPerformance.record(.resultToCandidateUI, since: self.session.candidateResultReadyAt)
        }
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessibilityIdentifier = "vime.keyboard"
        insertSubview(skinCanvas, at: 0)
        addSubview(header)
        addSubview(keysContainer)
        addSubview(panelScroll)
        panelScroll.isHidden = true
        header.addSubview(brandButton)
        brandButton.setImage(KeyboardGlyphs.logo(), for: .normal)
        brandArtwork.contentMode = .scaleAspectFit; brandArtwork.isUserInteractionEnabled = false
        brandButton.addSubview(brandArtwork)
        brandButton.tintColor = UIColor(cgColor: VimeLogo.blue)
        brandButton.accessibilityIdentifier = "vime.brand.settings"
        brandButton.accessibilityLabel = String(localized: "键盘设置")
        brandButton.addTarget(self, action: #selector(toggleSettings), for: .touchUpInside)
        addSubview(globeButton)
        globeButton.tintColor = .label
        globeButton.setImage(Self.footerGlobe, for: .normal)
        globeButton.accessibilityLabel = String(localized: "切换系统键盘")
        globeButton.addTarget(self, action: #selector(switchKeyboard), for: .touchUpInside)
        header.addSubview(modeButton)
        header.addSubview(neuralStatusLabel)
        neuralStatusLabel.font = .systemFont(ofSize: 12)
        neuralStatusLabel.textColor = .secondaryLabel
        neuralStatusLabel.text = String(localized: "内存不足，暂用词典")
        neuralStatusLabel.accessibilityIdentifier = "vime.neural.status"
        neuralStatusLabel.isHidden = true
        modeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        modeButton.backgroundColor = KeyboardPalette.key
        modeButton.tintColor = .secondaryLabel
        modeButton.addTarget(self, action: #selector(toggleKana), for: .touchUpInside)
        modeButton.accessibilityLabel = String(localized: "切换平假名和片假名")
        header.addSubview(undoButton)
        undoButton.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        undoButton.accessibilityLabel = String(localized: "撤回刚才的删行")
        undoButton.accessibilityIdentifier = "vime.delete.undo"
        undoButton.addAction(UIAction { [weak self] _ in self?.apply([.undoLineDeletion]) }, for: .touchUpInside)
        header.addSubview(candidateScroll)
        candidateScroll.accessibilityIdentifier = "vime.candidates"
        configureScroll(candidateScroll)
        configureScroll(panelScroll)
        panelScroll.accessibilityIdentifier = "vime.candidates.panel"
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.addSubview(candidateRow)
        header.addSubview(quickCandidates)
        quickCandidates.onSelect = { [weak self] in self?.selectQuickCandidate($0) }
        header.addSubview(clipboardSuggestion)
        clipboardSuggestion.onPaste = { [weak self] text in
            guard let self, self.canUseClipboardSuggestion(text) else { return }
            self.playFeedback()
            self.insertClipboardText(text)
            self.clipboard.consume()
        }
        clipboardSuggestion.onDismiss = { [weak self] text in
            guard let self, self.canUseClipboardSuggestion(text) else { return }
            self.playFeedback()
            self.clipboard.consume()
        }
        self.clipboard.onChange = { [weak self] in
            guard let self else { return }
            if !self.clipboardActive || self.window == nil || !self.preferences.clipboardSuggestions || !self.hasFullAccess {
                self.clipboard.clear()
            }
            if self.panel == .clipboardHistory { self.reloadClipboardHistory() }
            self.refresh()
        }
        header.addSubview(expandButton)
        expandButton.tintColor = .secondaryLabel
        expandButton.backgroundColor = KeyboardPalette.key
        expandButton.addTarget(self, action: #selector(headerArrow), for: .touchUpInside)
        expandButton.accessibilityLabel = String(localized: "展开候选词")
        addSubview(divider)
        addSubview(oneHandedButton)
        oneHandedButton.isHidden = true
        oneHandedButton.accessibilityIdentifier = "vime.oneHanded.restore"
        oneHandedButton.accessibilityLabel = String(localized: "恢复全宽键盘")
        oneHandedButton.addTarget(self, action: #selector(leaveOneHandedMode), for: .touchUpInside)
        panelTitle.font = .systemFont(ofSize: 16, weight: .medium)
        panelTitle.accessibilityIdentifier = "vime.candidates.title"
        panelTitle.isUserInteractionEnabled = false
        header.addSubview(panelTitle)
        for (button, title, label, identifier, action) in [
            (shortenRange, String(localized: "缩短"), String(localized: "缩短转换范围"), "vime.segment.shorten", #selector(shortenConversion)),
            (lengthenRange, String(localized: "延长"), String(localized: "加长转换范围"), "vime.segment.lengthen", #selector(lengthenConversion)),
            (wholeRange, String(localized: "整句"), String(localized: "恢复整句转换"), "vime.segment.whole", #selector(wholeConversion))] {
            button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = identifier
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .touchUpInside)
            header.addSubview(button)
        }
        panelTitle.lineBreakMode = .byTruncatingMiddle
        panelScroll.delegate = self
        gestureHint.font = .systemFont(ofSize: 18, weight: .medium)
        gestureHint.textAlignment = .center
        gestureHint.isUserInteractionEnabled = false
        gestureHint.isHidden = true
        gestureHint.accessibilityIdentifier = "vime.gesture.hint"
        addSubview(gestureHint)
        addSubview(deletePrompt)
        deletePrompt.isHidden = true
        previewOverlay.isUserInteractionEnabled = false
        previewOverlay.accessibilityIdentifier = "vime.key.preview.overlay"
        previewOverlay.layer.zPosition = 1
        addSubview(previewOverlay)
        keysContainer.onGestureChange = { [weak self] gesture in
            guard let self else { return }
            if gesture == .horizontalCursor || gesture == .spaceCursor {
                self.confirmComposition()
                self.session.finishLearningFeedback()
                // A zero move starts a new caret gesture and resets its column.
                self.onEdit?([.moveCursor(horizontal: 0, vertical: 0)])
            }
            for row in self.rows { for (key, _) in row { key.alpha = gesture == .horizontalCursor || gesture == .spaceCursor ? 0 : 1 } }
            self.gestureHint.text = gesture == .spaceCursor ? String(localized: "上下左右移动光标") : String(localized: "左右移动光标")
            self.gestureHint.isHidden = gesture == nil || gesture == .deleteLine
            self.bringSubviewToFront(self.gestureHint)
        }
        keysContainer.onCursorMove = { [weak self] x, y in
            guard let self else { return }
            self.session.finishLearningFeedback()
            self.onEdit?([.moveCursor(horizontal: x, vertical: y)])
        }
        keysContainer.onDeletePressChange = { [weak self] held in
            guard let self else { return }
            self.deletePrompt.isHidden = !held
            self.layoutIfNeeded(); self.bringSubviewToFront(self.deletePrompt)
        }
        keysContainer.onDeleteArmedChange = { [weak self] in self?.deletePrompt.armed = $0 }
        keysContainer.onDeleteLine = { [weak self] in
            guard let self else { return }
            self.session.invalidateLearningFeedback()
            self.apply(self.session.confirmAll() + [.deleteToLineStart])
        }
        divider.isHidden = true
        for button in [brandButton, modeButton, undoButton, expandButton] {
            button.addTarget(self, action: #selector(toolbarFeedback), for: .touchDown)
        }
        configureGlobe()
        rebuildKeys()
        applyTheme()
        refresh()
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) {
            (view: KeyboardView, _: UITraitCollection) in
            view.traitCollection.performAsCurrent {
                let traits = view.session.inputTraits
                view.languageKey?.setImage(KeyboardGlyphs.language(active: traits.language, other: traits.alternateLanguage), for: .normal)
            }
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateClipboardMonitoring()
    }

    deinit { clipboardTimer?.invalidate() }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight(for: bounds.width)) }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, alpha >= 0.01, bounds.contains(point) else {
            KeyboardTouchDiagnostics.record("KeyboardView.hitTest", point: point, view: self, detail: "outside/hidden/disabled")
            return nil
        }
        // A layout switch can be followed by another touch before the next
        // display frame. Resolve against the new keys, never removed objects.
        layoutIfNeeded()
        if !header.isHidden, header.frame.contains(point) {
            // Visual circles stay small. Resolve their larger targets here so
            // neighboring controls never compete, and a miss cannot type a key.
            let controls = [globeButton, brandButton, undoButton, modeButton, expandButton, shortenRange, lengthenRange, wholeRange]
            let target = controls.filter { !$0.isHidden && $0.isEnabled && $0.alpha >= 0.01 }
                .filter { button in
                    let frame = button.convert(button.bounds, to: self)
                    return frame.insetBy(dx: -max(0, (44 - frame.width) / 2),
                        dy: -max(0, (44 - frame.height) / 2)).contains(point)
                }.min { lhs, rhs in
                    abs(lhs.center.x - point.x) < abs(rhs.center.x - point.x)
                }
            if let target { return target }
        }
        let hit = super.hitTest(point, with: event)
        // Real toolbar/candidate/globe controls keep their own interactions.
        // Empty space in the key plane routes to a key. The toolbar is reserved
        // for controls and must never insert a letter when a tap misses them.
        if !keysContainer.isHidden, (hit === self || hit === header || hit === keysContainer),
           keysContainer.resolvedKey(at: keysContainer.convert(point, from: self)) != nil {
            KeyboardTouchDiagnostics.record("KeyboardView.hitTest", point: point, view: self, result: keysContainer)
            return keysContainer
        }
        KeyboardTouchDiagnostics.record("KeyboardView.hitTest", point: point, view: self, result: hit)
        return hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Cancelling a delete during a page change can synchronously request
        // layout. Do not lay out the old rows using the new page's geometry.
        guard !rebuildingKeys else { return }
        skinCanvas.frame = bounds
        let width = bounds.width
        guard width > 0 else { return }
        let metrics = KeyboardMetrics(width: width, compact: compact, showsFooter: showsFooter,
            heightFactor: heightFactor, availableHeight: bounds.height, pad: pad)
        let scale = metrics.scale
        let xScale = width / 440
        let aligned = metrics.alignsToolbarToKeys
        let toolbarLeft = aligned ? metrics.contentLeft : 12 * xScale
        let headerHeight = metrics.headerHeight
        header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        let diameter = metrics.toolbarButtonDiameter
        let centerY = max(22, KeyboardMetrics.toolbarTopInset + diameter / 2)
        brandButton.frame = CGRect(x: metrics.showsToolbarGlobe ? metrics.leadingToolbarFrame(index: 1).minX : toolbarLeft,
            y: centerY - diameter / 2, width: diameter, height: diameter)
        brandArtwork.frame = brandButton.bounds.insetBy(dx: 2, dy: 2)
        brandButton.imageView?.isHidden = brandArtwork.image != nil
        modeButton.frame = metrics.trailingToolbarFrame(index: 1)
        undoButton.frame = metrics.trailingToolbarFrame(index: 2)
        neuralStatusLabel.frame = CGRect(x: brandButton.frame.maxX + 8, y: centerY - diameter / 2,
            width: max(0, undoButton.frame.minX - brandButton.frame.maxX - 16), height: diameter)
        expandButton.frame = metrics.trailingToolbarFrame(index: 0)
        for button in [undoButton, modeButton, expandButton] { button.layer.cornerRadius = diameter / 2 }
        // The iPad globe keeps its place beside every toolbar state.
        let stripLeft = metrics.showsToolbarGlobe ? metrics.leadingToolbarFrame(index: 0).midX + 22 + 2
            : aligned ? metrics.contentLeft : 4 * xScale
        candidateScroll.frame = CGRect(x: stripLeft, y: 3, width: expandButton.frame.midX - 22 - stripLeft,
            height: headerHeight - 6)
        if !candidateScroll.isHidden || !quickCandidates.isHidden {
            var left = candidateScroll.frame.minX
            if !brandButton.isHidden { left = brandButton.frame.midX + 22 + 2 }
            let right = candidateScroll.frame.maxX
            candidateScroll.frame = CGRect(x: left, y: candidateScroll.frame.minY,
                width: max(0, right - left), height: candidateScroll.frame.height)
        }
        let previewLeft = (brandButton.isHidden ? brandButton.frame.minX : brandButton.frame.maxX) + 8
        let previewRight = aligned ? metrics.contentRight : width - 12 * xScale
        clipboardSuggestion.frame = CGRect(x: previewLeft, y: brandButton.frame.minY,
            width: max(0, previewRight - previewLeft), height: diameter)
        quickCandidates.frame = candidateScroll.frame
        forgetPrompt?.frame = CGRect(x: toolbarLeft, y: 0, width: max(0, (aligned ? metrics.contentRight : width - 12 * xScale) - toolbarLeft),
            height: headerHeight)
        layoutCandidateStrip()
        // Range controls use full targets too; their clear backgrounds keep
        // the existing compact appearance while avoiding overlapping actions.
        // Text labels vary by language; each target is at least 44 pt wide.
        var rangeRight = expandButton.frame.midX - 22
        for control in [wholeRange, lengthenRange, shortenRange] {
            let width = max(44, ceil(control.intrinsicContentSize.width))
            control.frame = CGRect(x: rangeRight - 8 - width, y: centerY - 22, width: width, height: 44)
            rangeRight = control.frame.minX
        }
        let titleLeft = metrics.showsToolbarGlobe ? metrics.leadingToolbarFrame(index: 0).maxX + 12 : toolbarLeft
        let titleRight = shortenRange.isHidden ? expandButton.frame.midX - 22 : shortenRange.frame.minX
        panelTitle.frame = CGRect(x: titleLeft, y: centerY - diameter / 2,
            width: max(0, titleRight - 8 - titleLeft), height: diameter)
        divider.frame = CGRect(x: expandButton.frame.midX - 22, y: centerY - 12, width: 0.5, height: 24)
        if panel == .settings {
            panelTitle.frame = CGRect(x: brandButton.frame.maxX + 12, y: brandButton.frame.minY,
                width: max(0, expandButton.frame.minX - brandButton.frame.maxX - 24), height: diameter)
        }
        keysContainer.frame = bounds
        let body = CGRect(x: 0, y: headerHeight, width: width, height: metrics.contentHeight - headerHeight)
        gestureHint.frame = body
        panelScroll.frame = body
        symbolPanel?.compact = compact
        symbolPanel?.regular = metrics.regular
        symbolPanel?.frame = bounds
        previewOverlay.frame = bounds
        settingsPanel?.frame = body
        // Lists keep a readable width on an iPad rather than spanning the screen.
        let listInset = metrics.regular ? max(metrics.contentLeft, (width - Self.padListWidth) / 2) : nil
        clipboardHistoryPanel?.headerHeight = headerHeight
        clipboardHistoryPanel?.contentMargins = UIEdgeInsets(top: 0, left: listInset ?? (compact ? metrics.contentLeft : 12),
            bottom: 0, right: listInset ?? (compact ? width - metrics.contentRight : 12))
        clipboardHistoryPanel?.frame = CGRect(x: 0, y: 0, width: width, height: metrics.contentHeight)
        settingsPanel?.setContentMargins(left: listInset ?? (compact ? metrics.contentLeft : 12),
            right: listInset ?? (compact ? width - metrics.contentRight : 12))
        let keyGrid = KeyGridLayout(size: bounds.size, compact: compact, pad: pad, showsFooter: showsFooter,
            heightFactor: heightFactor, page: page, numberPad: usesNumberPad, kana: kanaLayoutActive,
            oneHanded: activeOneHandedSide, generation: keyGridGeneration)
        if keyGrid != laidOutKeyGrid {
            laidOutKeyGrid = keyGrid
            layoutKeyGrid(metrics: metrics)
        }
        layoutOneHandedButton(keysTop: headerHeight, keysBottom: metrics.contentHeight)
        globeButton.isHidden = !showsFooter || panel == .symbols || (metrics.showsToolbarGlobe && header.isHidden)
        if metrics.showsToolbarGlobe {
            globeButton.frame = metrics.leadingToolbarFrame(index: 0)
            globeButton.layer.cornerRadius = diameter / 2
        } else {
            globeButton.frame = CGRect(x: 22 * xScale, y: metrics.contentHeight + (compact ? 0 : 17 * scale), width: 40 * scale, height: compact ? 34 : 40 * scale)
            globeButton.layer.cornerRadius = 0
        }
        globeButton.backgroundColor = metrics.showsToolbarGlobe ? KeyboardPalette.key : .clear
        let globe = metrics.showsToolbarGlobe ? Self.toolbarGlobe : Self.footerGlobe
        if globeButton.image(for: .normal) !== globe { globeButton.setImage(globe, for: .normal) }
        globeButton.tintColor = metrics.showsToolbarGlobe ? .secondaryLabel : .label
        bringSubviewToFront(header)
        if metrics.showsToolbarGlobe { bringSubviewToFront(globeButton) }
        if !deletePrompt.isHidden { bringSubviewToFront(deletePrompt) }
        // Candidate refreshes and layout changes must never raise a sibling
        // above held key previews. This overlay also stays transparent to input.
        bringSubviewToFront(previewOverlay)
        let panelLeft: CGFloat = aligned ? metrics.contentLeft : 8
        let panelWidth: CGFloat = aligned ? metrics.contentWidth : width - 20
        let columns = metrics.regular ? max(5, Int(panelWidth / 150)) : width > 600 ? 5 : 3
        let cellWidth = aligned ? (panelWidth + 8) / CGFloat(columns) : panelWidth / CGFloat(columns)
        for (index, button) in panelCandidates.enumerated() {
            button.frame = CGRect(x: panelLeft + CGFloat(index % columns) * cellWidth, y: CGFloat(index / columns) * 46,
                width: cellWidth - (aligned ? 8 : 5), height: 41)
        }
        panelScroll.contentSize = CGSize(width: width, height: CGFloat((panelCandidates.count + columns - 1) / columns) * 46)
        if let timing = pendingCandidateTiming {
            pendingCandidateTiming = nil
            if window != nil, panel == .keyboard || panel == .candidates,
               session.candidatesAreCurrent, stripButtons.first?.selectionToken == timing.token {
                KeyboardPerformance.record(.inputToCandidateInteractive, since: timing.startedAt)
            }
        }
    }

    static let footerGlobe = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 27, weight: .regular))
    static let toolbarGlobe = UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
    /// Settings and clipboard history stay this wide on an iPad.
    static let padListWidth: CGFloat = 640

    func apply(_ edits: [KeyboardEdit]) {
        if !edits.isEmpty, let onEditsAndPreeditChange {
            onEditsAndPreeditChange(edits, session.markedText)
        } else {
            if !edits.isEmpty { onEdit?(edits) }
            publishPreedit()
        }
        if !session.isComposing && panel == .candidates { panel = .keyboard }
        else if !edits.isEmpty && panel == .candidates {
            // A committed prefix starts a new suffix candidate list. Keeping
            // the old page can hide its leading candidates above the viewport.
            panelLimit = 40
            panelScroll.setContentOffset(.zero, animated: false)
        }
        if !edits.isEmpty { session.didApplyEdits(edits) }
        KeyboardPerformance.record(.typeToMarked, since: session.takeInputTiming())
        refresh()
        if !edits.isEmpty { updateAutoCapitalization() }
    }

    func publishPreedit() {
        onPreeditChange?(session.markedText)
    }

    var leftContextProvider: (() -> String?)? {
        get { session.leftContextProvider }
        set { session.leftContextProvider = newValue }
    }

    var learningContextProvider: (() -> KeyboardLearningContext?)? {
        get { session.learningContextProvider }
        set { session.learningContextProvider = newValue }
    }

    func hostContextDidChange() { session.didApplyEdits([]); refresh(); updateAutoCapitalization() }
    func finishLearningFeedback() { session.finishLearningFeedback() }
    func prepareForInput() { session.prepareForInput() }

    func resetComposition() {
        emojiSearchActive = false
        session.reset()
        if panel == .candidates { panel = .keyboard }
        onPreeditChange?(nil)
        refresh()
    }

    func confirmComposition() { apply(session.confirmAll()) }

    func stopInteractions() {
        keysContainer.cancelAllPresses()
        for row in rows { for (key, _) in row { key.stopTracking() } }
    }

    func releaseInactiveResources() {
        setClipboardActive(false)
        session.releaseInactiveResources()
        spareCandidateButtons.removeAll(keepingCapacity: false)
        sparePanelButtons.removeAll(keepingCapacity: false)
        symbolPanel?.isHidden = true // Cancel this panel's preparation; retain the bounded shared bitmaps.
        symbolPanel?.removeFromSuperview(); symbolPanel = nil
        impactGenerators.removeAll(keepingCapacity: false)
        if panel == .symbols { panel = .keyboard }
    }

    func handleMemoryPressure() {
        clipboard.clear()
        clipboardHistoryPanel?.present([])
        if panel == .clipboardHistory { panel = .keyboard }
        KeyboardEmojiImages.clear()
        spareCandidateButtons.removeAll(keepingCapacity: false)
        sparePanelButtons.removeAll(keepingCapacity: false)
        if panel != .symbols { symbolPanel?.isHidden = true; symbolPanel?.removeFromSuperview(); symbolPanel = nil }
        impactGenerators.removeAll(keepingCapacity: false)
        session.handleMemoryPressure()
        refresh()
    }
}
