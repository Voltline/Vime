import UIKit

/// Compact groups for settings that can be changed without leaving the keyboard.
final class KeyboardSettingsPanel: UIScrollView {
    private let preferences: KeyboardPreferences
    private let stack = UIStackView()
    private let shortcuts = UIStackView()
    private let history = UIButton(type: .custom)
    private let sound = UISwitch()
    private let liveConversion = UISwitch()
    private var liveConversionGroup: UIView?
    private let haptics = HapticIntensitySlider()
    private let hapticValue = UILabel()
    private let numbers = UISegmentedControl(items: ["九宫格", "全键盘"])
    private let accessibleNumbers = UIStackView()
    private let oneHanded = UISegmentedControl(items: [String(localized: "关闭"), String(localized: "靠左"), String(localized: "靠右")])
    private var oneHandedGroup: UIView?
    private static let languages: [KeyboardInputLanguage] = [.japanese, .chinese]
    private let inputLanguage = UISegmentedControl(items: [String(localized: "日语"), String(localized: "简体中文")])
    private var inputLanguageGroup: UIView?
    private static let chineseLayouts = ChineseKeyboardLayout.allCases
    private let chineseLayout = UISegmentedControl(items: [String(localized: "全键盘"), String(localized: "九宫格"), String(localized: "双拼")])
    private var chineseLayoutGroup: UIView?
    private var numberChoices: [UIButton] = []
    private let notice = UILabel()
    private let neuralStatus = UILabel()
    private let retryNeural = UIButton(type: .custom)
    private var retryGroup: UIView?
    private var adaptiveRows: [UIStackView] = []
    /// Rows of two groups, side by side unless the text is too large.
    private var pairs: [UIStackView] = []
    /// Title-over-control tiles; a lone tile or large text lays out as a row.
    private var tiles: [UIStackView] = []
    /// Half-width switch rows, which drop their icon when the label would wrap.
    private var compactRows: [UIStackView] = []
    private var accessibleSliderWidth: NSLayoutConstraint?
    private var hapticValueWidth: NSLayoutConstraint?
    private var typography: [(UILabel, CGFloat, UIFont.Weight)] = []
    private var groups: [UIView] = []
    private var icons: [UIImageView] = []
    private var labels: [UILabel] = []
    private var horizontal: [NSLayoutConstraint] = []
    var onRetryNeural: (() -> Void)?
    var onHistory: (() -> Void)?
    var onOpenAppSettings: (() -> Void)?
    var onFeedback: (() -> Void)?
    var onNumberLayoutChange: (() -> Void)?
    var onOneHandedChange: (() -> Void)?
    var onLiveConversionChange: (() -> Void)?
    var onInputLanguageChange: ((KeyboardInputLanguage) -> Void)?
    var onChineseLayoutChange: (() -> Void)?
    /// The Chinese key plane, for the Chinese keyboard only.
    var showsChineseLayout = false { didSet { chineseLayoutGroup?.isHidden = !showsChineseLayout } }
    /// Only a keyboard that follows the stored language with Rime data bundled.
    var showsInputLanguage = false { didSet { inputLanguageGroup?.isHidden = !showsInputLanguage } }
    /// One-handed mode applies to an upright iPhone only.
    var showsOneHanded = true { didSet { oneHandedGroup?.isHidden = !showsOneHanded; updatePairs() } }
    /// Live conversion is Japanese input's; the Chinese keyboard hides it.
    var showsLiveConversion = true { didSet { updateLiveConversion() } }

