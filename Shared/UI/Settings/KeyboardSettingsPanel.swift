import UIKit

/// Compact groups for settings that can be changed without leaving the keyboard.
final class KeyboardSettingsPanel: UIScrollView {
    private let preferences: KeyboardPreferences
    private let stack = UIStackView()
    private let shortcuts = UIStackView()
    private let history = UIButton(type: .custom)
    private let sound = UISwitch()
    private let haptics = HapticIntensitySlider()
    private let hapticValue = UILabel()
    private let numbers = UISegmentedControl(items: ["九宫格", "全键盘"])
    private let accessibleNumbers = UIStackView()
    private var numberChoices: [UIButton] = []
    private let notice = UILabel()
    private let neuralStatus = UILabel()
    private let retryNeural = UIButton(type: .custom)
    private var retryGroup: UIView?
    private var adaptiveRows: [UIStackView] = []
    private var accessibleSliderWidth: NSLayoutConstraint?
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


        sound.accessibilityLabel = "按键声音"; sound.accessibilityIdentifier = "vime.setting.sound"
        sound.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.preferences.sound = self.sound.isOn
        }, for: .valueChanged)
        let soundRow = row(symbol: "speaker.wave.2", content: [label("按键声音"), sound], height: 44, adaptive: true)
        configureTypography(hapticValue, size: 11)
        hapticValue.textAlignment = .right
        hapticValue.accessibilityIdentifier = "vime.setting.hapticValue"
        hapticValue.setContentHuggingPriority(.required, for: .horizontal)
        hapticValue.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        vibration.setContentHuggingPriority(.required, for: .horizontal)
        let hapticRow = row(symbol: "iphone.radiowaves.left.and.right", content: [vibration, haptics, hapticValue], height: 46, adaptive: true)
        accessibleSliderWidth = haptics.widthAnchor.constraint(equalTo: haptics.superview!.widthAnchor)
        let feedback = UIStackView(arrangedSubviews: [soundRow, separator(), hapticRow])
        feedback.axis = .vertical
        stack.addArrangedSubview(group(feedback))

        numbers.accessibilityLabel = String(localized: "数字键盘布局"); numbers.accessibilityIdentifier = "vime.setting.numbers"
        numbers.setContentHuggingPriority(.required, for: .horizontal)
        numbers.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
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
        stack.addArrangedSubview(group(row(symbol: "square.grid.2x2", content: [label("数字布局"), layouts], height: 48, adaptive: true)))

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
        retryNeural.accessibilityLabel = "重试智能排序"
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
        updateNumberSelection()
        if !haptics.isAdjusting {
            haptics.setIntensity(preferences.hapticIntensity)
            hapticValue.text = HapticIntensity.description(preferences.hapticIntensity)
        }
        notice.isHidden = hasFullAccess
        neuralStatus.isHidden = !neuralPaused
        retryGroup?.isHidden = !neuralPaused
    }

    func applyTheme() {
        groups.forEach { $0.backgroundColor = KeyboardPalette.key }
        icons.forEach { $0.tintColor = KeyboardPalette.text }
        labels.forEach { $0.textColor = KeyboardPalette.text }
        for item in [hapticValue, notice, neuralStatus] { item.textColor = KeyboardPalette.text.withAlphaComponent(0.6) }
        sound.onTintColor = KeyboardPalette.accent
        haptics.tintColor = KeyboardPalette.accent
        numbers.selectedSegmentTintColor = KeyboardPalette.accent.withAlphaComponent(0.16)
        numbers.setTitleTextAttributes([.foregroundColor: KeyboardPalette.text, .font: scaledFont(size: 13)], for: .normal)
        numbers.setTitleTextAttributes([.foregroundColor: KeyboardPalette.accent, .font: scaledFont(size: 13, weight: .medium)], for: .selected)
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
        accessibleSliderWidth?.isActive = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        numbers.isHidden = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        accessibleNumbers.isHidden = !numbers.isHidden
        for button in numberChoices { button.titleLabel?.font = scaledFont(size: 15) }
        setNeedsLayout()
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
    private func row(symbol: String, content: [UIView], height: CGFloat, adaptive: Bool = false) -> UIStackView {
        let body = UIStackView(arrangedSubviews: content)
        body.alignment = .center; body.spacing = 10
        if adaptive { adaptiveRows.append(body) }
        let value = UIStackView(arrangedSubviews: [icon(symbol), body])
        value.alignment = .center; value.spacing = 10
        value.isLayoutMarginsRelativeArrangement = true
        value.layoutMargins = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        value.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        return value
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
    private func separator() -> UIView {
        let container = UIView(), line = UIView()
        line.backgroundColor = .separator; line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        container.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 48),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: container.topAnchor), line.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        return container
    }
}
