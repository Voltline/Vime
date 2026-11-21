import UIKit

/// The visual selection follows the text width, independently of the button's
/// hit area or a wider cell in the expanded candidate panel.
final class KeyboardCandidateButton: UIButton {
    /// The first candidate's box, a rounded key-coloured backing behind its
    /// text, as the system keyboards mark the candidate Space takes.
    private let highlight = UIView()
    private let separator = UIView()
    /// Next-word suggestions read as equal, divided slots (like QuickType)
    /// rather than a ranked list with a leading best guess.
    private(set) var suggestion = false
    private let annotation = UILabel()
    /// The reading above a word found by its Mandarin reading, like furigana.
    private let ruby = UILabel()
    /// Ruby and text share the strip's height; the text is a point smaller
    /// so the pair fits the compact landscape strip as well.
    nonisolated static let rubyTitleFontSize: CGFloat = 17
    nonisolated static let titleFontSize: CGFloat = 18
    private var presentedPresentation: CandidatePresentation?
    private var presentedRuby: Bool?
    private var presentedIndex: Int?
    private var presentedHighlight: Bool?
    private var measuredTextWidth: CGFloat = 0
    /// The title's and the ruby's own widths, to centre one over the other.
    private var measuredTitleWidth: CGFloat = 0
    private var measuredRubyWidth: CGFloat = 0
    var presentationWidth: CGFloat { max(ceil(measuredTextWidth) + 24, suggestion ? Self.suggestionMinimumWidth : 0) }
    /// Keeps one-character suggestions such as は or 、 from crowding together.
    static let suggestionMinimumWidth: CGFloat = 56
    /// A sentence wider than the expanded panel's row wraps onto a second
    /// line (KeyboardCandidatePanelLayout); the strip always shows one.
    var titleLines = 1 {
        didSet {
            guard titleLines != oldValue else { return }
            titleLabel?.numberOfLines = titleLines
            setNeedsLayout()
        }
    }
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
        highlight.isUserInteractionEnabled = false
        highlight.backgroundColor = KeyboardPalette.key
        highlight.accessibilityIdentifier = "vime.candidate.highlight"
        highlight.layer.cornerCurve = .continuous
        highlight.isHidden = true
        insertSubview(highlight, at: 0)
        separator.isUserInteractionEnabled = false
        separator.backgroundColor = KeyboardPalette.text.withAlphaComponent(0.18)
        separator.isHidden = true
        addSubview(separator)
        annotation.font = .systemFont(ofSize: 10)
        annotation.accessibilityIdentifier = "vime.candidate.annotation"
        annotation.isUserInteractionEnabled = false
        annotation.lineBreakMode = .byTruncatingTail
        addSubview(annotation)
        ruby.font = .systemFont(ofSize: 10)
        ruby.accessibilityIdentifier = "vime.candidate.ruby"
        ruby.isUserInteractionEnabled = false
        ruby.lineBreakMode = .byTruncatingTail
        ruby.isHidden = true
        addSubview(ruby)
        backgroundColor = KeyboardTouchBacking.color
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ presentation: CandidatePresentation, index: Int, highlighted: Bool) {
        tag = index
        let suggests = presentation.selectionToken?.kind == .suggestion
        let needsMeasurement = presentation.text != presentedPresentation?.text
            || presentation.annotation != presentedPresentation?.annotation || presentedIndex != index
            || presentation.rubyReading != presentedPresentation?.rubyReading || suggests != suggestion
        if suggests != suggestion {
            suggestion = suggests
            contentHorizontalAlignment = suggests ? .center : .left
            titleLabel?.textAlignment = suggests ? .center : .left
            annotation.textAlignment = suggests ? .center : .natural
            presentedIndex = nil
        }
        separator.isHidden = !suggests || index == 0
        if presentation != presentedPresentation {
            if presentation.text != presentedPresentation?.text { setTitle(presentation.text, for: .normal) }
            presentedPresentation = presentation
            ruby.text = presentation.rubyReading
            ruby.isHidden = presentation.rubyReading == nil
            annotation.text = presentation.annotation
            // The ruby is the note for these words; one line of each fits.
            annotation.isHidden = presentation.annotation == nil || !ruby.isHidden
            accessibilityLabel = presentation.accessibilityLabel
            accessibilityHint = presentation.correction == nil ? String(localized: "点击确认候选词") : String(localized: "点击采用建议读音")
            invalidateIntrinsicContentSize()
        }
        let hasRuby = !ruby.isHidden
        let indexChanged = presentedIndex != index || presentedRuby != hasRuby
        let highlightChanged = presentedHighlight != highlighted
        let colorChanged = titleColor(for: .normal)?.isEqual(KeyboardPalette.text) != true
        if !needsMeasurement && !indexChanged && !highlightChanged && !colorChanged { return }
        if indexChanged {
            titleLabel?.font = .systemFont(ofSize: hasRuby ? Self.rubyTitleFontSize : Self.titleFontSize,
                weight: index == 0 && !suggestion ? .medium : .regular)
            presentedIndex = index
            presentedRuby = hasRuby
            invalidateIntrinsicContentSize()
        }
        if highlightChanged {
            presentedHighlight = highlighted
            highlight.isHidden = !highlighted
        }
        if colorChanged {
            setTitleColor(KeyboardPalette.text, for: .normal)
            annotation.textColor = .secondaryLabel
            ruby.textColor = annotation.textColor
        }
        if needsMeasurement {
            let startedAt = KeyboardPerformance.start()
            let mainWidth = KeyboardCandidateTextMetrics.width(of: presentation.text, font: titleLabel!.font!)
            let noteWidth = annotation.isHidden ? 0
                : KeyboardCandidateTextMetrics.width(of: presentation.annotation ?? "", font: annotation.font!)
            let rubyWidth = KeyboardCandidateTextMetrics.width(of: presentation.rubyReading ?? "", font: ruby.font!)
            measuredTextWidth = max(mainWidth, noteWidth, rubyWidth)
            (measuredTitleWidth, measuredRubyWidth) = (mainWidth, rubyWidth)
            KeyboardPerformance.record(.candidateTitleMeasurement, since: startedAt)
        }
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: presentationWidth, height: ceil(titleLabel?.font.lineHeight ?? 22)
            + (annotation.isHidden ? 0 : ceil(annotation.font.lineHeight) + 1)
            + (ruby.isHidden ? 0 : ceil(ruby.font.lineHeight) + 1) + 4)
    }

    override func contentRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 12, dy: 2) }

    /// Room the highlight box leaves around the text block.
    static let highlightPadding = CGSize(width: 7, height: 5)

    override func layoutSubviews() {
        super.layoutSubviews()
        let titleHeight = ceil(titleLabel?.font.lineHeight ?? 22)
        var textTop = (bounds.height - titleHeight) / 2
        var textBottom = (bounds.height + titleHeight) / 2
        if titleLines > 1 && annotation.isHidden && ruby.isHidden {
            // Wrapped text fills the slot's width; the label truncates the
            // last line in the middle if even two lines are not enough.
            let height = titleHeight * CGFloat(titleLines)
            let top = max(0, floor((bounds.height - height) / 2))
            titleLabel?.frame = CGRect(x: 12, y: top, width: max(0, bounds.width - 24), height: height)
            (textTop, textBottom) = (top, top + height)
        } else if !annotation.isHidden {
            let noteHeight = ceil(annotation.font.lineHeight)
            let top = max(0, (bounds.height - titleHeight - noteHeight - 3) / 2)
            titleLabel?.frame = CGRect(x: 12, y: top, width: max(0, bounds.width - 24), height: titleHeight)
            annotation.frame = CGRect(x: 12, y: top + titleHeight + 1,
                width: max(0, bounds.width - 24), height: noteHeight)
            (textTop, textBottom) = (top, annotation.frame.maxY)
        } else if !ruby.isHidden {
            // Like furigana: the reading sits centred over the word, and the
            // narrower of the two is centred under or over the wider one.
            let rubyHeight = ceil(ruby.font.lineHeight)
            let top = max(0, (bounds.height - rubyHeight - 1 - titleHeight) / 2)
            let available = max(0, bounds.width - 24)
            let block = min(available, ceil(max(measuredTitleWidth, measuredRubyWidth)))
            let titleWidth = min(available, ceil(measuredTitleWidth)), rubyWidth = min(available, ceil(measuredRubyWidth))
            ruby.frame = CGRect(x: 12 + floor((block - rubyWidth) / 2), y: top, width: rubyWidth, height: rubyHeight)
            titleLabel?.frame = CGRect(x: 12 + floor((block - titleWidth) / 2), y: top + rubyHeight + 1,
                width: titleWidth, height: titleHeight)
            (textTop, textBottom) = (top, titleLabel?.frame.maxY ?? textBottom)
        }
        // Follow the text, not the strip: a full-height box would otherwise
        // run into the first key row.
        let padding = Self.highlightPadding
        let top = max(1, floor(textTop - padding.height)), bottom = min(bounds.height - 1, ceil(textBottom + padding.height))
        let width = min(max(0, bounds.width - 24), ceil(measuredTextWidth)) + padding.width * 2
        highlight.frame = CGRect(x: 12 - padding.width, y: top, width: min(bounds.width - (12 - padding.width) * 2, width),
            height: max(0, bottom - top))
        highlight.layer.cornerRadius = min(10, highlight.bounds.height / 2)
        let separatorHeight = min(bounds.height, 18)
        separator.frame = CGRect(x: -1, y: (bounds.height - separatorHeight) / 2, width: 1 / max(1, traitCollection.displayScale), height: separatorHeight)
    }
    func applyTheme() {
        highlight.backgroundColor = KeyboardPalette.key
        separator.backgroundColor = KeyboardPalette.text.withAlphaComponent(0.18)
        setTitleColor(KeyboardPalette.text, for: .normal)
        annotation.textColor = .secondaryLabel
        ruby.textColor = annotation.textColor
    }
}
