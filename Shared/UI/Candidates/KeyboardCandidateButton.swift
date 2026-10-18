import UIKit

/// The visual selection follows the text width, independently of the button's
/// hit area or a wider cell in the expanded candidate panel.
final class KeyboardCandidateButton: UIButton {
    private let underline = UIView()
    private let annotation = UILabel()
    private var presentedPresentation: CandidatePresentation?
    private var presentedIndex: Int?
    private var presentedHighlight: Bool?
    private var measuredTextWidth: CGFloat = 0
    var presentationWidth: CGFloat { ceil(measuredTextWidth) + 24 }
    var selectionToken: CandidateSelectionToken? { presentedPresentation?.selectionToken }
    private var armedSelectionToken: CandidateSelectionToken?
    private var selectionArmed = false

    func takeSelectionToken() -> CandidateSelectionToken? {
        let token = selectionArmed ? armedSelectionToken : selectionToken
        cancelSelection()
        return token
    }

    @objc private func armSelection() {
        selectionArmed = true
        armedSelectionToken = selectionToken
    }

    @objc private func cancelSelection() {
        selectionArmed = false
        armedSelectionToken = nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // A new query may repurpose pooled buttons while a finger is down.
        // A release must resolve the touched list, never its replacement.
        addTarget(self, action: #selector(armSelection), for: .touchDown)
        addTarget(self, action: #selector(cancelSelection), for: [.touchCancel, .touchUpOutside])
        contentHorizontalAlignment = .left
        titleLabel?.textAlignment = .left
        underline.isUserInteractionEnabled = false
        underline.backgroundColor = KeyboardPalette.accent
        underline.accessibilityIdentifier = "vime.candidate.underline"
        underline.layer.cornerRadius = 1
        insertSubview(underline, at: 0)
        annotation.font = .systemFont(ofSize: 10)
        annotation.isUserInteractionEnabled = false
        annotation.lineBreakMode = .byTruncatingTail
        addSubview(annotation)
        backgroundColor = KeyboardTouchBacking.color
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ presentation: CandidatePresentation, index: Int, highlighted: Bool) {
        tag = index
        let needsMeasurement = presentation.text != presentedPresentation?.text
            || presentation.annotation != presentedPresentation?.annotation || presentedIndex != index
        if presentation != presentedPresentation {
            if presentation.text != presentedPresentation?.text { setTitle(presentation.text, for: .normal) }
            presentedPresentation = presentation
            annotation.text = presentation.annotation
            annotation.isHidden = presentation.annotation == nil
            accessibilityLabel = presentation.accessibilityLabel
            accessibilityHint = presentation.correction == nil ? "点击确认候选词" : "点击采用建议读音"
            invalidateIntrinsicContentSize()
        }
        if presentedIndex != index {
            titleLabel?.font = .systemFont(ofSize: 18, weight: index == 0 ? .medium : .regular)
            presentedIndex = index
            invalidateIntrinsicContentSize()
        }
        if presentedHighlight != highlighted {
            presentedHighlight = highlighted
            setTitleColor(highlighted ? KeyboardPalette.accent : KeyboardPalette.text, for: .normal)
            underline.isHidden = !highlighted
        }
        annotation.textColor = highlighted ? KeyboardPalette.accent : .secondaryLabel
        if needsMeasurement {
            let startedAt = KeyboardPerformance.start()
            let mainWidth = KeyboardCandidateTextMetrics.width(of: presentation.text, font: titleLabel!.font!)
            let noteWidth = KeyboardCandidateTextMetrics.width(of: presentation.annotation ?? "", font: annotation.font!)
            measuredTextWidth = max(mainWidth, noteWidth)
            KeyboardPerformance.record(.candidateTitleMeasurement, since: startedAt)
        }
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: presentationWidth, height: (titleLabel?.font.lineHeight ?? 22) + 4)
    }

    override func contentRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 12, dy: 2) }

    override func layoutSubviews() {
        super.layoutSubviews()
        underline.frame = CGRect(x: 12, y: max(0, bounds.height - 2),
            width: min(max(0, bounds.width - 24), ceil(measuredTextWidth)), height: 2)
        if !annotation.isHidden {
            let small = bounds.height < 30
            titleLabel?.frame = CGRect(x: 12, y: 0, width: max(0, bounds.width - 24), height: small ? 16 : 20)
            annotation.frame = CGRect(x: 12, y: small ? 16 : 20, width: max(0, bounds.width - 24), height: small ? 8 : 11)
        }
    }
    func applyTheme() {
        underline.backgroundColor = KeyboardPalette.accent
        setTitleColor(presentedHighlight == true ? KeyboardPalette.accent : KeyboardPalette.text, for: .normal)
        annotation.textColor = presentedHighlight == true ? KeyboardPalette.accent : .secondaryLabel
    }
}
