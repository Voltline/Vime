import UIKit

/// Native scrolling owns this column, independently of cursor/key gestures.
/// Editing lives in the containing app, outside the keyboard process.
final class KeyboardNumberSymbolRail: UIScrollView {
    private(set) var symbols: [String] = []
    private var buttons: [UIButton] = []
    private var separators: [UIView] = []
    private let settingsLink = UIButton(type: .system)
    var onSelect: ((String) -> Void)?
    var onEdit: (() -> Void)?
    var scale: CGFloat = 1
    /// Without the settings link (the nine-key syllable rail).
    var editable = true { didSet { settingsLink.isHidden = !editable; setNeedsLayout() } }
    /// Accessibility IDs of the items: this, then the item.
    var identifierPrefix = "vime.number."
    /// The item drawn in the accent colour, such as the syllable Rime reads.
    var highlighted: String? { didSet { if highlighted != oldValue { applyTheme() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "vime.numberSymbols"
        accessibilityLabel = String(localized: "常用符号")
        accessibilityHint = String(localized: "上下滑动选择符号，底部的编辑入口可打开 Vime 设置")
        alwaysBounceVertical = true
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        canCancelContentTouches = true
        delaysContentTouches = true
        clipsToBounds = true
        settingsLink.setTitle(String(localized: "编辑 ↗"), for: .normal)
        settingsLink.titleLabel?.font = .systemFont(ofSize: 12)
        settingsLink.accessibilityLabel = String(localized: "在 Vime App 中编辑常用符号")
        settingsLink.accessibilityIdentifier = "vime.numberSymbols.edit"
        settingsLink.addAction(UIAction { [weak self] _ in self?.onEdit?() }, for: .touchUpInside)
        addSubview(settingsLink)
        if #available(iOS 26.0, *) {
            for edge in [topEdgeEffect, bottomEdgeEffect, leftEdgeEffect, rightEdgeEffect] { edge.isHidden = true }
        }
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(revealSettings(_:))))
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ symbols: [String]) {
        guard self.symbols != symbols || buttons.isEmpty else { return }
        self.symbols = symbols
        buttons.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        buttons = symbols.map { symbol in
            let button = UIButton(type: .system)
            button.setTitle(KeyboardNumberSymbols.title(for: symbol), for: .normal)
            button.accessibilityIdentifier = identifierPrefix + symbol
            button.accessibilityLabel = symbol
            button.addAction(UIAction { [weak self] _ in
                guard let self, !self.isHidden, self.symbols.contains(symbol) else { return }
                self.onSelect?(symbol)
            }, for: .touchUpInside)
            addSubview(button)
            return button
        }
        separators = symbols.map { _ in let line = UIView(); line.isUserInteractionEnabled = false; addSubview(line); return line }
        setContentOffset(.zero, animated: false)
        applyTheme()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let itemHeight = max(30, bounds.height / 4.25)
        layer.cornerRadius = 6.2 * scale
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: 0, y: CGFloat(index) * itemHeight, width: bounds.width, height: itemHeight)
            button.titleLabel?.font = .systemFont(ofSize: min(19, 17 * scale))
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.5
            separators[index].frame = CGRect(x: 8, y: button.frame.maxY - 0.5,
                width: max(0, bounds.width - 16), height: 0.5)
        }
        settingsLink.frame = CGRect(x: 0, y: CGFloat(buttons.count) * itemHeight,
            width: bounds.width, height: max(36, itemHeight))
        contentSize = CGSize(width: bounds.width, height: editable ? settingsLink.frame.maxY : CGFloat(buttons.count) * itemHeight)
    }

    override func touchesShouldCancel(in view: UIView) -> Bool { true }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -6 * scale, dy: -5 * scale).contains(point)
    }

    @objc private func revealSettings(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, editable else { return }
        scrollRectToVisible(settingsLink.frame, animated: true)
    }

    func applyTheme() {
        backgroundColor = KeyboardPalette.utility
        for (symbol, button) in zip(symbols, buttons) {
            button.setTitleColor(symbol == highlighted ? KeyboardPalette.accent : KeyboardPalette.text, for: .normal)
        }
        separators.forEach { $0.backgroundColor = KeyboardPalette.text.withAlphaComponent(0.12) }
        settingsLink.setTitleColor(KeyboardPalette.accent, for: .normal)
        setNeedsLayout()
    }
}
