import UIKit

nonisolated struct KeyboardQuickCandidate: Equatable {
    enum Action: Equatable {
        case symbol(String), clipboard(String), replacement(KeyboardTextReplacement)
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
            switch items[index].action {
            case .clipboard:
                button.accessibilityIdentifier = "vime.clipboard.paste"
                button.accessibilityHint = "输入剪贴板的完整文本"
            case .replacement:
                button.accessibilityIdentifier = "vime.calculation.\(index)"
                button.accessibilityHint = "替换光标前的完整算式"
            case .symbol:
                button.accessibilityIdentifier = "vime.quickSymbol.\(items[index].title)"
                button.accessibilityHint = "输入符号"
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
            let measured = (button.title(for: .normal)! as NSString).size(withAttributes: [.font: button.titleLabel!.font!]).width + 24
            let width = min(max(44, measured), max(44, bounds.width))
            button.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + 2
        }
        contentSize = CGSize(width: max(0, x - 2), height: bounds.height)
    }

    func applyTheme() { for button in buttons { button.setTitleColor(KeyboardPalette.text, for: .normal) } }

    private final class QuickButton: UIButton {
        var item: KeyboardQuickCandidate?
        private var armed = false
        private var touchedItem: KeyboardQuickCandidate?
        override init(frame: CGRect) {
            super.init(frame: frame)
            addTarget(self, action: #selector(arm), for: .touchDown)
            addTarget(self, action: #selector(cancel), for: [.touchCancel, .touchUpOutside])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func arm() { armed = true; touchedItem = item }
        @objc private func cancel() { armed = false; touchedItem = nil }
        func takeItem() -> KeyboardQuickCandidate? {
            let value = armed ? touchedItem : item
            cancel(); return value
        }
    }
}
