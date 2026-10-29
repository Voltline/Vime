import UIKit

nonisolated struct KeyboardQuickCandidate: Equatable {
    enum Action: Equatable {
        case symbol(String), replacement(KeyboardTextReplacement)
        /// An emoji search result; replaces the reading being typed.
        case emoji(String)
        /// Explanatory text in the strip; not selectable.
        case prompt
        /// Turns the selected text back into its reading for conversion.
        case reconvert(String)
    }
    let title: String
    let action: Action
}

/// Utility candidates do not enter the converter/learning pipeline. Capture
/// the touched item before a refresh can repurpose the underlying button.
final class KeyboardQuickCandidateStrip: UIScrollView {
    private var buttons: [QuickButton] = []
    private(set) var items: [KeyboardQuickCandidate] = []
    var onSelect: ((KeyboardQuickCandidate) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        accessibilityIdentifier = "vime.quickCandidates"
        backgroundColor = KeyboardTouchBacking.color
        if #available(iOS 26.0, *) {
            for edge in [topEdgeEffect, bottomEdgeEffect, leftEdgeEffect, rightEdgeEffect] { edge.isHidden = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ items: [KeyboardQuickCandidate]) {
        guard self.items != items else { return }
        self.items = items
        while buttons.count > items.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < items.count {
            let button = QuickButton(type: .custom)
            button.addTarget(self, action: #selector(selectItem(_:)), for: .touchUpInside)
            buttons.append(button); addSubview(button)
        }
        for (index, button) in buttons.enumerated() {
            button.item = items[index]
            button.setTitle(items[index].title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 18, weight: index == 0 ? .medium : .regular)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.accessibilityLabel = items[index].title
            button.isEnabled = items[index].action != .prompt
            switch items[index].action {
            case .replacement:
                button.primaryResult = index == 0
                button.accessibilityIdentifier = "vime.calculation.\(index)"
                button.accessibilityHint = String(localized: "替换光标前的完整算式")
            case .symbol:
                button.primaryResult = false
                button.accessibilityIdentifier = "vime.quickSymbol.\(items[index].title)"
                button.accessibilityHint = String(localized: "输入符号")
            case .emoji:
                button.primaryResult = false
                button.accessibilityIdentifier = "vime.emojiResult.\(items[index].title)"
                button.accessibilityHint = String(localized: "输入符号")
            case .prompt:
                button.primaryResult = false
                button.accessibilityIdentifier = "vime.emojiSearch.prompt"
                button.accessibilityHint = nil
            case .reconvert:
                button.primaryResult = false
                button.accessibilityIdentifier = "vime.reconvert"
                button.accessibilityHint = nil
            }
        }
        applyTheme()
        setContentOffset(.zero, animated: false)
        setNeedsLayout()
    }

    @objc private func selectItem(_ sender: QuickButton) {
        guard let item = sender.takeItem(), items.contains(item) else { return }
        onSelect?(item)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for button in buttons {
            let measured = KeyboardCandidateTextMetrics.width(of: button.title(for: .normal)!, font: button.titleLabel!.font!) + 24
            let width = min(max(44, measured), max(44, bounds.width))
            button.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + 2
        }
        contentSize = CGSize(width: max(0, x - 2), height: bounds.height)
    }

    func applyTheme() {
        for button in buttons {
            button.setTitleColor(button.primaryResult ? KeyboardPalette.accent : KeyboardPalette.text, for: .normal)
            button.setTitleColor(.secondaryLabel, for: .disabled)
            button.underline.backgroundColor = KeyboardPalette.accent
        }
    }

    private final class QuickButton: UIButton {
        let underline = UIView()
        var primaryResult = false { didSet { underline.isHidden = !primaryResult } }
        var item: KeyboardQuickCandidate?
        private var armed = false
        private var touchedItem: KeyboardQuickCandidate?
        override init(frame: CGRect) {
            super.init(frame: frame)
            underline.isUserInteractionEnabled = false
            underline.isHidden = true
            underline.layer.cornerRadius = 1
            underline.accessibilityIdentifier = "vime.calculation.underline"
            addSubview(underline)
            addTarget(self, action: #selector(arm), for: .touchDown)
            addTarget(self, action: #selector(cancel), for: [.touchCancel, .touchUpOutside])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            let width = min(titleLabel?.intrinsicContentSize.width ?? 0, max(0, bounds.width - 24))
            let textBottom = (bounds.height + ceil(titleLabel?.font.lineHeight ?? 22)) / 2
            underline.frame = CGRect(x: (bounds.width - width) / 2,
                y: min(max(0, bounds.height - 2), ceil(textBottom + KeyboardCandidateButton.underlineGap)), width: width, height: 2)
        }
        @objc private func arm() { armed = true; touchedItem = item }
        @objc private func cancel() { armed = false; touchedItem = nil }
        func takeItem() -> KeyboardQuickCandidate? {
            let value = armed ? touchedItem : item
            cancel(); return value
        }
    }
}