    init(preferences: KeyboardPreferences) {
        self.preferences = preferences
        super.init(frame: .zero)
        accessibilityIdentifier = "vime.settings"
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        showsVerticalScrollIndicator = false
        stack.axis = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        horizontal = [stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 12),
                      stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -12),
                      stack.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor, constant: -24)]
        NSLayoutConstraint.activate(horizontal + [
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -12)
        ])

        // Keep both destinations at the top without displacing feedback controls
        // from the first landscape screen. Large text gets full-width rows.
        shortcuts.spacing = 8
        let historyRow = row(symbol: "clipboard", content: [label(String(localized: "剪贴板历史"), weight: .medium)], height: 44)
        history.addSubview(historyRow)
        historyRow.isUserInteractionEnabled = false
        historyRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([historyRow.leadingAnchor.constraint(equalTo: history.leadingAnchor),
            historyRow.trailingAnchor.constraint(equalTo: history.trailingAnchor),
            historyRow.topAnchor.constraint(equalTo: history.topAnchor),
            historyRow.bottomAnchor.constraint(equalTo: history.bottomAnchor)])
        history.accessibilityIdentifier = "vime.setting.clipboardHistory"
        history.accessibilityLabel = String(localized: "剪贴板历史")
        history.accessibilityValue = String(localized: "最近 24 小时")
        history.addAction(UIAction { [weak self] _ in self?.onHistory?() }, for: .touchUpInside)
        shortcuts.addArrangedSubview(group(history))

        let appSettings = UIButton(type: .custom)
        let appSettingsRow = row(symbol: "slider.horizontal.3",
            content: [label(String(localized: "App 设置"))], height: 44)
        appSettingsRow.isUserInteractionEnabled = false
        appSettingsRow.translatesAutoresizingMaskIntoConstraints = false
        appSettings.addSubview(appSettingsRow)
        NSLayoutConstraint.activate([
            appSettingsRow.leadingAnchor.constraint(equalTo: appSettings.leadingAnchor),
            appSettingsRow.trailingAnchor.constraint(equalTo: appSettings.trailingAnchor),
            appSettingsRow.topAnchor.constraint(equalTo: appSettings.topAnchor),
            appSettingsRow.bottomAnchor.constraint(equalTo: appSettings.bottomAnchor)
        ])
        appSettings.accessibilityIdentifier = "vime.setting.openAppSettings"
        appSettings.accessibilityLabel = String(localized: "打开 App 设置")
        appSettings.accessibilityHint = String(localized: "前往 Vime App 调整更多设置")
        appSettings.addAction(UIAction { [weak self] _ in self?.onOpenAppSettings?() }, for: .touchUpInside)
        shortcuts.addArrangedSubview(group(appSettings))
        stack.addArrangedSubview(shortcuts)


        // Vibration needs a full-width slider; the rest pair up two to a row,
        // the sound and live conversion switches first.
        configureTypography(hapticValue, size: 11)
        hapticValue.numberOfLines = 1
        hapticValue.textAlignment = .right
        hapticValue.accessibilityIdentifier = "vime.setting.hapticValue"
        hapticValue.setContentHuggingPriority(.required, for: .horizontal)
        hapticValue.setContentCompressionResistancePriority(.required, for: .horizontal)
        hapticValueWidth = hapticValue.widthAnchor.constraint(equalToConstant: 0)
        haptics.setContentHuggingPriority(.defaultLow, for: .horizontal)
        haptics.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        haptics.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        haptics.onValue = { [weak self] value, settled in
            guard let self else { return }
            self.preferences.hapticIntensity = value
            self.hapticValue.text = HapticIntensity.description(value)
            if settled { self.onFeedback?() }
        }
        let vibration = label(String(localized: "振动"))
        vibration.numberOfLines = 1
        vibration.setContentHuggingPriority(.required, for: .horizontal)
        vibration.setContentCompressionResistancePriority(.required, for: .horizontal)
        let hapticRow = row(symbol: "iphone.radiowaves.left.and.right", content: [vibration, haptics, hapticValue], height: 46, adaptive: true)
        accessibleSliderWidth = haptics.widthAnchor.constraint(equalTo: haptics.superview!.widthAnchor)

        sound.accessibilityLabel = String(localized: "按键声音"); sound.accessibilityIdentifier = "vime.setting.sound"
        sound.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.preferences.sound = self.sound.isOn
        }, for: .valueChanged)
        let soundGroup = group(row(symbol: "speaker.wave.2", content: [label("按键声音"), sound], height: 44, adaptive: true, compact: true))

        // Live conversion is a matter of taste; try it without leaving the keyboard.
        liveConversion.accessibilityLabel = String(localized: "实时转换")
        liveConversion.accessibilityIdentifier = "vime.setting.liveConversion"
        liveConversion.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.preferences.liveConversion = self.liveConversion.isOn
            self.onLiveConversionChange?()
        }, for: .valueChanged)
        let liveConversionGroup = group(row(symbol: "character.textbox",
            content: [label(String(localized: "实时转换")), liveConversion], height: 44, adaptive: true, compact: true))
        self.liveConversionGroup = liveConversionGroup
        stack.addArrangedSubview(pair(soundGroup, liveConversionGroup))
        stack.addArrangedSubview(group(hapticRow))

        numbers.accessibilityLabel = String(localized: "数字键盘布局"); numbers.accessibilityIdentifier = "vime.setting.numbers"
        numbers.setContentHuggingPriority(.required, for: .horizontal)
        numbers.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        numbers.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.preferences.nineKeyNumbers = self.numbers.selectedSegmentIndex == 0
            self.updateNumberSelection()
            self.onNumberLayoutChange?()
        }, for: .valueChanged)
        accessibleNumbers.axis = .vertical; accessibleNumbers.spacing = 4
        for (index, title) in ["九宫格", "全键盘"].enumerated() {
            let button = UIButton(type: .custom)
            button.setTitle(title, for: .normal)
            button.contentHorizontalAlignment = .left
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.accessibilityIdentifier = "vime.setting.numbers.\(index)"
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.preferences.nineKeyNumbers = index == 0
                self.updateNumberSelection()
                self.onNumberLayoutChange?()
            }, for: .touchUpInside)
            numberChoices.append(button); accessibleNumbers.addArrangedSubview(button)
        }
        let layouts = UIStackView(arrangedSubviews: [numbers, accessibleNumbers])
        layouts.axis = .vertical
        let numbersGroup = group(tile(symbol: "square.grid.2x2", title: String(localized: "数字布局"), control: layouts))

        oneHanded.accessibilityLabel = String(localized: "单手模式"); oneHanded.accessibilityIdentifier = "vime.setting.oneHanded"
        oneHanded.setContentHuggingPriority(.required, for: .horizontal)
        oneHanded.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.preferences.oneHanded = KeyboardOneHandedSide.allCases[self.oneHanded.selectedSegmentIndex]
            self.onOneHandedChange?()
        }, for: .valueChanged)
        let oneHandedGroup = group(tile(symbol: "keyboard.onehanded.left", title: String(localized: "单手模式"), control: oneHanded))
        self.oneHandedGroup = oneHandedGroup
        chineseLayout.accessibilityLabel = String(localized: "键盘布局")
        chineseLayout.accessibilityIdentifier = "vime.setting.chineseLayout"
        chineseLayout.setContentHuggingPriority(.required, for: .horizontal)
        chineseLayout.addAction(UIAction { [weak self] _ in
            guard let self, Self.chineseLayouts.indices.contains(self.chineseLayout.selectedSegmentIndex) else { return }
            self.preferences.chineseLayout = Self.chineseLayouts[self.chineseLayout.selectedSegmentIndex]
            self.onChineseLayoutChange?()
        }, for: .valueChanged)
        let chineseLayoutGroup = group(row(symbol: "keyboard", content: [label(String(localized: "键盘布局")), chineseLayout],
            height: 48, adaptive: true))
        chineseLayoutGroup.isHidden = !showsChineseLayout
        self.chineseLayoutGroup = chineseLayoutGroup
        stack.addArrangedSubview(chineseLayoutGroup)
        stack.addArrangedSubview(pair(numbersGroup, oneHandedGroup))

        inputLanguage.accessibilityLabel = String(localized: "输入语言"); inputLanguage.accessibilityIdentifier = "vime.setting.inputLanguage"
        inputLanguage.setContentHuggingPriority(.required, for: .horizontal)
        inputLanguage.addAction(UIAction { [weak self] _ in
            guard let self, Self.languages.indices.contains(self.inputLanguage.selectedSegmentIndex) else { return }
            self.onInputLanguageChange?(Self.languages[self.inputLanguage.selectedSegmentIndex])
        }, for: .valueChanged)
        let inputLanguageGroup = group(row(symbol: "globe", content: [label(String(localized: "输入语言")), inputLanguage],
            height: 48, adaptive: true))
        inputLanguageGroup.isHidden = !showsInputLanguage
        self.inputLanguageGroup = inputLanguageGroup
        stack.addArrangedSubview(inputLanguageGroup)

        configureTypography(notice, size: 12)
        notice.text = String(localized: "声音与振动需允许完全访问")
        stack.addArrangedSubview(notice)
        configureTypography(neuralStatus, size: 12)
        neuralStatus.text = String(localized: "内存紧张后已暂停智能排序，词典输入仍可用。点击下方按钮可重试。")
        neuralStatus.accessibilityIdentifier = "vime.settings.neural.status"
        stack.addArrangedSubview(neuralStatus)
        let retryRow = row(symbol: "arrow.clockwise", content: [label("重试智能排序"), icon("chevron.right", size: 13)], height: 44)
        retryRow.isUserInteractionEnabled = false
        retryRow.translatesAutoresizingMaskIntoConstraints = false
        retryNeural.addSubview(retryRow)
        NSLayoutConstraint.activate([retryRow.leadingAnchor.constraint(equalTo: retryNeural.leadingAnchor),
            retryRow.trailingAnchor.constraint(equalTo: retryNeural.trailingAnchor),
            retryRow.topAnchor.constraint(equalTo: retryNeural.topAnchor),
            retryRow.bottomAnchor.constraint(equalTo: retryNeural.bottomAnchor)])
        retryNeural.accessibilityLabel = String(localized: "重试智能排序")
        retryNeural.accessibilityIdentifier = "vime.settings.neural.retry"
        retryNeural.addAction(UIAction { [weak self] _ in self?.onRetryNeural?() }, for: .touchUpInside)
        let retryGroup = group(retryNeural)
        self.retryGroup = retryGroup
        stack.addArrangedSubview(retryGroup)
        updateTypography()
        applyTheme()
        update(hasFullAccess: true, neuralPaused: false)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (panel: KeyboardSettingsPanel, _: UITraitCollection) in
            panel.updateTypography()
            panel.applyTheme()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContentMargins(left: CGFloat, right: CGFloat) {
        horizontal[0].constant = left; horizontal[1].constant = -right
        horizontal[2].constant = -left - right
    }

    func update(hasFullAccess: Bool, neuralPaused: Bool) {
        sound.isOn = preferences.sound
        liveConversion.isOn = preferences.liveConversion
        updateLiveConversion()
        updateNumberSelection()
        oneHanded.selectedSegmentIndex = KeyboardOneHandedSide.allCases.firstIndex(of: preferences.oneHanded) ?? 0
        inputLanguage.selectedSegmentIndex = Self.languages.firstIndex(of: preferences.inputLanguage) ?? 0
        chineseLayout.selectedSegmentIndex = Self.chineseLayouts.firstIndex(of: preferences.chineseLayout) ?? 0
        if !haptics.isAdjusting {
            haptics.setIntensity(preferences.hapticIntensity)
            hapticValue.text = HapticIntensity.description(preferences.hapticIntensity)
        }
        notice.isHidden = hasFullAccess
        neuralStatus.isHidden = !neuralPaused
        retryGroup?.isHidden = !neuralPaused
    }

    private func updateLiveConversion() {
        liveConversionGroup?.isHidden = !showsLiveConversion || !preferences.japaneseInputEnabled
        updatePairs()
    }

    func applyTheme() {
        groups.forEach { $0.backgroundColor = KeyboardPalette.key }
        icons.forEach { $0.tintColor = KeyboardPalette.text }
        labels.forEach { $0.textColor = KeyboardPalette.text }
        for item in [hapticValue, notice, neuralStatus] { item.textColor = KeyboardPalette.text.withAlphaComponent(0.6) }
        sound.onTintColor = KeyboardPalette.accent
        liveConversion.onTintColor = KeyboardPalette.accent
        haptics.tintColor = KeyboardPalette.accent
        numbers.selectedSegmentTintColor = KeyboardPalette.accent.withAlphaComponent(0.16)
        numbers.setTitleTextAttributes([.foregroundColor: KeyboardPalette.text, .font: scaledFont(size: 13)], for: .normal)
        numbers.setTitleTextAttributes([.foregroundColor: KeyboardPalette.accent, .font: scaledFont(size: 13, weight: .medium)], for: .selected)
        oneHanded.selectedSegmentTintColor = numbers.selectedSegmentTintColor
        oneHanded.setTitleTextAttributes(numbers.titleTextAttributes(for: .normal), for: .normal)
        oneHanded.setTitleTextAttributes(numbers.titleTextAttributes(for: .selected), for: .selected)
        inputLanguage.selectedSegmentTintColor = numbers.selectedSegmentTintColor
        inputLanguage.setTitleTextAttributes(numbers.titleTextAttributes(for: .normal), for: .normal)
        inputLanguage.setTitleTextAttributes(numbers.titleTextAttributes(for: .selected), for: .selected)
        chineseLayout.selectedSegmentTintColor = numbers.selectedSegmentTintColor
        chineseLayout.setTitleTextAttributes(numbers.titleTextAttributes(for: .normal), for: .normal)
        chineseLayout.setTitleTextAttributes(numbers.titleTextAttributes(for: .selected), for: .selected)
        updateNumberSelection()
    }
    private func updateNumberSelection() {
        numbers.selectedSegmentIndex = preferences.nineKeyNumbers ? 0 : 1
        for (index, button) in numberChoices.enumerated() {
            let selected = index == numbers.selectedSegmentIndex
            button.setImage(UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"), for: .normal)
            button.tintColor = selected ? KeyboardPalette.accent : KeyboardPalette.text
            button.setTitleColor(KeyboardPalette.text, for: .normal)
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        var current: UIView? = view
        while let item = current, item !== self {
            if item is UISlider { return false }
            current = item.superview
        }
        return super.touchesShouldCancel(in: view)
    }

    private func label(_ text: String, size: CGFloat = 15, weight: UIFont.Weight = .regular) -> UILabel {
        let value = UILabel(); value.text = text
        configureTypography(value, size: size, weight: weight)
        value.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        labels.append(value); return value
    }
    private func scaledFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: size < 15 ? .caption1 : .body)
            .scaledFont(for: .systemFont(ofSize: size, weight: weight), compatibleWith: traitCollection)
    }
    private func configureTypography(_ label: UILabel, size: CGFloat, weight: UIFont.Weight = .regular) {
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        typography.append((label, size, weight))
    }
    private func updateTypography() {
        let accessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        shortcuts.axis = accessibilitySize ? .vertical : .horizontal
        shortcuts.distribution = accessibilitySize ? .fill : .fillEqually
        for (label, size, weight) in typography { label.font = scaledFont(size: size, weight: weight) }
        for row in adaptiveRows {
            row.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
            row.alignment = row.axis == .vertical ? .leading : .center
        }
        accessibleSliderWidth?.isActive = accessibilitySize
        hapticValue.numberOfLines = accessibilitySize ? 0 : 1
        hapticValue.textAlignment = accessibilitySize ? .left : .right
        if let font = hapticValue.font {
            let maxWidth = [0.0, 0.25, 0.6, 1.0].map {
                ceil((HapticIntensity.description($0) as NSString).size(withAttributes: [.font: font]).width)
            }.max() ?? 0
            hapticValueWidth?.constant = maxWidth + 2
        }
        hapticValueWidth?.isActive = !accessibilitySize
        updatePairs()
        numbers.isHidden = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        accessibleNumbers.isHidden = !numbers.isHidden
        for button in numberChoices { button.titleLabel?.font = scaledFont(size: 15) }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        for row in compactRows where row.bounds.width > 0 {
            guard let icon = row.arrangedSubviews.first, let body = row.arrangedSubviews.last as? UIStackView else { continue }
            let content = body.arrangedSubviews.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
                + body.spacing * CGFloat(max(0, body.arrangedSubviews.count - 1))
            let needed = row.layoutMargins.left + row.layoutMargins.right + 24 + row.spacing + content
            let hide = !large && row.bounds.width < needed
            if icon.isHidden != hide { icon.isHidden = hide; row.setNeedsLayout() }
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateTypography()
        applyTheme()
    }
    private func icon(_ name: String, size: CGFloat = 21) -> UIImageView {
        let value = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size)))
        value.contentMode = .scaleAspectFit
        value.widthAnchor.constraint(equalToConstant: size == 13 ? 14 : 24).isActive = true
        icons.append(value); return value
    }
    private func row(symbol: String, content: [UIView], height: CGFloat, adaptive: Bool = false, compact: Bool = false) -> UIStackView {
        let body = UIStackView(arrangedSubviews: content)
        body.alignment = .center; body.spacing = compact ? 6 : 10
        if adaptive { adaptiveRows.append(body) }
        let value = UIStackView(arrangedSubviews: [icon(symbol), body])
        value.alignment = .center; value.spacing = compact ? 8 : 10
        value.isLayoutMarginsRelativeArrangement = true
        let side: CGFloat = compact ? 12 : 14
        value.layoutMargins = UIEdgeInsets(top: 8, left: side, bottom: 8, right: side)
        if compact {
            compactRows.append(value)
            // A narrow half row squeezes the title, never the switch.
            for view in content where view is UISwitch { view.setContentCompressionResistancePriority(.required, for: .horizontal) }
            // Its title keeps to one line, shrinking a little on the narrowest
            // phones, so the pair stays as short as a single row.
            for case let title as UILabel in content { title.adjustsFontSizeToFitWidth = true; title.minimumScaleFactor = 0.7 }
        }
        value.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        return value
    }
    /// An icon and title over a control, for half a row.
    private func tile(symbol: String, title: String, control: UIView) -> UIStackView {
        let heading = UIStackView(arrangedSubviews: [icon(symbol, size: 17), label(title)])
        heading.alignment = .center; heading.spacing = 8
        let value = UIStackView(arrangedSubviews: [heading, control])
        value.spacing = 8
        value.isLayoutMarginsRelativeArrangement = true
        value.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        value.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        tiles.append(value); return value
    }
    private func pair(_ first: UIView, _ second: UIView) -> UIStackView {
        let value = UIStackView(arrangedSubviews: [first, second])
        value.spacing = 8; value.distribution = .fillEqually; value.alignment = .fill
        pairs.append(value); return value
    }
    /// Pairs stack at large text sizes, and a tile with its partner hidden
    /// spreads into a row instead of leaving its control under the title.
    private func updatePairs() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        for row in compactRows {
            for case let title as UILabel in (row.arrangedSubviews.last as? UIStackView)?.arrangedSubviews ?? [] { title.numberOfLines = large ? 0 : 1 }
        }
        for pair in pairs {
            pair.axis = large ? .vertical : .horizontal
            pair.distribution = large ? .fill : .fillEqually
            pair.isHidden = pair.arrangedSubviews.allSatisfy(\.isHidden)
            let together = !large && pair.arrangedSubviews.filter { !$0.isHidden }.count == 2
            for tile in tiles where tile.isDescendant(of: pair) {
                tile.axis = together || large ? .vertical : .horizontal
                tile.alignment = tile.axis == .vertical ? .fill : .center
            }
        }
    }
    private func group(_ content: UIView) -> UIView {
        let value = UIView(); value.layer.cornerRadius = 14; value.layer.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        value.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: value.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: value.trailingAnchor), content.topAnchor.constraint(equalTo: value.topAnchor),
            content.bottomAnchor.constraint(equalTo: value.bottomAnchor)])
        groups.append(value); return value
    }
}
