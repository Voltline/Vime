import UIKit

/// Compact, noninteractive callout directly above the held delete key.
final class KeyboardDeletePrompt: UIView {
    private let red = UIView()
    private let icon = UIImageView(image: UIImage(systemName: "trash"))
    private let label = UILabel()
    var armed = false { didSet { label.text = armed ? "松手清空" : "上滑清空" } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "vime.delete.prompt"
        isUserInteractionEnabled = false
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.2
        layer.shadowRadius = 6; layer.shadowOffset = CGSize(width: 0, height: 3)
        red.backgroundColor = .systemRed; red.layer.cornerRadius = 8
        icon.tintColor = .white; icon.contentMode = .scaleAspectFit
        label.textColor = .white; label.text = "上滑清空"
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.adjustsFontSizeToFitWidth = true
        addSubview(red); red.addSubview(icon); red.addSubview(label)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func applyTheme() { backgroundColor = KeyboardPalette.key }
    override func layoutSubviews() {
        super.layoutSubviews()
        red.frame = bounds.insetBy(dx: 6, dy: 6)
        icon.frame = CGRect(x: 6, y: (red.bounds.height - 22) / 2, width: 22, height: 22)
        label.frame = CGRect(x: 32, y: 0, width: red.bounds.width - 37, height: red.bounds.height)
    }
}
