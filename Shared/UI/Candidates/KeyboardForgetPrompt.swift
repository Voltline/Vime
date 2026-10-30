import UIKit

/// Asks before removing what Vime learned for a long-pressed candidate. It
/// covers the toolbar row, which both the strip and the expanded panel keep.
final class KeyboardForgetPrompt: UIView {
    private let label = UILabel()
    let confirm = UIButton(type: .system)
    let cancel = UIButton(type: .system)
    /// The candidate the question is about; a new list invalidates it.
    var token: CandidateSelectionToken?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "vime.forget.prompt"
        label.font = .systemFont(ofSize: 15)
        label.lineBreakMode = .byTruncatingMiddle
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        for (button, title, identifier) in [(confirm, String(localized: "删除"), "vime.forget.confirm"),
                                            (cancel, String(localized: "取消"), "vime.forget.cancel")] {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.accessibilityIdentifier = identifier
            button.layer.cornerCurve = .continuous
            addSubview(button)
        }
        addSubview(label)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ text: String, token: CandidateSelectionToken) {
        self.token = token
        label.text = String(localized: "删除「\(text)」的学习记录？")
        isHidden = false
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = min(bounds.height, 36)
        let y = (bounds.height - height) / 2
        var right = bounds.width
        for button in [cancel, confirm] {
            let width = max(56, ceil(button.intrinsicContentSize.width) + 20)
            button.frame = CGRect(x: right - width, y: y, width: width, height: height)
            button.layer.cornerRadius = height / 2
            right = button.frame.minX - 6
        }
        label.frame = CGRect(x: 8, y: 0, width: max(0, right - 14), height: bounds.height)
    }

    func applyTheme() {
        label.textColor = KeyboardPalette.text
        confirm.backgroundColor = KeyboardPalette.key
        confirm.tintColor = .systemRed
        cancel.backgroundColor = KeyboardPalette.key
        cancel.tintColor = KeyboardPalette.text
    }
}
