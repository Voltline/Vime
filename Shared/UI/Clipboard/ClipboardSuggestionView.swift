import UIKit

/// A single clipboard preview, independent of conversion candidates. Each
/// button remembers the value touched so a refresh cannot paste/dismiss a
/// newer clipboard value on touch-up.
final class ClipboardSuggestionView: UIView {
    private let paste = ValueButton(type: .custom)
    private let dismiss = ValueButton(type: .custom)
    var onPaste: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "vime.clipboard.preview"
        backgroundColor = .clear
        paste.accessibilityIdentifier = "vime.clipboard.paste"
        paste.accessibilityHint = String(localized: "输入剪贴板的完整文本")
        paste.contentHorizontalAlignment = .leading
        paste.titleLabel?.numberOfLines = 1
        paste.addAction(UIAction { [weak self] _ in
            guard let self, let value = self.paste.takeValue() else { return }
            self.onPaste?(value)
        }, for: .touchUpInside)
        dismiss.accessibilityIdentifier = "vime.clipboard.dismiss"
        dismiss.accessibilityLabel = String(localized: "收起剪贴板提示")
        dismiss.accessibilityHint = String(localized: "内容仍保留在剪贴板历史中")
        dismiss.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)), for: .normal)
        dismiss.addAction(UIAction { [weak self] _ in
            guard let self, let value = self.dismiss.takeValue() else { return }
            self.onDismiss?(value)
        }, for: .touchUpInside)
        addSubview(paste); addSubview(dismiss)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ text: String?) {
        guard paste.value != text else { return }
        paste.value = text; dismiss.value = text
        let preview = text.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(160)))
            .replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: " ") }
        var configuration = UIButton.Configuration.plain()
        configuration.title = preview
        configuration.image = UIImage(systemName: "clipboard", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14))
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in .secondaryLabel }
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 6)
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            // Same size as candidate and next-word text; long text truncates.
            attributes.font = UIFont.systemFont(ofSize: 18)
            return attributes
        }
        paste.configuration = configuration
        paste.accessibilityLabel = preview
        applyTheme()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let closeWidth = min(44, bounds.width)
        paste.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - closeWidth), height: bounds.height)
        dismiss.frame = CGRect(x: bounds.width - closeWidth, y: 0, width: closeWidth, height: bounds.height)
    }

    func applyTheme() {
        paste.configuration?.baseForegroundColor = KeyboardPalette.text
        dismiss.tintColor = .secondaryLabel
    }

    private final class ValueButton: UIButton {
        var value: String?
        private var armed = false
        private var touchedValue: String?
        override init(frame: CGRect) {
            super.init(frame: frame)
            addTarget(self, action: #selector(arm), for: .touchDown)
            addTarget(self, action: #selector(cancel), for: [.touchCancel, .touchUpOutside])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func arm() { armed = true; touchedValue = value }
        @objc private func cancel() { armed = false; touchedValue = nil }
        func takeValue() -> String? {
            let result = armed ? touchedValue : value
            cancel(); return result
        }
    }
}
