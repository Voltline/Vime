import UIKit

/// Compact groups for settings that can be changed without leaving the keyboard.
final class KeyboardSettingsPanel: UIScrollView {
    private let preferences: KeyboardPreferences
    private let stack = UIStackView()
    private let history = UIButton(type: .custom)
    private let sound = UISwitch()
    private let haptics = HapticIntensitySlider()
    private let hapticValue = UILabel()
    private let numbers = UISegmentedControl(items: ["九宫格", "全键盘"])
    private let notice = UILabel()
    private let neuralStatus = UILabel()
    private var groups: [UIView] = []
    private var icons: [UIImageView] = []
    private var labels: [UILabel] = []
    private var horizontal: [NSLayoutConstraint] = []
    var onHistory: (() -> Void)?
    var onFeedback: (() -> Void)?
    var onNumberLayoutChange: (() -> Void)?

    init(preferences: KeyboardPreferences) {
        self.preferences = preferences
        super.init(frame: .zero)
        accessibilityIdentifier = "vime.settings"
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

        let historyText = UIStackView(arrangedSubviews: [label("剪贴板历史", weight: .medium), label("最近 24 小时", size: 12)])
        historyText.axis = .vertical; historyText.spacing = 3
        historyText.arrangedSubviews.last?.alpha = 0.6
        let arrow = icon("chevron.right", size: 13)
        let historyRow = row(symbol: "clipboard", content: [historyText, arrow], height: 54)
        history.addSubview(historyRow)
        historyRow.isUserInteractionEnabled = false
        historyRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([historyRow.leadingAnchor.constraint(equalTo: history.leadingAnchor),
            historyRow.trailingAnchor.constraint(equalTo: history.trailingAnchor),
            historyRow.topAnchor.constraint(equalTo: history.topAnchor),
            historyRow.bottomAnchor.constraint(equalTo: history.bottomAnchor)])
        history.accessibilityIdentifier = "vime.setting.clipboardHistory"
        history.accessibilityLabel = "剪贴板历史"
        history.accessibilityValue = "最近 24 小时"
        history.addAction(UIAction { [weak self] _ in self?.onHistory?() }, for: .touchUpInside)
        stack.addArrangedSubview(group(history))

        sound.accessibilityLabel = "按键声音"; sound.accessibilityIdentifier = "vime.setting.sound"
        sound.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.preferences.sound = self.sound.isOn
        }, for: .valueChanged)
        let soundRow = row(symbol: "speaker.wave.2", content: [label("按键声音"), sound], height: 44)
        hapticValue.font = .systemFont(ofSize: 11)
        hapticValue.textAlignment = .right
        hapticValue.accessibilityIdentifier = "vime.setting.hapticValue"
        hapticValue.widthAnchor.constraint(equalToConstant: 66).isActive = true
        haptics.setContentHuggingPriority(.defaultLow, for: .horizontal)
        haptics.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        haptics.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        haptics.onValue = { [weak self] value, settled in
            guard let self else { return }
            self.preferences.hapticIntensity = value
            self.hapticValue.text = HapticIntensity.description(value)
            if settled { self.onFeedback?() }
        }
        let vibration = label("振动")
        vibration.setContentHuggingPriority(.required, for: .horizontal)
        let hapticRow = row(symbol: "iphone.radiowaves.left.and.right", content: [vibration, haptics, hapticValue], height: 46)
        let feedback = UIStackView(arrangedSubviews: [soundRow, separator(), hapticRow])
        feedback.axis = .vertical
        stack.addArrangedSubview(group(feedback))

        numbers.accessibilityLabel = "数字键盘布局"; numbers.accessibilityIdentifier = "vime.setting.numbers"
        numbers.setContentHuggingPriority(.required, for: .horizontal)
        numbers.widthAnchor.constraint(equalToConstant: 150).isActive = true
        numbers.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.preferences.nineKeyNumbers = self.numbers.selectedSegmentIndex == 0
            self.onNumberLayoutChange?()
        }, for: .valueChanged)
        stack.addArrangedSubview(group(row(symbol: "square.grid.2x2", content: [label("数字布局"), numbers], height: 48)))

        notice.font = .systemFont(ofSize: 12); notice.numberOfLines = 0
        notice.text = "更多设置，请打开 Vime App"
        stack.addArrangedSubview(notice)
        neuralStatus.font = .systemFont(ofSize: 12); neuralStatus.numberOfLines = 0
        neuralStatus.text = "神经候选暂时停用，词典输入仍可用。可在 Vime App 中重新开启神经候选。"
        neuralStatus.accessibilityIdentifier = "vime.settings.neural.status"
        stack.addArrangedSubview(neuralStatus)
        applyTheme()
        update(hasFullAccess: true, neuralPaused: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContentMargins(left: CGFloat, right: CGFloat) {
        horizontal[0].constant = left; horizontal[1].constant = -right
        horizontal[2].constant = -left - right
    }

    func update(hasFullAccess: Bool, neuralPaused: Bool) {
        sound.isOn = preferences.sound
        numbers.selectedSegmentIndex = preferences.nineKeyNumbers ? 0 : 1
        if !haptics.isAdjusting {
            haptics.setIntensity(preferences.hapticIntensity)
            hapticValue.text = HapticIntensity.description(preferences.hapticIntensity)
        }
        notice.text = hasFullAccess ? "更多设置，请打开 Vime App" : "声音与振动需允许完全访问 · 更多设置请打开 Vime App"
        neuralStatus.isHidden = !neuralPaused
    }

    func applyTheme() {
        groups.forEach { $0.backgroundColor = KeyboardPalette.key }
        icons.forEach { $0.tintColor = KeyboardPalette.text }
        labels.forEach { $0.textColor = KeyboardPalette.text }
        for item in [hapticValue, notice, neuralStatus] { item.textColor = KeyboardPalette.text.withAlphaComponent(0.6) }
        sound.onTintColor = KeyboardPalette.accent
        haptics.tintColor = KeyboardPalette.accent
        numbers.selectedSegmentTintColor = KeyboardPalette.accent.withAlphaComponent(0.16)
        numbers.setTitleTextAttributes([.foregroundColor: KeyboardPalette.text, .font: UIFont.systemFont(ofSize: 13)], for: .normal)
        numbers.setTitleTextAttributes([.foregroundColor: KeyboardPalette.accent, .font: UIFont.systemFont(ofSize: 13, weight: .medium)], for: .selected)
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
        let value = UILabel(); value.text = text; value.font = .systemFont(ofSize: size, weight: weight)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        labels.append(value); return value
    }
    private func icon(_ name: String, size: CGFloat = 21) -> UIImageView {
        let value = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size)))
        value.contentMode = .scaleAspectFit
        value.widthAnchor.constraint(equalToConstant: size == 13 ? 14 : 24).isActive = true
        icons.append(value); return value
    }
    private func row(symbol: String, content: [UIView], height: CGFloat) -> UIStackView {
        let value = UIStackView(arrangedSubviews: [icon(symbol)] + content)
        value.alignment = .center; value.spacing = 10
        value.isLayoutMarginsRelativeArrangement = true
        value.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        value.heightAnchor.constraint(equalToConstant: height).isActive = true
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
