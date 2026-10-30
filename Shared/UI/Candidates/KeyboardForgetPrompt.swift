import UIKit

/// Offers to remove what Vime learned for a long-pressed candidate. It covers
/// the whole keyboard: the bubble under the candidate confirms, and a touch
/// anywhere else sends `.touchDown` to dismiss it without typing.
final class KeyboardForgetPrompt: UIControl {
    private let highlight = UIView()
    private let bubble = UIView()
    private let shape = CAShapeLayer()
    let confirm = UIButton(type: .system)
    /// The candidate the bubble is about; a new list invalidates it.
    var token: CandidateSelectionToken?
    /// The long-pressed candidate, in this view's coordinates.
    private var anchor = CGRect.zero

    private static let arrow = CGSize(width: 16, height: 8)
    private static let cardHeight: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "vime.forget.prompt"
        highlight.isUserInteractionEnabled = false
        highlight.layer.cornerCurve = .continuous
        bubble.layer.addSublayer(shape)
        bubble.layer.shadowColor = UIColor.black.cgColor
        bubble.layer.shadowOpacity = 0.18
        bubble.layer.shadowRadius = 8
        bubble.layer.shadowOffset = CGSize(width: 0, height: 2)
        confirm.setTitle(String(localized: "删除学习记录"), for: .normal)
        confirm.titleLabel?.font = .systemFont(ofSize: 16)
        confirm.accessibilityIdentifier = "vime.forget.confirm"
        bubble.addSubview(confirm)
        addSubview(highlight)
        addSubview(bubble)
        applyTheme()
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (prompt: KeyboardForgetPrompt, _: UITraitCollection) in
            prompt.applyTheme()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ text: String, token: CandidateSelectionToken, anchor: CGRect) {
        self.token = token
        self.anchor = anchor
        confirm.accessibilityLabel = String(localized: "删除「\(text)」的学习记录？")
        isHidden = false
        setNeedsLayout()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        let inBubble = confirm.convert(point, from: self)
        return confirm.bounds.contains(inBubble) ? confirm : self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pillHeight = min(anchor.height, 34)
        highlight.frame = CGRect(x: anchor.minX, y: anchor.midY - pillHeight / 2, width: anchor.width, height: pillHeight)
        highlight.layer.cornerRadius = pillHeight / 2

        let arrow = Self.arrow, cardHeight = Self.cardHeight, radius: CGFloat = 12
        let width = min(bounds.width - 16, max(120, ceil(confirm.intrinsicContentSize.width) + 40))
        let x = min(max(8, anchor.midX - width / 2), bounds.width - 8 - width)
        // Below the candidate by default; above it when the keyboard ends first.
        let below = highlight.frame.maxY + 2 + arrow.height + cardHeight <= bounds.height - 4
        let y = below ? highlight.frame.maxY + 2 : highlight.frame.minY - 2 - arrow.height - cardHeight
        bubble.frame = CGRect(x: x, y: y, width: width, height: arrow.height + cardHeight)
        let card = CGRect(x: 0, y: below ? arrow.height : 0, width: width, height: cardHeight)
        confirm.frame = card
        let tip = min(max(anchor.midX - x, radius + arrow.width / 2), width - radius - arrow.width / 2)

        let path = UIBezierPath(roundedRect: card, cornerRadius: radius)
        let base = below ? card.minY : card.maxY
        let peak = below ? 0 : bubble.bounds.height
        let triangle = UIBezierPath()
        triangle.move(to: CGPoint(x: tip - arrow.width / 2, y: base))
        triangle.addLine(to: CGPoint(x: tip, y: peak))
        triangle.addLine(to: CGPoint(x: tip + arrow.width / 2, y: base))
        triangle.close()
        path.append(triangle)
        shape.path = path.cgPath
        bubble.layer.shadowPath = path.cgPath
    }

    func applyTheme() {
        highlight.backgroundColor = KeyboardPalette.text.withAlphaComponent(0.12)
        // Skins can make keys translucent; the bubble floats over keys, so it stays opaque.
        shape.fillColor = KeyboardPalette.key.resolvedColor(with: traitCollection).withAlphaComponent(1).cgColor
        confirm.tintColor = .systemRed
    }
}
