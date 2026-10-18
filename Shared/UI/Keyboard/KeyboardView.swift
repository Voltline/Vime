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
    private var appliedPreferences: KeyboardPreferences.Snapshot?
    private let skinCanvas = KeyboardSkinCanvas()
    private let brandArtwork = UIImageView()
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
        if next.clipboardSuggestions != previous?.clipboardSuggestions { updateClipboardMonitoring() }
        if next.nineKeyNumbers != previous?.nineKeyNumbers || next.prolongedKey != previous?.prolongedKey {
            rebuildKeys()
        }
        if next.numberSymbols != previous?.numberSymbols { numberSymbolRail?.present(next.numberSymbols) }
        if next.previews != previous?.previews {
            for key in letterKeys { key.showsPreview = next.previews }
        }
        if next.theme != previous?.theme || next.customSkinID != previous?.customSkinID || next.skinRevision != previous?.skinRevision { applyTheme() }
        settingsPanel?.update(hasFullAccess: hasFullAccess, neuralPaused: session.neuralModeSuspendedForMemoryPressure)
    }
    weak var inputModeListTarget: AnyObject? { didSet { configureGlobe() } }
    var inputModeListAction: Selector? { didSet { configureGlobe() } }
    var needsGlobe = false { didSet { if oldValue != needsGlobe { configureGlobe() } } }
    var showsFooter = true { didSet { if oldValue != showsFooter { setNeedsLayout(); invalidateIntrinsicContentSize(); onHeightChange?() } } }
    var compact = false { didSet { if oldValue != compact { setNeedsLayout(); invalidateIntrinsicContentSize(); onHeightChange?() } } }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        KeyboardMetrics(width: width > 0 ? width : 440, compact: compact, showsFooter: showsFooter, heightFactor: heightFactor).height
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

    private enum Page { case letters, numbers, symbols }
    private func shouldConvertNumber(_ text: String) -> Bool {
        session.inputTraits.convertsNumbers && keyboardType == .default
            && !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
    private func composesNumberPageInput(_ text: String) -> Bool {
        if shouldConvertNumber(text) { return true }
        let mark = session.markedText?.text ?? ""
        let numeric = !mark.isEmpty && mark.allSatisfy { "0123456789０１２３４５６７８９.．".contains($0) }
        return session.isComposing && !numeric && session.inputTraits.compositionInputSymbols.contains(text)
    }
    private let session: any KeyboardInputSession
    private var displayedCandidates: [CandidatePresentation] = []
    private var displayedSelection: Int?
    private var pendingCandidateTiming: (startedAt: TimeInterval, token: CandidateSelectionToken)?
    private var page: Page = .letters
    private var shifted = false
    private var capsLocked = false
    private var lastShiftTap: TimeInterval = 0
    private enum Panel { case keyboard, candidates, settings, symbols, clipboardHistory }
    private var panel: Panel = .keyboard {
        didSet {
            if (oldValue == .candidates) != (panel == .candidates) {
                session.setExpandedCandidates(panel == .candidates)
            }
        }
    }
    private var previewsEnabled: Bool { preferences.previews }
    private var impactGenerators: [Int: UIImpactFeedbackGenerator] = [:]
    private let header = UIView()
    private let candidateScroll = UIScrollView()
    private let candidateRow = UIView()
    private let quickCandidates = KeyboardQuickCandidateStrip()
    private let clipboardSuggestion = ClipboardSuggestionView()
    private let clipboard: KeyboardClipboard
    private var clipboardTimer: Timer?
    private var clipboardActive = true
    private var clipboardHistoryPanel: ClipboardHistoryPanel?
    private var historyRequest = 0
    private var stripButtons: [KeyboardCandidateButton] = []
    private var spareCandidateButtons: [KeyboardCandidateButton] = []
    private var displayedLanguage: KeyboardInputLanguage?
    private var displayedAlternateLanguage: KeyboardInputLanguage?
    private let brandButton = UIButton(type: .custom)
    private let globeButton = UIButton(type: .custom)
    private let modeButton = UIButton(type: .system)
    private let neuralStatusLabel = UILabel()
    private let undoButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)
    private let divider = UIView()
    private let panelTitle = UILabel()
    private let shortenRange = UIButton(type: .system)
    private let lengthenRange = UIButton(type: .system)
    private let wholeRange = UIButton(type: .system)
    private var panelLimit = 40
    private let gestureHint = UILabel()
    private let deletePrompt = KeyboardDeletePrompt()
    private let previewOverlay = UIView()
    private let keysContainer = KeyboardTouchSurface()
    private let panelScroll = UIScrollView()
    private var panelCandidates: [KeyboardCandidateButton] = []
    private var sparePanelButtons: [KeyboardCandidateButton] = []
    private var settingsPanel: KeyboardSettingsPanel?
    private var symbolPanel: KeyboardSymbolPanel?
    private var rows: [[(KeyboardKey, CGFloat)]] = []
    private var rebuildingKeys = false
    private var letterKeys: [KeyboardKey] = []
    private var shiftKey: KeyboardKey?
    private var spaceKey: KeyboardKey?
    private var languageKey: KeyboardKey?
    private var returnKey: KeyboardKey?
    private var numberSymbolRail: KeyboardNumberSymbolRail?
    private var numberBackKey: KeyboardKey?
    private var usesNumberPad: Bool { page == .numbers && preferences.nineKeyNumbers }

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
        heightFactor = CGFloat(preferences.heightFactor)
        KeyboardPalette.theme = preferences.theme
        session.updateIntelligence(ranking: preferences.candidateRanking, suggestionsEnabled: preferences.phraseSuggestions)
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
        brandButton.backgroundColor = KeyboardPalette.key
        brandButton.setImage(KeyboardGlyphs.logo(), for: .normal)
        brandArtwork.contentMode = .scaleAspectFit; brandArtwork.isUserInteractionEnabled = false
        brandButton.addSubview(brandArtwork)
        brandButton.tintColor = UIColor(cgColor: VimeLogo.blue)
        brandButton.accessibilityIdentifier = "vime.brand.settings"
        brandButton.accessibilityLabel = "键盘设置"
        brandButton.addTarget(self, action: #selector(toggleSettings), for: .touchUpInside)
        addSubview(globeButton)
        globeButton.tintColor = .label
        globeButton.setImage(UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 27, weight: .regular)), for: .normal)
        globeButton.accessibilityLabel = "切换系统键盘"
        globeButton.addTarget(self, action: #selector(switchKeyboard), for: .touchUpInside)
        header.addSubview(modeButton)
        header.addSubview(neuralStatusLabel)
        neuralStatusLabel.font = .systemFont(ofSize: 12)
        neuralStatusLabel.textColor = .secondaryLabel
        neuralStatusLabel.text = "内存不足，暂用词典"
        neuralStatusLabel.accessibilityIdentifier = "vime.neural.status"
        neuralStatusLabel.isHidden = true
        modeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        modeButton.backgroundColor = KeyboardPalette.key
        modeButton.tintColor = .secondaryLabel
        modeButton.addTarget(self, action: #selector(toggleKana), for: .touchUpInside)
        modeButton.accessibilityLabel = "切换平假名和片假名"
        header.addSubview(undoButton)
        undoButton.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        undoButton.accessibilityLabel = "撤回刚才的删行"
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
        expandButton.accessibilityLabel = "展开候选词"
        addSubview(divider)
        panelTitle.font = .systemFont(ofSize: 16, weight: .medium)
        panelTitle.accessibilityIdentifier = "vime.candidates.title"
        panelTitle.isUserInteractionEnabled = false
        header.addSubview(panelTitle)
        for (button, title, identifier, action) in [
            (shortenRange, "−", "vime.segment.shorten", #selector(shortenConversion)),
            (lengthenRange, "+", "vime.segment.lengthen", #selector(lengthenConversion)),
            (wholeRange, "整句", "vime.segment.whole", #selector(wholeConversion))] {
            button.setTitle(title, for: .normal)
            button.accessibilityIdentifier = identifier
            button.accessibilityLabel = title == "−" ? "缩短转换范围" : title == "+" ? "加长转换范围" : "恢复整句转换"
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
            self.gestureHint.text = gesture == .spaceCursor ? "上下左右移动光标" : "左右移动光标"
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
                view.languageKey?.setImage(KeyboardGlyphs.language(primary: traits.language.glyph, secondary: traits.alternateLanguage.glyph), for: .normal)
            }
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateClipboardMonitoring()
    }

    func setClipboardActive(_ active: Bool) {
        clipboardActive = active
        updateClipboardMonitoring()
    }

    private func updateClipboardMonitoring() {
        let active = clipboardActive && window != nil && preferences.clipboardSuggestions && hasFullAccess
        guard active else {
            if clipboardTimer != nil {
                NotificationCenter.default.removeObserver(self, name: UIPasteboard.changedNotification, object: nil)
                clipboardTimer?.invalidate(); clipboardTimer = nil
            }
            historyRequest += 1
            clipboardHistoryPanel?.present([])
            if panel == .clipboardHistory { panel = .keyboard }
            if preferences.clipboardSuggestions { clipboard.clear() }
            else { clipboard.disable() }
            refresh()
            return
        }
        if clipboardTimer == nil {
            NotificationCenter.default.addObserver(self, selector: #selector(checkClipboard),
                name: UIPasteboard.changedNotification, object: nil)
            let timer = Timer(timeInterval: KeyboardClipboard.fallbackInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkClipboard() }
            }
            timer.tolerance = 0.1
            clipboardTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        checkClipboard()
    }

    @objc private func checkClipboard() {
        guard clipboardActive, window != nil, preferences.clipboardSuggestions, hasFullAccess else {
            updateClipboardMonitoring(); return
        }
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        if !clipboardActive || window == nil || !preferences.clipboardSuggestions || !hasFullAccess {
            updateClipboardMonitoring()
        }
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
        let hit = super.hitTest(point, with: event)
        // Real toolbar/candidate/globe controls keep their own interactions.
        // Any otherwise empty keyboard surface routes to a key, including the
        // blank space above the first row and below the last row.
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
            heightFactor: heightFactor, availableHeight: bounds.height)
        let scale = metrics.scale
        let xScale = width / 440
        let headerHeight = metrics.headerHeight
        header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        let diameter = metrics.toolbarButtonDiameter
        let centerY = KeyboardMetrics.toolbarTopInset + diameter / 2
        brandButton.frame = CGRect(x: compact ? metrics.contentLeft : 12 * xScale,
            y: centerY - diameter / 2, width: diameter, height: diameter)
        brandArtwork.frame = brandButton.bounds.insetBy(dx: 2, dy: 2)
        brandButton.imageView?.isHidden = brandArtwork.image != nil
        modeButton.frame = metrics.trailingToolbarFrame(index: 1)
        undoButton.frame = metrics.trailingToolbarFrame(index: 2)
        neuralStatusLabel.frame = CGRect(x: brandButton.frame.maxX + 8, y: centerY - diameter / 2,
            width: max(0, undoButton.frame.minX - brandButton.frame.maxX - 16), height: diameter)
        expandButton.frame = metrics.trailingToolbarFrame(index: 0)
        for button in [brandButton, undoButton, modeButton, expandButton] { button.layer.cornerRadius = diameter / 2 }
        candidateScroll.frame = CGRect(x: compact ? metrics.contentLeft : 4 * xScale,
            y: centerY - (compact ? 13 : 17 * scale),
            width: compact ? expandButton.frame.minX - KeyboardMetrics.toolbarGap - metrics.contentLeft : width - 55 * xScale,
            height: compact ? 26 : 34 * scale)
        if !candidateScroll.isHidden || !quickCandidates.isHidden {
            var left = candidateScroll.frame.minX
            if !brandButton.isHidden { left = brandButton.frame.maxX + 4 }
            let right = candidateScroll.frame.maxX
            candidateScroll.frame = CGRect(x: left, y: candidateScroll.frame.minY,
                width: max(0, right - left), height: candidateScroll.frame.height)
        }
        let previewLeft = (brandButton.isHidden ? brandButton.frame.minX : brandButton.frame.maxX) + 8
        let previewRight = compact ? metrics.contentRight : width - 12 * xScale
        clipboardSuggestion.frame = CGRect(x: previewLeft, y: brandButton.frame.minY,
            width: max(0, previewRight - previewLeft), height: diameter)
        quickCandidates.frame = candidateScroll.frame
        layoutCandidateStrip()
        panelTitle.frame = CGRect(x: 12 * xScale, y: 0, width: width - 185 * xScale, height: headerHeight)
        shortenRange.frame = CGRect(x: width - 172 * xScale, y: 0, width: 40 * xScale, height: headerHeight)
        lengthenRange.frame = CGRect(x: width - 132 * xScale, y: 0, width: 40 * xScale, height: headerHeight)
        wholeRange.frame = CGRect(x: width - 92 * xScale, y: 0, width: 42 * xScale, height: headerHeight)
        divider.frame = CGRect(x: width - 51 * xScale, y: centerY - 12 * scale, width: 0.5, height: 24 * scale)
        if compact {
            let gap = KeyboardMetrics.toolbarGap
            wholeRange.frame = CGRect(x: expandButton.frame.minX - gap - 44, y: KeyboardMetrics.toolbarTopInset, width: 44, height: diameter)
            lengthenRange.frame = CGRect(x: wholeRange.frame.minX - gap - diameter, y: KeyboardMetrics.toolbarTopInset, width: diameter, height: diameter)
            shortenRange.frame = CGRect(x: lengthenRange.frame.minX - gap - diameter, y: KeyboardMetrics.toolbarTopInset, width: diameter, height: diameter)
            let titleRight = shortenRange.isHidden ? expandButton.frame.minX : shortenRange.frame.minX
            panelTitle.frame = CGRect(x: metrics.contentLeft, y: KeyboardMetrics.toolbarTopInset,
                width: max(0, titleRight - gap - metrics.contentLeft), height: diameter)
            divider.frame = CGRect(x: expandButton.frame.minX - gap / 2, y: centerY - 12, width: 0.5, height: 24)
        }
        if panel == .settings {
            panelTitle.frame = CGRect(x: brandButton.frame.maxX + 12, y: brandButton.frame.minY,
                width: max(0, expandButton.frame.minX - brandButton.frame.maxX - 24), height: diameter)
        }
        keysContainer.frame = bounds
        let body = CGRect(x: 0, y: headerHeight, width: width, height: metrics.contentHeight - headerHeight)
        gestureHint.frame = body
        panelScroll.frame = body
        symbolPanel?.compact = compact
        symbolPanel?.frame = bounds
        previewOverlay.frame = bounds
        settingsPanel?.frame = body
        clipboardHistoryPanel?.headerHeight = headerHeight
        clipboardHistoryPanel?.contentMargins = UIEdgeInsets(top: 0, left: compact ? metrics.contentLeft : 12,
            bottom: 0, right: compact ? width - metrics.contentRight : 12)
        clipboardHistoryPanel?.frame = CGRect(x: 0, y: 0, width: width, height: metrics.contentHeight)
        settingsPanel?.setContentMargins(left: compact ? metrics.contentLeft : 12,
            right: compact ? width - metrics.contentRight : 12)
        for (rowIndex, row) in rows.enumerated() {
            for (column, pair) in row.enumerated() {
                if page == .numbers && preferences.nineKeyNumbers {
                    pair.0.frame = metrics.numberPadFrame(row: rowIndex, column: column + (rowIndex < 3 ? 1 : 0))
                } else {
                    pair.0.frame = metrics.frame(row: rowIndex, column: column, letters: page == .letters,
                                                prolonged: rowIndex == 1 && row.count == 10)
                }
                pair.0.layer.cornerRadius = 6.2 * scale
                // Compact phone keys are shorter despite the wider viewport.
                // Typography follows their height rather than landscape width.
                let textScale = compact ? scale : min(scale, metrics.keyHeight / 46.5)
                var fontSize: CGFloat = compact ? (rowIndex == 3 ? 13 : 18)
                    : (rowIndex == 3 ? 15 : 21) * textScale
                if usesNumberPad {
                    let isDigit = Int(pair.0.title(for: .normal) ?? "") != nil
                    fontSize = compact ? (isDigit ? 18 : rowIndex == 3 ? 13 : 15)
                        : (isDigit ? 20 : rowIndex == 3 ? 14 : 16) * textScale
                    pair.0.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: compact ? 16 : 18 * textScale),
                        forImageIn: .normal)
                }
                pair.0.hintLabel.font = .systemFont(ofSize: compact ? 8 : 9 * textScale)
                pair.0.titleLabel?.font = .systemFont(ofSize: fontSize)
                pair.0.applySkinMetrics(size: fontSize, scale: textScale)
            }
        }
        if usesNumberPad {
            let top = metrics.numberPadFrame(row: 0, column: 0)
            let bottom = metrics.numberPadFrame(row: 2, column: 0)
            numberSymbolRail?.frame = top.union(bottom)
            numberSymbolRail?.scale = scale
            numberSymbolRail?.layoutIfNeeded()
        }
        updateTouchBounds(metrics: metrics)
        if let key = rows.flatMap({ $0 }).first(where: { $0.0.repeats })?.0 {
            let promptWidth = 112 * scale
            let h = metrics.keyHeight + 10 * scale
            deletePrompt.frame = CGRect(x: max(0, key.frame.maxX - promptWidth),
                y: max(metrics.headerHeight, key.frame.minY - h - 6 * scale), width: promptWidth, height: h)
        }
        globeButton.isHidden = !showsFooter || panel == .symbols
        globeButton.frame = CGRect(x: 22 * xScale, y: metrics.contentHeight + (compact ? 0 : 17 * scale), width: 40 * scale, height: compact ? 34 : 40 * scale)
        bringSubviewToFront(header)
        if !deletePrompt.isHidden { bringSubviewToFront(deletePrompt) }
        // Candidate refreshes and layout changes must never raise a sibling
        // above held key previews. This overlay also stays transparent to input.
        bringSubviewToFront(previewOverlay)
        let columns = width > 600 ? 5 : 3
        let panelLeft: CGFloat = compact ? metrics.contentLeft : 8
        let panelWidth: CGFloat = compact ? metrics.contentWidth : width - 20
        let cellWidth = compact ? (panelWidth + 8) / CGFloat(columns) : panelWidth / CGFloat(columns)
        for (index, button) in panelCandidates.enumerated() {
            button.frame = CGRect(x: panelLeft + CGFloat(index % columns) * cellWidth, y: CGFloat(index / columns) * 46,
                width: cellWidth - (compact ? 8 : 5), height: 41)
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

    private func updateTouchBounds(metrics: KeyboardMetrics) {
        var regions: [KeyboardTouchSurface.Region] = []
        for (rowIndex, row) in rows.enumerated() {
            guard let first = row.first?.0 else { continue }
            let top = rowIndex == 0
                ? 0
                : (rows[rowIndex - 1][0].0.frame.maxY + first.frame.minY) / 2
            let bottom = rowIndex == rows.count - 1
                ? bounds.height
                : (first.frame.maxY + rows[rowIndex + 1][0].0.frame.minY) / 2
            for (column, pair) in row.enumerated() {
                let key = pair.0
                // Boundaries lie in the gaps, never inside a painted key. This
                // respects wide utility keys as well as staggered letter rows.
                let leading = usesNumberPad && rowIndex < 3
                    ? (metrics.numberPadFrame(row: rowIndex, column: 0).maxX + first.frame.minX) / 2 : 0
                let left = column == 0 ? leading : (row[column - 1].0.frame.maxX + key.frame.minX) / 2
                let right = column == row.count - 1 ? bounds.width : (key.frame.maxX + row[column + 1].0.frame.minX) / 2
                key.touchBounds = CGRect(x: left - key.frame.minX, y: top - key.frame.minY,
                                         width: right - left, height: bottom - top)
                regions.append(.init(key: key, body: key.frame,
                                     cell: CGRect(x: left, y: top, width: right - left, height: bottom - top)))
            }
        }
        keysContainer.regions = regions
        keysContainer.scale = metrics.scale
    }

    private func key(_ title: String, utility: Bool = false, weight: CGFloat = 1, action: @escaping () -> Void) -> (KeyboardKey, CGFloat) {
        let button = KeyboardKey(title: title)
        button.previewContainer = previewOverlay
        button.action = action
        button.feedback = { [weak self] in self?.playFeedback() }
        if utility {
            button.isUtility = true
            button.fillColor = KeyboardPalette.utility
            button.titleLabel?.font = .systemFont(ofSize: 16)
        }
        keysContainer.addSubview(button)
        return (button, weight)
    }

    private func symbol(_ name: String, label: String, weight: CGFloat, action: @escaping () -> Void) -> (KeyboardKey, CGFloat) {
        let button = KeyboardKey(symbol: name)
        button.previewContainer = previewOverlay
        button.accessibilityLabel = label
        button.isUtility = true
        button.fillColor = KeyboardPalette.utility
        button.action = action
        button.feedback = { [weak self] in self?.playFeedback() }
        keysContainer.addSubview(button)
        return (button, weight)
    }

    private func rebuildKeys() {
        rebuildingKeys = true
        defer { rebuildingKeys = false; setNeedsLayout() }
        keysContainer.cancelAllPresses()
        keysContainer.regions = []
        for row in rows { for (button, _) in row { button.stopTracking(); button.removeFromSuperview() } }
        rows = []
        letterKeys = []
        shiftKey = nil
        spaceKey = nil
        languageKey = nil
        returnKey = nil
        numberBackKey = nil
        if page == .letters {
            for letters in ["qwertyuiop", "asdfghjkl", "zxcvbnm"] {
                var row: [(KeyboardKey, CGFloat)] = []
                if letters == "zxcvbnm" {
                    let shift = symbol("shift", label: "切换大小写", weight: 1.35) { [weak self] in self?.shift() }
                    shiftKey = shift.0
                    row.append(shift)
                }
                for character in letters {
                    let value = String(character)
                    let item = key(value.uppercased()) { [weak self] in
                        guard let self else { return }
                        KeyboardPerformance.record(.touchUpToType, since: self.keysContainer.releaseStartedAt)
                        self.apply(self.session.type(self.shifted && self.session.inputTraits.isEnglish ? value.uppercased() : value))
                        if self.shifted && !self.capsLocked { self.shifted = false; self.updateKeyLabels() }
                    }
                    item.0.showsPreview = previewsEnabled
                    item.0.accessibilityIdentifier = "vime.key." + value
                    item.0.hint = Self.letterHints[value]
                    item.0.alternateTitle = Self.letterHints[value]
                    item.0.alternateAction = { [weak self] in
                        guard let self, let hint = Self.letterHints[value] else { return }
                        self.insertSymbol(hint)
                    }
                    letterKeys.append(item.0)
                    row.append(item)
                }
                if letters == "zxcvbnm" { row.append(deleteKey(weight: 1.35)) }
                if letters == "asdfghjkl", preferences.prolongedKey, let prolongedInput = session.inputTraits.prolongedInput {
                    let prolonged = key(prolongedInput) { [weak self] in
                        guard let self else { return }
                        self.apply(self.session.type(prolongedInput))
                    }
                    prolonged.0.accessibilityLabel = "长音符号"
                    prolonged.0.accessibilityIdentifier = "vime.key.prolonged"
                    row.append(prolonged)
                }
                rows.append(row)
            }
        } else if page == .numbers && preferences.nineKeyNumbers {
            if numberSymbolRail == nil {
                let rail = KeyboardNumberSymbolRail()
                rail.onSelect = { [weak self] symbol in
                    guard let self, self.usesNumberPad, self.panel == .keyboard else { return }
                    self.playFeedback()
                    if self.composesNumberPageInput(symbol) { self.apply(self.session.type(symbol)) }
                    else { self.insertSymbol(symbol) }
                }
                rail.onEdit = { [weak self] in
                    guard let self, self.panel == .keyboard, self.usesNumberPad else { return }
                    self.stopInteractions()
                    self.onOpenNumberSymbolSettings?()
                }
                numberSymbolRail = rail
                addSubview(rail)
            }
            numberSymbolRail?.present(preferences.numberSymbols)
            let values = [["1", "2", "3", "删除"],
                          ["4", "5", "6", "空格"],
                          ["7", "8", "9", "表情"],
                          ["ABC", "符号", "0", ".", "换行"]]
            for (r, values) in values.enumerated() {
                rows.append(values.map { value in
                    if value == "删除" { return deleteKey(weight: 1) }
                    if value == "表情" {
                        let item = symbol("face.smiling", label: "表情", weight: 1) { [weak self] in self?.toggleEmoji() }
                        item.0.accessibilityIdentifier = "vime.number.emoji"
                        return item
                    }
                    let item = key(value, utility: ["ABC", "符号", "空格", "换行"].contains(value)) { [weak self] in
                        guard let self else { return }
                        switch value {
                        case "ABC": self.page = .letters; self.rebuildKeys()
                        case "空格": self.apply(self.session.insertLiteral(" "))
                        case "符号": self.openSymbolPanel(mode: .symbols)
                        case "换行": self.apply(self.session.enter())
                        default:
                            let composes = self.composesNumberPageInput(value)
                            if composes { self.apply(self.session.type(value)) } else { self.insertSymbol(value) }
                        }
                    }
                    item.0.accessibilityIdentifier = "vime.number." + value
                    if value == "ABC" { numberBackKey = item.0 }
                    if r == 3 && value == "换行" {
                        returnKey = item.0; item.0.accessibilityIdentifier = "vime.key.return"
                    }
                    if value == "空格" {
                        spaceKey = item.0; item.0.accessibilityIdentifier = "vime.key.space"
                    }
                    return item
                })
            }
            applyKeySkins(); refresh(); setNeedsLayout(); return
        } else {
            let values = page == .numbers
                ? [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""], ["。", "、", "？", "！", "'", "ー", "・"]]
                : [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "$", "€", "£", "・"], ["「", "」", "『", "』", "…", "〜", "々"]]
            for (index, values) in values.enumerated() {
                var row = values.map { value in
                    let item = key(value) { [weak self] in
                        guard let self else { return }
                        if self.composesNumberPageInput(value) {
                            self.apply(self.session.type(value))
                        } else {
                            self.insertSymbol(value)
                        }
                    }
                    item.0.titleLabel?.font = .systemFont(ofSize: 21)
                    return item
                }
                if index == 2 {
                    row.insert(key(page == .numbers ? "#+=" : "123", utility: true, weight: 1.4) { [weak self] in
                        guard let self else { return }
                        self.page = self.page == .numbers ? .symbols : .numbers
                        self.rebuildKeys()
                    }, at: 0)
                    row.append(deleteKey(weight: 1.4))
                }
                rows.append(row)
            }
        }
        var bottom = [key(page == .letters ? "123" : "ABC", utility: true, weight: 1.25) { [weak self] in
            guard let self else { return }
            self.page = self.page == .letters ? .numbers : .letters
            self.rebuildKeys()
        }]
        let emoji = symbol("face.smiling", label: "表情", weight: 1) { [weak self] in self?.toggleEmoji() }
        bottom.append(emoji)
        let comma = key(page == .letters ? "," : "符号", utility: page != .letters, weight: 1) { [weak self] in
            guard let self else { return }
            if self.page != .letters { self.openSymbolPanel(mode: .symbols); return }
            self.apply(self.session.insertLiteral(self.session.inputTraits.comma))
        }
        comma.0.accessibilityIdentifier = page == .letters ? "vime.key.comma" : "vime.key.symbols"
        comma.0.hint = page == .letters ? "°" : nil
        comma.0.alternateTitle = page == .letters ? session.inputTraits.period : nil
        comma.0.alternateAction = { [weak self] in
            guard let self else { return }
            self.apply(self.session.insertLiteral(self.session.inputTraits.period))
        }
        bottom.append(comma)
        let space = key("", weight: 1) { [weak self] in
            guard let self else { return }
            self.apply(self.session.space())
        }
        space.0.accessibilityLabel = "空格，转换候选"
        space.0.accessibilityIdentifier = "vime.key.space"
        spaceKey = space.0
        bottom.append(space)
        let language = key("", weight: 1) { [weak self] in
            guard let self else { return }
            self.apply(self.session.toggleEnglish())
            self.shifted = false
            self.capsLocked = false
            self.rebuildKeys()
        }
        language.0.setImage(KeyboardGlyphs.language(primary: session.inputTraits.language.glyph,
                                                 secondary: session.inputTraits.alternateLanguage.glyph), for: .normal)
        languageKey = language.0
        language.0.accessibilityLabel = session.inputTraits.languageSwitchAccessibilityLabel
        language.0.accessibilityIdentifier = "vime.key.language"
        bottom.append(language)
        let enter = key("换行", weight: 1.55) { [weak self] in
            guard let self else { return }
            self.apply(self.session.enter())
        }
        enter.0.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        enter.0.fillColor = KeyboardPalette.utility
        enter.0.setTitleColor(.label, for: .normal)
        enter.0.accessibilityIdentifier = "vime.key.return"
        returnKey = enter.0
        bottom.append(enter)
        rows.append(bottom)
        applyKeySkins()
        updateKeyLabels()
        refresh()
        setNeedsLayout()
    }

    private func deleteKey(weight: CGFloat) -> (KeyboardKey, CGFloat) {
        let item = symbol("delete.left", label: "删除", weight: weight) { [weak self] in
            guard let self else { return }
            guard self.hasDeletableContent else { return }
            self.apply(self.session.backspace())
        }
        item.0.accessibilityIdentifier = "vime.key.delete"
        item.0.repeats = true
        item.0.canRepeat = { [weak self] in self?.hasDeletableContent ?? false }
        return item
    }

    private var hasDeletableContent: Bool {
        session.isComposing || (deletionAvailabilityProvider?() ?? true)
    }

    private static let bracketPairs: [String: String] = [
        "(": ")", "（": "）", "[": "]", "［": "］", "{": "}", "｛": "｝",
        "「": "」", "『": "』", "【": "】", "〔": "〕", "〈": "〉", "《": "》",
        "〖": "〗", "〘": "〙", "〚": "〛", "⌈": "⌉", "⌊": "⌋", "⟨": "⟩"
    ]

    private func insertSymbol(_ text: String) {
        guard preferences.autoPairBrackets, let closing = Self.bracketPairs[text] else {
            apply(session.insertLiteral(text)); return
        }
        let edits = session.confirmAll()
        session.invalidateLearningFeedback()
        session.reset()
        apply(edits + [.insertPair(opening: text, closing: closing)])
    }

    private func apply(_ edits: [KeyboardEdit]) {
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
    }

    private func publishPreedit() {
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

    func hostContextDidChange() { session.didApplyEdits([]); refresh() }
    func finishLearningFeedback() { session.finishLearningFeedback() }
    func prepareForInput() { session.prepareForInput() }

    func resetComposition() {
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

    private func refresh() {
        let uiStartedAt = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.candidateUIUpdate, since: uiStartedAt) }
        let traits = session.inputTraits
        if displayedLanguage != traits.language || displayedAlternateLanguage != traits.alternateLanguage {
            traitCollection.performAsCurrent {
                languageKey?.setImage(KeyboardGlyphs.language(primary: traits.language.glyph, secondary: traits.alternateLanguage.glyph), for: .normal)
            }
            displayedLanguage = traits.language
            displayedAlternateLanguage = traits.alternateLanguage
        }
        languageKey?.accessibilityValue = session.inputTraits.language.accessibilityName
        languageKey?.accessibilityLabel = traits.languageSwitchAccessibilityLabel
        let composing = session.isComposing
        // Composition candidates and LM suggestions share the strip.
        let quick = quickCandidateItems()
        let showsQuick = !quick.isEmpty
        let showsClipboard = clipboard.text != nil && preferences.clipboardSuggestions && hasFullAccess
            && clipboardActive && !composing && !showsQuick && panel == .keyboard
        let strip = session.showsStrip || showsQuick || showsClipboard
        quickCandidates.present(quick)
        quickCandidates.isHidden = !showsQuick || panel != .keyboard
        clipboardSuggestion.present(showsClipboard ? clipboard.text : nil)
        clipboardSuggestion.isHidden = !showsClipboard
        let neuralPaused = session.neuralModeSuspendedForMemoryPressure
        neuralStatusLabel.isHidden = !neuralPaused || strip || panel != .keyboard
        settingsPanel?.update(hasFullAccess: hasFullAccess, neuralPaused: neuralPaused)
        header.isHidden = panel == .symbols || panel == .clipboardHistory
        undoButton.isHidden = !canUndoLineDeletion || strip || panel != .keyboard
        let showsQuickToolbar = (showsQuick || showsClipboard) && !composing
        brandButton.isHidden = (panel == .keyboard && (page != .letters || (strip && !showsQuickToolbar)))
            || (panel == .candidates || panel == .symbols || panel == .clipboardHistory)
        modeButton.isHidden = strip || page != .letters || panel != .keyboard || !session.inputTraits.supportsPrimaryVariant
        modeButton.accessibilityLabel = session.inputTraits.primaryVariantAccessibilityLabel
        candidateScroll.isHidden = !strip || showsQuick || showsClipboard || panel != .keyboard
        expandButton.isHidden = showsClipboard
        modeButton.setTitle(session.inputTraits.modeLabel, for: .normal)
        accessibilityValue = composing ? "输入中：" + (session.markedText?.text ?? "") : session.inputTraits.modeLabel
        expandButton.backgroundColor = composing ? KeyboardTouchBacking.color : KeyboardPalette.key
        divider.isHidden = !strip || showsClipboard || panel != .keyboard
        panelTitle.isHidden = panel != .candidates && panel != .settings
        panelTitle.text = panel == .settings ? "快捷设置" : session.conversionRangeDescription ?? "候选词"
        for control in [shortenRange, lengthenRange, wholeRange] {
            control.isHidden = panel != .candidates || session.conversionRangeDescription == nil
        }
        divider.backgroundColor = .separator
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
        let panelOpen = panel != .keyboard
        expandButton.setImage(UIImage(systemName: panelOpen ? "chevron.up" : "chevron.down"), for: .normal)
        expandButton.accessibilityLabel = panelOpen ? "返回键盘" : composing ? "展开候选词" : "收起键盘"
        expandButton.accessibilityIdentifier = panelOpen ? "vime.panel.close" : "vime.candidates.expand"
        let hidesKeys = panel != .keyboard
        numberSymbolRail?.isHidden = hidesKeys || !usesNumberPad
        if hidesKeys { keysContainer.cancelAllPresses() }
        keysContainer.isHidden = hidesKeys
        panelScroll.isHidden = panel != .candidates
        symbolPanel?.isHidden = panel != .symbols
        settingsPanel?.isHidden = panel != .settings
        clipboardHistoryPanel?.isHidden = panel != .clipboardHistory
        if panel == .candidates { rebuildCandidatePanel() }
        else if panel == .symbols { showSymbolPanel() }
        spaceKey?.setTitle(usesNumberPad ? "空格" : composing ? session.inputTraits.compositionSpaceTitle : "", for: .normal)
        returnKey?.setTitle(composing ? session.inputTraits.compositionReturnTitle : returnTitle, for: .normal)
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
        setNeedsLayout()
    }

    private func layoutCandidateStrip() {
        let height = candidateScroll.bounds.height
        var x: CGFloat = 0
        for button in stripButtons {
            button.frame = CGRect(x: x, y: 0, width: button.presentationWidth, height: height)
            button.layoutIfNeeded()
            x = button.frame.maxX + 2
        }
        let size = CGSize(width: max(0, x - 2), height: height)
        candidateRow.frame = CGRect(origin: .zero, size: size)
        candidateScroll.contentSize = size
    }

    private var returnTitle: String {
        switch returnKeyType {
        case .send: "发送"
        case .search: "搜索"
        case .go: "前往"
        case .done: "完成"
        case .next: "下一项"
        case .join: "加入"
        default: "换行"
        }
    }

    private func candidateButton(_ presentation: CandidatePresentation, index: Int) -> KeyboardCandidateButton {
        let button = KeyboardCandidateButton(frame: .zero)
        presentCandidate(button, presentation: presentation, index: index)
        button.addTarget(self, action: #selector(selectCandidate(_:)), for: .touchUpInside)
        return button
    }

    private func presentCandidate(_ button: KeyboardCandidateButton, presentation: CandidatePresentation, index: Int) {
        let configurationStartedAt = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.candidateButtonConfiguration, since: configurationStartedAt) }
        button.present(presentation, index: index, highlighted: session.isComposing && index == (session.selectedIndex ?? 0))
    }

    @objc private func selectCandidate(_ sender: UIButton) {
        guard let token = (sender as? KeyboardCandidateButton)?.takeSelectionToken() else { return }
        playFeedback()
        apply(session.chooseCandidate(token))
    }

    private func rebuildCandidatePanel() {
        let values = session.candidatePage(offset: 0, limit: panelLimit)
        while panelCandidates.count > values.count {
            let button = panelCandidates.removeLast()
            button.removeFromSuperview(); sparePanelButtons.append(button)
        }
        while panelCandidates.count < values.count {
            let index = panelCandidates.count
            let button = sparePanelButtons.popLast() ?? candidateButton(values[index], index: index)
            button.backgroundColor = .clear
            button.layer.cornerRadius = 6
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            panelScroll.addSubview(button)
            panelCandidates.append(button)
        }
        for (index, button) in panelCandidates.enumerated() {
            presentCandidate(button, presentation: values[index], index: index)
            button.isUserInteractionEnabled = session.candidatesAreCurrent && button.selectionToken != nil
        }
    }

    private func updateKeyLabels() {
        for button in letterKeys {
            if let value = button.title(for: .normal) {
                button.setTitle(value.uppercased(), for: .normal)
            }
        }
        let active = shifted
        shiftKey?.setImage(UIImage(systemName: capsLocked && session.inputTraits.isEnglish ? "capslock.fill" : active ? "shift.fill" : "shift"), for: .normal)
        shiftKey?.tintColor = KeyboardPalette.text
    }

    private func shift() {
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastShiftTap < 0.3 { capsLocked = true; shifted = true }
        else { shifted.toggle(); capsLocked = false }
        lastShiftTap = now
        updateKeyLabels()
    }

    private func playFeedback() {
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

    @objc private func toolbarFeedback() { playFeedback() }

    private func configureScroll(_ scroll: UIScrollView) {
        scroll.backgroundColor = KeyboardTouchBacking.color
        scroll.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            // Candidate text is foreground content, not content behind a toolbar.
            for edge in [scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect] {
                edge.isHidden = true
            }
        }
    }

    private static let letterHints: [String: String] = Dictionary(uniqueKeysWithValues: zip(
        Array("qwertyuiopasdfghjklzxcvbnm").map(String.init),
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "/", ":", ";", "(", ")", "~", "“", "”", "@", "·", "#", "`", "?", "!", "…"]
    ))

    private func configureGlobe() {
        globeButton.removeTarget(nil, action: nil, for: .allTouchEvents)
        if needsGlobe, let target = inputModeListTarget, let selector = inputModeListAction {
            globeButton.addTarget(target, action: selector, for: .allTouchEvents)
        } else { globeButton.addTarget(self, action: #selector(switchKeyboard), for: .touchUpInside) }
        // Configuring the system input-mode selector removes old touch targets;
        // reinstall feedback each time so the globe still has a native click.
        globeButton.addTarget(self, action: #selector(toolbarFeedback), for: .touchDown)
    }

    @objc private func switchKeyboard() { confirmComposition(); onSwitchKeyboard?() }

    @objc private func headerArrow() {
        if panel != .keyboard {
            panel = .keyboard; refresh()
        } else if session.isComposing { toggleExpanded() }
        else { onDismiss?() }
    }

    private func toggleEmoji() {
        openSymbolPanel(mode: .emoji)
    }

    private func openSymbolPanel(mode: KeyboardSymbolPanel.Mode) {
        apply(session.confirm())
        panel = .symbols
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
        symbolPanel?.selectMode(mode)
    }

    private func showSymbolPanel() {
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

    @objc private func toggleKana() {
        apply(session.togglePrimaryVariant())
        rebuildKeys()
    }

    private func canUseClipboardSuggestion(_ text: String) -> Bool {
        !clipboardSuggestion.isHidden && panel == .keyboard && !session.isComposing
            && clipboardActive && window != nil && preferences.clipboardSuggestions && hasFullAccess
            && clipboard.text == text && quickCandidateItems().isEmpty
    }

    private func quickCandidateItems() -> [KeyboardQuickCandidate] {
        guard page == .numbers else { return [] }
        // A word being converted keeps its full candidate strip. Pure numeric
        // input gets shortcuts immediately, including when digits are marked.
        let mark = session.markedText?.text ?? ""
        guard mark.isEmpty || mark.allSatisfy({ "0123456789０１２３４５６７８９.．+-−－＋*/×÷＊／()（）%％".contains($0) }) else { return [] }
        var items: [KeyboardQuickCandidate] = []
        if onReplaceText != nil, let anchor = learningContextProvider?(), !anchor.hasSelection,
           let before = anchor.before, let calculation = KeyboardCalculation.trailing(in: before + mark),
           calculation.expression.hasSuffix(mark), calculation.expression.count >= mark.count {
            let suffix = String(calculation.expression.dropLast(mark.count))
            for text in [calculation.result, calculation.equation] {
                let replacement = KeyboardTextReplacement(anchor: anchor, markedText: session.markedText?.text,
                    committedSuffix: suffix, text: text)
                items.append(.init(title: text, action: .replacement(replacement)))
            }
        }
        items += KeyboardCalculation.symbols.map { .init(title: $0, action: .symbol($0)) }
        return items
    }

    private func selectQuickCandidate(_ item: KeyboardQuickCandidate) {
        guard quickCandidateItems().contains(item) else { refresh(); return }
        playFeedback()
        switch item.action {
        case .symbol(let text):
            insertSymbol(text)
        case .replacement(let replacement):
            guard learningContextProvider?() == replacement.anchor,
                  session.markedText?.text == replacement.markedText,
                  onReplaceText?(replacement) == true else { refresh(); return }
            session.invalidateLearningFeedback()
            session.reset()
            if panel == .candidates { panel = .keyboard }
            refresh()
        }
    }

    @objc private func shortenConversion() {
        panelLimit = 40
        session.adjustConversionRange(by: -1)
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
    }
    @objc private func lengthenConversion() {
        panelLimit = 40
        session.adjustConversionRange(by: 1)
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
    }
    @objc private func wholeConversion() {
        panelLimit = 40
        session.resetConversionRange()
        refresh()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === panelScroll, panel == .candidates, panelLimit < session.candidateCount,
              session.candidatesAreCurrent, scrollView.contentSize.height > scrollView.bounds.height,
              scrollView.contentOffset.y + scrollView.bounds.height >= scrollView.contentSize.height - 90 else { return }
        panelLimit += 40
        rebuildCandidatePanel()
        setNeedsLayout()
    }
    @objc private func toggleExpanded() {
        panelLimit = 40
        panel = panel == .candidates ? .keyboard : .candidates
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
    }

    @objc private func toggleSettings() {
        panel = panel == .settings ? .keyboard : .settings
        if settingsPanel == nil { createSettingsPanel() }
        refresh()
    }

    private func insertClipboardText(_ text: String) {
        panel = .keyboard
        let edits = session.confirmAll()
        session.invalidateLearningFeedback()
        session.reset()
        apply(edits + [.insert(text)])
    }

    private func openClipboardHistory() {
        panel = .clipboardHistory
        if clipboardHistoryPanel == nil {
            let view = ClipboardHistoryPanel()
            view.onBack = { [weak self] in
                guard let self else { return }
                self.playFeedback(); self.panel = .settings; self.refresh()
            }
            view.onSelect = { [weak self] entry in self?.selectClipboardHistory(entry) }
            view.onClear = { [weak self] in
                guard let self else { return }
                self.historyRequest += 1
                self.clipboardHistoryPanel?.present([], message: "正在清空…")
                Task { [weak self] in
                    guard let self else { return }
                    do { try await self.clipboard.clearHistory(); self.reloadClipboardHistory() }
                    catch { self.clipboardHistoryPanel?.present([], message: "清空失败，请重试") }
                }
            }
            addSubview(view)
            clipboardHistoryPanel = view
        }
        reloadClipboardHistory()
        refresh()
    }

    private func reloadClipboardHistory() {
        historyRequest += 1
        let request = historyRequest
        guard panel == .clipboardHistory else { return }
        guard preferences.clipboardSuggestions, hasFullAccess, clipboardActive, window != nil else {
            clipboardHistoryPanel?.present([], message: preferences.clipboardSuggestions
                ? "请允许键盘完全访问后查看" : "请先在 Vime App 开启剪贴板功能")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.clipboard.history.entries()
                guard self.panel == .clipboardHistory, self.historyRequest == request else { return }
                self.clipboardHistoryPanel?.present(entries)
            } catch {
                guard self.panel == .clipboardHistory, self.historyRequest == request else { return }
                self.clipboardHistoryPanel?.present([], message: "历史暂时无法读取，请稍后重试")
            }
        }
    }

    private func selectClipboardHistory(_ entry: ClipboardHistoryStore.Entry) {
        let request = historyRequest
        Task { [weak self] in
            guard let self else { return }
            let value = try? await self.clipboard.history.text(for: entry.id)
            guard self.panel == .clipboardHistory, self.historyRequest == request,
                  self.clipboardActive, self.window != nil, self.preferences.clipboardSuggestions,
                  self.hasFullAccess, value == entry.text else { return }
            self.playFeedback()
            self.insertClipboardText(entry.text)
            if self.clipboard.text == entry.text { self.clipboard.consume() }
        }
    }

    private func createSettingsPanel() {
        let view = KeyboardSettingsPanel(preferences: preferences)
        configureScroll(view)
        view.onHistory = { [weak self] in self?.openClipboardHistory() }
        view.onOpenAppSettings = { [weak self] in self?.onOpenAppSettings?() }
        view.onFeedback = { [weak self] in self?.playFeedback() }
        view.onNumberLayoutChange = { [weak self] in self?.rebuildKeys() }
        addSubview(view)
        settingsPanel = view
    }

    private func applyKeySkins() {
        for (key, _) in rows.flatMap({ $0 }) {
            let identifier = key.accessibilityIdentifier?.replacingOccurrences(of: "vime.key.", with: "") ?? ""
            let semantic: String
            if key === shiftKey { semantic = "shift" }
            else if key === returnKey { semantic = "return" }
            else if letterKeys.contains(where: { $0 === key }) { semantic = "letter." + identifier }
            else if key.repeats { semantic = "backspace" }
            else if key.accessibilityLabel == "表情" { semantic = "emoji" }
            else if ["123", "ABC", "#+="].contains(key.title(for: .normal) ?? "") { semantic = "numbers" }
            else { semantic = identifier }
            key.applySkin(KeyboardPalette.skin, key: semantic)
        }
    }
    private func applyTheme() {
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
