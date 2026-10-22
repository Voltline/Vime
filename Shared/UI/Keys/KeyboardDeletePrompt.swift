import UIKit

/// Noninteractive pull track that grows upward out of the held delete key,
/// with a caption beside it. The track fills with the accent once a release
/// would clear the line.
final class KeyboardDeletePrompt: UIView {
    private let track = UIView()
    private let arrow = UIImageView()
    private let glyph = UIImageView(image: UIImage(systemName: "delete.left"))
    private let caption = UILabel()
    private let captionBackground = UIView()
    /// Size of the delete key the track covers at its bottom end.
    var keySize: CGSize = .zero { didSet { setNeedsLayout() } }
    var armed = false {
        didSet {
            guard armed != oldValue else { return }
            UIView.transition(with: self, duration: 0.15, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.applyTheme(); self.setNeedsLayout(); self.layoutIfNeeded()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "vime.delete.prompt"
        isUserInteractionEnabled = false
        track.layer.borderWidth = 1.5
        arrow.contentMode = .scaleAspectFit
        glyph.contentMode = .scaleAspectFit
        caption.font = .systemFont(ofSize: 14, weight: .semibold)
        caption.textAlignment = .center
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.7
        captionBackground.layer.shadowColor = UIColor.black.cgColor
        captionBackground.layer.shadowOpacity = 0.12
        captionBackground.layer.shadowRadius = 4
        captionBackground.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(captionBackground); captionBackground.addSubview(caption)
        addSubview(track); track.addSubview(arrow); track.addSubview(glyph)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme() {
        let accent = KeyboardPalette.accent
        // Light accents (the midnight skin) need dark ink when filled.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        accent.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: nil)
        let ink: UIColor = 0.299 * red + 0.587 * green + 0.114 * blue > 0.6 ? .black : .white
        track.backgroundColor = armed ? accent : KeyboardPalette.key
        track.layer.borderColor = accent.resolvedColor(with: traitCollection).cgColor
        arrow.image = UIImage(systemName: armed ? "eraser.fill" : "chevron.up")
        arrow.tintColor = armed ? ink : accent
        glyph.tintColor = armed ? ink : KeyboardPalette.text
        captionBackground.backgroundColor = armed ? accent : KeyboardPalette.key
        caption.textColor = armed ? ink : KeyboardPalette.text
        caption.text = armed ? String(localized: "松手清空") : String(localized: "上滑清空")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let key = CGSize(width: min(keySize.width, bounds.width), height: min(keySize.height, bounds.height))
        track.frame = CGRect(x: bounds.width - key.width, y: 0, width: key.width, height: bounds.height)
        track.layer.cornerRadius = min(track.bounds.width, track.bounds.height) / 2
        let reach = track.bounds.height - key.height
        glyph.frame = CGRect(x: (key.width - 22) / 2, y: reach + (key.height - 22) / 2, width: 22, height: 22)
        arrow.frame = CGRect(x: (key.width - 18) / 2, y: max(6, (reach - 18) / 2), width: 18, height: 18)
        let room = max(0, track.frame.minX - 8)
        let width = min(room, caption.intrinsicContentSize.width + 24)
        captionBackground.frame = CGRect(x: track.frame.minX - 8 - width, y: arrow.frame.midY - 15, width: width, height: 30)
        captionBackground.layer.cornerRadius = 15
        caption.frame = captionBackground.bounds.insetBy(dx: 10, dy: 0)
    }
}
