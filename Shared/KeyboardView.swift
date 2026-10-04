import UIKit

private enum KeyboardPalette {
    static let background = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : UIColor(red: 232 / 255, green: 233 / 255, blue: 236 / 255, alpha: 1) }
    static let key = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.28, alpha: 1) : .white }
    static let utility = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.21, alpha: 1) : UIColor(red: 196 / 255, green: 200 / 255, blue: 206 / 255, alpha: 1) }
    static let accent = UIColor(red: 0.08, green: 0.65, blue: 0.39, alpha: 1)
    static let pressed = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.40, alpha: 1) : UIColor(white: 0.85, alpha: 1) }
}

/// The visual selection follows the text width, independently of the button's
/// hit area or a wider cell in the expanded candidate panel.
private final class CandidateButton: UIButton {
    private let fill = UIView()
    private var presentedText = ""
    private var presentedIndex: Int?
    private var presentedHighlight: Bool?
    private var measuredTextWidth: CGFloat = 0
    var presentationWidth: CGFloat { ceil(measuredTextWidth) + 24 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentHorizontalAlignment = .left
        titleLabel?.textAlignment = .left
        fill.isUserInteractionEnabled = false
        fill.backgroundColor = KeyboardPalette.key
        insertSubview(fill, at: 0)
        backgroundColor = KeyboardTouchBacking.color
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ text: String, index: Int, highlighted: Bool, cornerRadius: CGFloat) {
        tag = index
        let needsMeasurement = text != presentedText || presentedIndex != index
        if text != presentedText {
            presentedText = text
            setTitle(text, for: .normal)
            accessibilityLabel = "候选词：" + text
            invalidateIntrinsicContentSize()
        }
        if presentedIndex != index {
            titleLabel?.font = .systemFont(ofSize: 18, weight: index == 0 ? .medium : .regular)
            presentedIndex = index
            invalidateIntrinsicContentSize()
        }
        if presentedHighlight != highlighted {
            presentedHighlight = highlighted
            setTitleColor(highlighted ? KeyboardPalette.accent : .label, for: .normal)
            fill.isHidden = !highlighted
        }
        if needsMeasurement {
            let startedAt = KeyboardPerformance.start()
            measuredTextWidth = (text as NSString).size(withAttributes: [.font: titleLabel!.font!]).width
            KeyboardPerformance.record(.candidateTitleMeasurement, since: startedAt)
        }
        fill.layer.cornerRadius = cornerRadius
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: presentationWidth, height: (titleLabel?.font.lineHeight ?? 22) + 4)
    }

    override func contentRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 12, dy: 2) }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = CGRect(x: 6, y: 0, width: min(max(0, bounds.width - 12), ceil(measuredTextWidth) + 12), height: bounds.height)
    }
}

final class KeyboardKey: UIButton {
    /// Owned, nonoverlapping touch cell in this key's local coordinates.
    /// The painted frame remains unchanged.
    var touchBounds: CGRect?
    var action: (() -> Void)?
    var feedback: (() -> Void)?
    var alternateAction: (() -> Void)?
    var alternateTitle: String?
    private var swipe = KeySwipeSelection()
    private var touchOrigin = CGPoint.zero
    let hintLabel = UILabel()
    var hint: String? { didSet { hintLabel.text = hint; setNeedsLayout() } }
    private var usedAlternate = false
    var repeats = false
    var showsPreview = false
    var fillColor: UIColor = KeyboardPalette.key { didSet { updateAppearance() } }
    private var repeatTimer: Timer?
    private var delayTimer: Timer?
    private var preview: UILabel?

