import UIKit
import CoreText

/// Place the visible glyphs, rather than a font's unused line leading, inside a
/// skin caption. This preserves the chosen point size while reserving real space
/// for both artwork and text, including fallback Japanese/Chinese glyphs.
final class KeyboardSkinCaption: UIView {
    var text: String? { didSet { if oldValue != text { setNeedsDisplay() } } }
    var font = UIFont.systemFont(ofSize: 17) { didSet { if oldValue != font { setNeedsDisplay() } } }
    var textColor = UIColor.label { didSet { if oldValue != textColor { setNeedsDisplay() } } }
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = false; isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var cachedText: String?
    private var cachedFont: UIFont?
    private var cachedColor: UIColor?
    private var line: CTLine?
    private var inkBounds = CGRect.zero

    var glyphSize: CGSize { prepareLine(); return inkBounds.size }

    private func prepareLine() {
        let value = text ?? ""
        let resolvedColor = textColor.resolvedColor(with: traitCollection)
        let selectedFont = font
        guard cachedText != value || cachedFont != selectedFont || cachedColor != resolvedColor else { return }
        cachedText = value; cachedFont = selectedFont; cachedColor = resolvedColor
        let attributed = NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): selectedFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): resolvedColor.cgColor
        ])
        line = CTLineCreateWithAttributedString(attributed)
        inkBounds = line.map { CTLineGetImageBounds($0, nil).integral } ?? .zero
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { glyphSize }
    override func draw(_ rect: CGRect) {
        prepareLine()
        guard bounds.width > 0, bounds.height > 0, let line, !inkBounds.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        // Width fitting is only needed for unusually narrow keys/long labels.
        let fit = min(1, bounds.width / inkBounds.width, bounds.height / inkBounds.height)
        context.scaleBy(x: fit, y: fit)
        context.textPosition = CGPoint(x: (bounds.width / fit - inkBounds.width) / 2 - inkBounds.minX,
                                       y: (bounds.height / fit - inkBounds.height) / 2 - inkBounds.minY)
        CTLineDraw(line, context)
    }
}