    init(title: String? = nil, symbol: String? = nil) {
        super.init(frame: .zero)
        layer.cornerRadius = 6.2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.30
        layer.shadowOffset = CGSize(width: 0, height: 0.8)
        layer.shadowRadius = 0
        titleLabel?.font = .systemFont(ofSize: 23, weight: .regular)
        hintLabel.font = .systemFont(ofSize: 9)
        hintLabel.textColor = UIColor(white: 0.63, alpha: 1)
        hintLabel.textAlignment = .center
        hintLabel.isUserInteractionEnabled = false
        addSubview(hintLabel)
        setTitleColor(.label, for: .normal)
        tintColor = .label
        if let title { setTitle(title, for: .normal); accessibilityLabel = title }
        if let symbol { setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)), for: .normal) }
        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(up), for: .touchUpInside)
        addTarget(self, action: #selector(cancel), for: .touchCancel)
        addTarget(self, action: #selector(upOutside), for: .touchUpOutside)
        addTarget(self, action: #selector(reenter), for: .touchDragEnter)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let inside = (touchBounds ?? bounds).contains(point)
        KeyboardTouchDiagnostics.record("KeyboardKey.pointInside", point: point, view: self,
            result: inside ? self : nil)
        return inside
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hintLabel.frame = CGRect(x: 0, y: 2, width: bounds.width, height: 11)
        if hint != nil { titleLabel?.center.y = bounds.height * 0.59 }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchOrigin = touch.location(in: self)
        swipe.reset()
        return super.beginTracking(touch, with: event)
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        updateSwipe(x: point.x - touchOrigin.x, y: point.y - touchOrigin.y)
        _ = super.continueTracking(touch, with: event)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch {
            let point = touch.location(in: self)
            updateSwipe(x: point.x - touchOrigin.x, y: point.y - touchOrigin.y)
        }
        finishSwipe(cancelled: touch == nil)
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        finishSwipe(cancelled: true)
        super.cancelTracking(with: event)
    }

    // Shared by touch tracking and regression tests; insertion happens on release only.
    @discardableResult
    func updateSwipe(x: CGFloat, y: CGFloat) -> Bool {
        guard alternateAction != nil else { return false }
        swipe.move(x: Double(x), y: Double(y))
        if swipe.alternate {
            showPreview(alternateTitle ?? hint ?? "", alternate: true)
        } else if showsPreview {
            showPreview(title(for: .normal) ?? "", alternate: false)
        } else { preview?.removeFromSuperview(); preview = nil }
        return swipe.alternate
    }

    func beginResolvedPress() {
        let startedAt = KeyboardPerformance.start()
        swipe.reset()
        isHighlighted = true
        down()
        KeyboardPerformance.record(.touchDownToVisual, since: startedAt)
    }

    func presentResolvedPress(alternate: Bool) {
        if alternate { showPreview(alternateTitle ?? hint ?? "", alternate: true) }
        else if showsPreview { showPreview(title(for: .normal) ?? "", alternate: false) }
        else { preview?.removeFromSuperview(); preview = nil }
    }

    func finishResolvedPress(cancelled: Bool, alternate: Bool, stillPressed: Bool) {
        KeyboardTouchDiagnostics.record("KeyboardKey.resolvedRelease", view: self,
            detail: "cancelled=\(cancelled) alternate=\(alternate) stillPressed=\(stillPressed)")
        if !stillPressed {
            isHighlighted = false
            stopTracking()
        }
        // The surface owns selection per finger; UIButton's shared swipe/up
        // state must not decide another simultaneous finger's character.
        if !cancelled && !repeats {
            if alternate { alternateAction?() }
            else { action?() }
        }
    }

    override func accessibilityActivate() -> Bool {
        feedback?()
        action?()
        return true
    }

    func finishSwipe(cancelled: Bool) {
        usedAlternate = cancelled || swipe.alternate
        if !cancelled && swipe.alternate { alternateAction?() }
        swipe.reset()
        stopTracking()
    }

    private func showPreview(_ text: String, alternate: Bool) {
        let bubble = preview ?? UILabel()
        let container = superview?.superview ?? self
        bubble.frame = convert(CGRect(x: -8, y: -48, width: bounds.width + 16, height: 44), to: container)
        bubble.text = text
        bubble.font = .systemFont(ofSize: alternate ? 27 : 30, weight: alternate ? .medium : .regular)
        bubble.textAlignment = .center
        bubble.textColor = alternate ? KeyboardPalette.accent : .label
        bubble.backgroundColor = KeyboardPalette.key
        bubble.layer.cornerRadius = 8
        bubble.layer.masksToBounds = true
        bubble.isUserInteractionEnabled = false
        bubble.accessibilityIdentifier = "vime.swipe.preview"
        if bubble.superview !== container { container.addSubview(bubble) }
        preview = bubble
        container.bringSubviewToFront(bubble)
    }

    override var isHighlighted: Bool { didSet { updateAppearance() } }

    private func updateAppearance() { backgroundColor = isHighlighted ? KeyboardPalette.pressed : fillColor }

    @objc private func down() {
        KeyboardTouchDiagnostics.record("KeyboardKey.touchDown", view: self)
        usedAlternate = false
        feedback?()
        if repeats {
            action?()
            // Two fingers can own this key. Keep one repeat stream and don't
            // overwrite an active timer, which would leave it uncancellable.
            guard isHighlighted || isTracking, delayTimer == nil, repeatTimer == nil else { return }
            let delay = Timer(timeInterval: 0.42, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.delayTimer = nil
                let timer = Timer(timeInterval: 0.065, repeats: true) { [weak self] _ in self?.feedback?(); self?.action?() }
                self.repeatTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            delayTimer = delay
            RunLoop.main.add(delay, forMode: .common)
        } else if showsPreview, let title = title(for: .normal), title.count == 1 {
            showPreview(title, alternate: false)
        }
    }

    @objc private func up() {
        KeyboardTouchDiagnostics.record("KeyboardKey.touchUpInside", view: self)
        stopTracking()
        if !repeats && !usedAlternate { action?() }
    }

    @objc private func cancel() {
        KeyboardTouchDiagnostics.record("KeyboardKey.touchCancel", view: self)
        stopTracking()
    }
    @objc private func upOutside() {
        KeyboardTouchDiagnostics.record("KeyboardKey.touchUpOutside", view: self)
        stopTracking()
    }
    @objc private func reenter() { if repeats { down() } }

    func stopTracking() {
        delayTimer?.invalidate()
        repeatTimer?.invalidate()
        delayTimer = nil
        repeatTimer = nil
        preview?.removeFromSuperview()
        preview = nil
    }

    override func didMoveToWindow() { if window == nil { stopTracking() } }
    deinit { delayTimer?.invalidate(); repeatTimer?.invalidate() }
}

/// The same UIKit keyboard is used by the extension and the containing app's sandbox.
final class KeyboardView: UIView, UIInputViewAudioFeedback {
    var hasFullAccess = true {
        didSet {
            if oldValue != hasFullAccess, settingsPanel != nil {
                settingsPanel?.removeFromSuperview(); settingsPanel = nil
                createSettingsPanel(); refresh()
            }
        }
    }
    var enableInputClicksWhenVisible: Bool { preferences.sound }
    let preferences = KeyboardPreferences()
    var onEdit: (([KeyboardEdit]) -> Void)?
    var onSwitchKeyboard: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onCompositionChange: ((String) -> Void)?
    var onMarkedTextChange: ((String?) -> Void)?
    weak var inputModeListTarget: AnyObject? { didSet { configureGlobe() } }
    var inputModeListAction: Selector? { didSet { configureGlobe() } }
    var needsGlobe = false { didSet { if oldValue != needsGlobe { configureGlobe() } } }
    var showsFooter = true { didSet { if oldValue != showsFooter { setNeedsLayout(); invalidateIntrinsicContentSize() } } }
    var compact = false { didSet { if oldValue != compact { setNeedsLayout(); invalidateIntrinsicContentSize() } } }
    func preferredHeight(for width: CGFloat) -> CGFloat {
        KeyboardMetrics(width: width > 0 ? width : 440, compact: compact, showsFooter: showsFooter).height
    }
    var returnKeyType: UIReturnKeyType = .default { didSet { if oldValue != returnKeyType { refresh() } } }
    var keyboardType: UIKeyboardType = .default {
        didSet {
            guard oldValue != keyboardType else { return }
            if [.numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad, .numbersAndPunctuation].contains(keyboardType) { page = .numbers }
            else { page = .letters }
            if [.emailAddress, .URL, .asciiCapable].contains(keyboardType) { apply(session.setMode(.english)) }
            rebuildKeys()
        }
    }

    private enum Page { case letters, numbers, symbols }
    private let session: KeyboardSession
    private var displayedCandidates: [String] = []
    private var displayedSelection: Int?
    private var page: Page = .letters
    private var shifted = false
    private var capsLocked = false
    private var lastShiftTap: TimeInterval = 0
    private var expanded = false
    private var settingsOpen = false
    private var emojiOpen = false
    private var previewsEnabled: Bool { preferences.previews }
    private var impactGenerators: [Int: UIImpactFeedbackGenerator] = [:]
    private let header = UIView()
    private let candidateScroll = UIScrollView()
    private let candidateRow = UIView()
    private var stripButtons: [CandidateButton] = []
    private var spareCandidateButtons: [CandidateButton] = []
    private var displayedLanguageEnglish: Bool?
    private let brandButton = UIButton(type: .custom)
    private let globeButton = UIButton(type: .custom)
    private let modeButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let divider = UIView()
    private let keysContainer = KeyboardTouchSurface()
    private let panelScroll = UIScrollView()
    private var panelCandidates: [UIButton] = []
    private var settingsPanel: UIView?
    private var rows: [[(KeyboardKey, CGFloat)]] = []
    private var letterKeys: [KeyboardKey] = []
    private var shiftKey: KeyboardKey?
    private var spaceKey: KeyboardKey?
    private var languageKey: KeyboardKey?
    private var returnKey: KeyboardKey?

    override convenience init(frame: CGRect) {
        self.init(frame: frame, session: KeyboardSession(asynchronousCandidates: true))
    }

    init(frame: CGRect, session: KeyboardSession) {
        self.session = session
        super.init(frame: frame)
        session.onCandidatesChange = { [weak self] in
            guard let self else { return }
            self.onMarkedTextChange?(self.session.preedit)
            let publicationStartedAt = KeyboardPerformance.start()
            self.refresh()
            KeyboardPerformance.record(.candidatePublication, since: publicationStartedAt)
            KeyboardPerformance.record(.resultToCandidateUI, since: self.session.candidateResultReadyAt)
        }
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessibilityIdentifier = "vime.keyboard"
        addSubview(header)
        addSubview(keysContainer)
        addSubview(panelScroll)
        panelScroll.isHidden = true
        header.addSubview(brandButton)
        brandButton.backgroundColor = KeyboardPalette.key
        brandButton.setImage(KeyboardGlyphs.settings(), for: .normal)
        brandButton.accessibilityLabel = "键盘设置"
        brandButton.addTarget(self, action: #selector(toggleSettings), for: .touchUpInside)
        addSubview(globeButton)
        globeButton.tintColor = .label
        globeButton.setImage(UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 27, weight: .regular)), for: .normal)
        globeButton.accessibilityLabel = "切换系统键盘"
        globeButton.addTarget(self, action: #selector(switchKeyboard), for: .touchUpInside)
        header.addSubview(modeButton)
        modeButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        modeButton.backgroundColor = KeyboardPalette.key
        modeButton.tintColor = .secondaryLabel
        modeButton.addTarget(self, action: #selector(toggleKana), for: .touchUpInside)
        modeButton.accessibilityLabel = "切换平假名和片假名"
        settingsButton.isHidden = true
        header.addSubview(settingsButton)
        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        settingsButton.tintColor = .secondaryLabel
        settingsButton.addTarget(self, action: #selector(toggleSettings), for: .touchUpInside)
        settingsButton.accessibilityLabel = "键盘设置"
        header.addSubview(candidateScroll)
        candidateScroll.accessibilityIdentifier = "vime.candidates"
        configureScroll(candidateScroll)
        configureScroll(panelScroll)
        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.addSubview(candidateRow)
        header.addSubview(expandButton)
        expandButton.tintColor = .secondaryLabel
        expandButton.backgroundColor = KeyboardPalette.key
        expandButton.addTarget(self, action: #selector(headerArrow), for: .touchUpInside)
        expandButton.accessibilityLabel = "展开候选词"
        header.addSubview(cancelButton)
        cancelButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        cancelButton.tintColor = .tertiaryLabel
        cancelButton.accessibilityLabel = "取消当前输入"
        cancelButton.addTarget(self, action: #selector(cancelComposition), for: .touchUpInside)
        addSubview(divider)
        divider.isHidden = true
        rebuildKeys()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight(for: bounds.width)) }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            traitCollection.performAsCurrent { languageKey?.setImage(KeyboardGlyphs.language(english: session.mode == .english), for: .normal) }
            setNeedsLayout()
        }
    }

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
        let width = bounds.width
        guard width > 0 else { return }
        let metrics = KeyboardMetrics(width: width, compact: compact, showsFooter: showsFooter)
        let scale = metrics.scale
        let xScale = width / 440
        let headerHeight = metrics.headerHeight
        header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        let diameter: CGFloat = compact ? 30 : 34.5 * scale
        let centerY: CGFloat = compact ? 19 : 28 * scale
        brandButton.frame = CGRect(x: 12 * xScale, y: centerY - diameter / 2, width: diameter, height: diameter)
        modeButton.frame = CGRect(x: width - 92 * xScale, y: centerY - diameter / 2, width: diameter, height: diameter)
        expandButton.frame = CGRect(x: width - 46 * xScale, y: centerY - diameter / 2, width: diameter, height: diameter)
        for button in [brandButton, modeButton, expandButton] { button.layer.cornerRadius = diameter / 2 }
        candidateScroll.frame = CGRect(x: 4 * xScale, y: centerY - (compact ? 13 : 17 * scale), width: width - 55 * xScale, height: compact ? 26 : 34 * scale)
        layoutCandidateStrip()
        cancelButton.frame = .zero
        divider.frame = CGRect(x: width - 51 * xScale, y: centerY - 12 * scale, width: 0.5, height: 24 * scale)
        keysContainer.frame = bounds
        let body = CGRect(x: 0, y: headerHeight, width: width, height: metrics.contentHeight - headerHeight)
        panelScroll.frame = body
        settingsPanel?.frame = body
        for (rowIndex, row) in rows.enumerated() {
            for (column, pair) in row.enumerated() {
                if page == .numbers && preferences.nineKeyNumbers {
                    pair.0.frame = metrics.numberPadFrame(row: rowIndex, column: column)
                } else {
                    pair.0.frame = metrics.frame(row: rowIndex, column: column, letters: page == .letters,
                                                prolonged: rowIndex == 1 && row.count == 10)
                }
                pair.0.layer.cornerRadius = 6.2 * scale
                pair.0.hintLabel.font = .systemFont(ofSize: 9 * scale)
                pair.0.titleLabel?.font = .systemFont(ofSize: (rowIndex == 3 ? 16.5 : 23) * scale)
            }
        }
        updateTouchBounds(metrics: metrics)
        globeButton.isHidden = !showsFooter
        globeButton.frame = CGRect(x: 22 * xScale, y: metrics.contentHeight + (compact ? 0 : 17 * scale), width: 40 * scale, height: compact ? 34 : 40 * scale)
        bringSubviewToFront(header)
        let columns = width > 600 ? 5 : 3
        let cellWidth = (width - 20) / CGFloat(columns)
        for (index, button) in panelCandidates.enumerated() {
            button.frame = CGRect(x: 8 + CGFloat(index % columns) * cellWidth, y: CGFloat(index / columns) * 46, width: cellWidth - 5, height: 41)
        }
        panelScroll.contentSize = CGSize(width: width, height: CGFloat((panelCandidates.count + columns - 1) / columns) * 46)
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
                let left = column == 0 ? 0 : (row[column - 1].0.frame.maxX + key.frame.minX) / 2
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
        button.action = action
        button.feedback = { [weak self] in self?.playFeedback() }
        if utility {
            button.fillColor = KeyboardPalette.utility
            button.titleLabel?.font = .systemFont(ofSize: 16)
        }
        keysContainer.addSubview(button)
        return (button, weight)
    }

    private func symbol(_ name: String, label: String, weight: CGFloat, action: @escaping () -> Void) -> (KeyboardKey, CGFloat) {
        let button = KeyboardKey(symbol: name)
        button.accessibilityLabel = label
        button.fillColor = KeyboardPalette.utility
        button.action = action
        button.feedback = { [weak self] in self?.playFeedback() }
        keysContainer.addSubview(button)
        return (button, weight)
    }

    private func rebuildKeys() {
        keysContainer.cancelAllPresses()
        keysContainer.regions = []
        for row in rows { for (button, _) in row { button.stopTracking(); button.removeFromSuperview() } }
        rows = []
        letterKeys = []
        shiftKey = nil
        spaceKey = nil
        languageKey = nil
        returnKey = nil
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
                        self.apply(self.session.type(self.shifted && self.session.mode == .english ? value.uppercased() : value))
                        if self.shifted && !self.capsLocked { self.shifted = false; self.updateKeyLabels() }
                    }
                    item.0.showsPreview = previewsEnabled
                    item.0.accessibilityIdentifier = "vime.key." + value
                    item.0.hint = Self.letterHints[value]
                    item.0.alternateTitle = Self.letterHints[value]
                    item.0.alternateAction = { [weak self] in
                        guard let self, let hint = Self.letterHints[value] else { return }
                        self.apply(self.session.insertLiteral(hint))
                    }
                    letterKeys.append(item.0)
                    row.append(item)
                }
                if letters == "zxcvbnm" { row.append(deleteKey(weight: 1.35)) }
                if letters == "asdfghjkl", preferences.prolongedKey, session.mode != .english {
                    let prolonged = key("ー") { [weak self] in
                        guard let self else { return }
                        self.apply(self.session.type("ー"))
                    }
                    prolonged.0.accessibilityLabel = "长音符号"
                    prolonged.0.accessibilityIdentifier = "vime.key.prolonged"
                    row.append(prolonged)
                }
                rows.append(row)
            }
        } else if page == .numbers && preferences.nineKeyNumbers {
            let values = [["#+=", "1", "2", "3", "删除"],
                          ["+", "4", "5", "6", "-"],
                          ["/", "7", "8", "9", "*"],
                          ["ABC", "。", "0", ".", "换行"]]
            for (r, values) in values.enumerated() {
                rows.append(values.map { value in
                    if value == "删除" { return deleteKey(weight: 1) }
                    let item = key(value, utility: ["ABC", "#+=", "换行"].contains(value)) { [weak self] in
                        guard let self else { return }
                        switch value {
                        case "ABC": self.page = .letters; self.rebuildKeys()
                        case "#+=": self.page = .symbols; self.rebuildKeys()
                        case "换行": self.apply(self.session.enter())
                        default: self.apply(self.session.insertLiteral(value))
                        }
                    }
                    item.0.accessibilityIdentifier = "vime.number." + value
                    if r == 3 && value == "换行" { returnKey = item.0 }
                    return item
                })
            }
            refresh(); setNeedsLayout(); return
        } else {
            let values = page == .numbers
                ? [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""], ["。", "、", "？", "！", "'", "ー", "・"]]
                : [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "$", "€", "£", "・"], ["「", "」", "『", "』", "…", "〜", "々"]]
            for (index, values) in values.enumerated() {
                var row = values.map { value in
                    let item = key(value) { [weak self] in
                        guard let self else { return }
                        if self.session.isComposing && ["'", "-", "ー"].contains(value) {
                            self.apply(self.session.type(value))
                        } else {
                            self.apply(self.session.insertLiteral(value))
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
        let comma = key(",", weight: 1) { [weak self] in
            guard let self else { return }
            self.apply(self.session.insertLiteral(self.session.mode == .english ? "," : "、"))
        }
        comma.0.hint = "°"
        comma.0.alternateTitle = "。"
        comma.0.alternateAction = { [weak self] in
            guard let self else { return }
            self.apply(self.session.insertLiteral("。"))
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
        language.0.setImage(KeyboardGlyphs.language(english: session.mode == .english), for: .normal)
        languageKey = language.0
        language.0.accessibilityLabel = "日语英文切换"
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
        updateKeyLabels()
        refresh()
        setNeedsLayout()
    }

    private func deleteKey(weight: CGFloat) -> (KeyboardKey, CGFloat) {
        let item = symbol("delete.left", label: "删除", weight: weight) { [weak self] in
            guard let self else { return }
            self.apply(self.session.backspace())
        }
        item.0.accessibilityIdentifier = "vime.key.delete"
        item.0.repeats = true
        return item
    }

    private func apply(_ edits: [KeyboardEdit]) {
        if !edits.isEmpty { onEdit?(edits) }
        if !session.isComposing { expanded = false }
        onMarkedTextChange?(session.preedit)
        KeyboardPerformance.record(.typeToMarked, since: session.takeInputTiming())
        onCompositionChange?(session.composition)
        refresh()
    }

    func resetComposition() {
        session.reset()
        expanded = false
        onMarkedTextChange?(nil)
        onCompositionChange?("")
        refresh()
    }

    func confirmComposition() { apply(session.confirmAll()) }

    func stopInteractions() {
        keysContainer.cancelAllPresses()
        for row in rows { for (key, _) in row { key.stopTracking() } }
    }

    private func refresh() {
        let uiStartedAt = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.candidateUIUpdate, since: uiStartedAt) }
        let english = session.mode == .english
        if displayedLanguageEnglish != english {
            traitCollection.performAsCurrent {
                languageKey?.setImage(KeyboardGlyphs.language(english: english), for: .normal)
            }
            displayedLanguageEnglish = english
        }
        languageKey?.accessibilityValue = session.mode == .english ? "英文" : "日语"
        let composing = session.isComposing
        brandButton.isHidden = composing
        modeButton.isHidden = composing
        settingsButton.isHidden = true
        candidateScroll.isHidden = !composing
        expandButton.isHidden = false
        cancelButton.isHidden = true
        modeButton.setTitle(session.mode.label, for: .normal)
        accessibilityValue = composing ? "输入中：" + (session.preedit ?? "") : session.mode.label
        expandButton.backgroundColor = composing ? KeyboardTouchBacking.color : KeyboardPalette.key
        divider.isHidden = !composing
        divider.backgroundColor = .separator
        let candidatesChanged = displayedCandidates != session.candidates
        let selectionChanged = displayedSelection != session.selectedIndex
        if candidatesChanged || selectionChanged {
            displayedCandidates = session.candidates
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
                presentCandidate(button, text: displayedCandidates[index], index: index)
            }
            // Frames and label layout are published here and included in timing.
            // A one-dimensional strip needs no changing Auto Layout graph.
            layoutCandidateStrip()
        }
        if let index = session.selectedIndex, stripButtons.indices.contains(index), selectionChanged {
            candidateScroll.scrollRectToVisible(stripButtons[index].frame, animated: true)
        } else if candidatesChanged && session.selectedIndex == nil { candidateScroll.setContentOffset(.zero, animated: false) }
        // The retained list may belong to the previous input revision. Keep
        // its appearance, but never let a stale tap discard the newer letters.
        stripButtons.forEach { $0.isUserInteractionEnabled = session.candidatesAreCurrent }
        expandButton.setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down"), for: .normal)
        let hidesKeys = expanded || settingsOpen || emojiOpen
        if hidesKeys { keysContainer.cancelAllPresses() }
        keysContainer.isHidden = hidesKeys
        panelScroll.isHidden = (!expanded && !emojiOpen) || settingsOpen
        settingsPanel?.isHidden = !settingsOpen
        if expanded { rebuildCandidatePanel() }
        else if emojiOpen { rebuildEmojiPanel() }
        spaceKey?.setTitle(composing ? (session.selectedIndex == nil ? "変換" : "次候補") : "", for: .normal)
        returnKey?.setTitle(composing ? "確定" : returnTitle, for: .normal)
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

    private func candidateButton(_ text: String, index: Int) -> CandidateButton {
        let button = CandidateButton(frame: .zero)
        presentCandidate(button, text: text, index: index)
        button.addTarget(self, action: #selector(selectCandidate(_:)), for: .touchUpInside)
        return button
    }

    private func presentCandidate(_ button: CandidateButton, text: String, index: Int) {
        let configurationStartedAt = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.candidateButtonConfiguration, since: configurationStartedAt) }
        button.present(text, index: index, highlighted: index == (session.selectedIndex ?? 0),
                       cornerRadius: 6.2 * KeyboardMetrics(width: bounds.width, compact: compact, showsFooter: showsFooter).scale)
    }

    @objc private func selectCandidate(_ sender: UIButton) {
        playFeedback()
        apply(session.choose(sender.tag))
    }

    private func rebuildCandidatePanel() {
        for button in panelCandidates { button.removeFromSuperview() }
        panelCandidates = session.candidates.enumerated().map { index, value in
            let button = candidateButton(value, index: index)
            button.backgroundColor = .clear
            button.isUserInteractionEnabled = session.candidatesAreCurrent
            button.layer.cornerRadius = 6
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            panelScroll.addSubview(button)
            return button
        }
    }

    private func updateKeyLabels() {
        for button in letterKeys {
            if let value = button.title(for: .normal) {
                button.setTitle(value.uppercased(), for: .normal)
            }
        }
        let active = shifted
        shiftKey?.setImage(UIImage(systemName: capsLocked && session.mode == .english ? "capslock.fill" : active ? "shift.fill" : "shift"), for: .normal)
        shiftKey?.tintColor = .label
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
        let level = preferences.hapticLevel
        guard level > 0 else { return }
        let styles: [UIImpactFeedbackGenerator.FeedbackStyle] = [.light, .light, .medium, .heavy, .heavy]
        let generator = impactGenerators[level] ?? UIImpactFeedbackGenerator(style: styles[level - 1])
        impactGenerators[level] = generator
        let intensities: [CGFloat] = [0.35, 0.7, 0.8, 0.8, 1]
        generator.impactOccurred(intensity: intensities[level - 1])
        generator.prepare()
    }

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
    }

    @objc private func switchKeyboard() { confirmComposition(); onSwitchKeyboard?() }

    @objc private func headerArrow() {
        if expanded || settingsOpen || emojiOpen {
            expanded = false; settingsOpen = false; emojiOpen = false; refresh()
        } else if session.isComposing { toggleExpanded() }
        else { onDismiss?() }
    }

    private func toggleEmoji() {
        apply(session.confirm())
        emojiOpen.toggle()
        expanded = false
        settingsOpen = false
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
    }

    private func rebuildEmojiPanel() {
        for button in panelCandidates { button.removeFromSuperview() }
        panelCandidates = ["😀", "😄", "😊", "🥰", "😍", "🥺", "😂", "😭", "😅", "🤔", "😎", "🙃", "👍", "👏", "🙏", "🙌", "❤️", "✨", "🎉", "🌸", "🍵", "🍣", "🐱", "🐶", "🌙", "☀️", "🎵", "💪", "👌", "✅"].map { emoji in
            let button = UIButton(type: .system)
            button.setTitle(emoji, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 28)
            button.backgroundColor = KeyboardPalette.key
            button.layer.cornerRadius = 6
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onEdit?([.insert(emoji)])
            }, for: .touchUpInside)
            panelScroll.addSubview(button)
            return button
        }
    }

    @objc private func toggleKana() {
        apply(session.mode == .english ? session.toggleEnglish() : session.toggleKana())
        rebuildKeys()
    }

    @objc private func cancelComposition() { resetComposition() }

    @objc private func toggleExpanded() {
        expanded.toggle()
        settingsOpen = false
        emojiOpen = false
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
    }

    @objc private func toggleSettings() {
        settingsOpen.toggle()
        expanded = false
        emojiOpen = false
        if settingsPanel == nil { createSettingsPanel() }
        refresh()
    }

    private func createSettingsPanel() {
        let panel = UIScrollView()
        configureScroll(panel)
        panel.accessibilityIdentifier = "vime.settings"
        addSubview(panel)
        settingsPanel = panel
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: panel.contentLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: panel.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: panel.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        func addSwitch(_ title: String, value: Bool, id: String, change: @escaping (Bool) -> Void) {
            let row = UIStackView(); row.axis = .horizontal
            let label = UILabel(); label.text = title; label.font = .systemFont(ofSize: 15)
            let control = UISwitch(); control.isOn = value; control.onTintColor = KeyboardPalette.accent
            control.accessibilityLabel = title; control.accessibilityIdentifier = id
            control.addAction(UIAction { [weak control] _ in if let control { change(control.isOn) } }, for: .valueChanged)
            row.addArrangedSubview(label); row.addArrangedSubview(control); stack.addArrangedSubview(row)
        }
        addSwitch("按键声音", value: preferences.sound, id: "vime.setting.sound") { [weak self] in self?.preferences.sound = $0 }
        let label = UILabel(); label.font = .systemFont(ofSize: 15)
        let levels = ["关闭", "很轻", "轻", "中", "强", "很强"]
        label.text = "振动强度：" + levels[preferences.hapticLevel]
        stack.addArrangedSubview(label)
        let slider = UISlider(); slider.minimumValue = 0; slider.maximumValue = 5
        slider.value = Float(preferences.hapticLevel); slider.tintColor = KeyboardPalette.accent
        slider.accessibilityLabel = "振动强度"; slider.accessibilityIdentifier = "vime.setting.haptics"
        slider.accessibilityValue = levels[preferences.hapticLevel]
        slider.addAction(UIAction { [weak self, weak slider] _ in
            guard let self, let slider else { return }
            let value = Int(slider.value.rounded()); slider.value = Float(value)
            let changed = self.preferences.hapticLevel != value
            self.preferences.hapticLevel = value
            label.text = "振动强度：" + levels[value]; slider.accessibilityValue = levels[value]
            if changed { self.playFeedback() }
        }, for: .valueChanged)
        stack.addArrangedSubview(slider)
        let layout = UISegmentedControl(items: ["数字九宫格", "数字全键盘"])
        layout.selectedSegmentIndex = preferences.nineKeyNumbers ? 0 : 1
        layout.accessibilityLabel = "数字键盘布局"; layout.accessibilityIdentifier = "vime.setting.numbers"
        layout.addAction(UIAction { [weak self, weak layout] _ in
            guard let self, let layout else { return }
            self.preferences.nineKeyNumbers = layout.selectedSegmentIndex == 0; self.rebuildKeys()
        }, for: .valueChanged)
        stack.addArrangedSubview(layout)
        addSwitch("显示长音键 ー", value: preferences.prolongedKey, id: "vime.setting.prolonged") { [weak self] value in
            guard let self else { return }; self.preferences.prolongedKey = value; self.rebuildKeys()
        }
        addSwitch("按键预览", value: preferences.previews, id: "vime.setting.previews") { [weak self] value in
            guard let self else { return }; self.preferences.previews = value
            for key in self.letterKeys { key.showsPreview = value }
        }
#if DEBUG
        addSwitch("触摸诊断（开发版）", value: KeyboardTouchDiagnostics.enabled, id: "vime.setting.touchDiagnostics") {
            KeyboardTouchDiagnostics.setEnabled($0)
        }
#endif
        let note = UILabel(); note.numberOfLines = 0; note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabel
        note.text = hasFullAccess
            ? "声音与振动已启用。静音会关闭按键声；振动强度受设备硬件限制。\n日语转换在设备上离线完成。"
            : "启用声音和振动：设置 → 通用 → 键盘 → 键盘 → Vime 日本語 → 允许完全访问。\n无需完全访问也能离线输入。"
        stack.addArrangedSubview(note)
    }
}
