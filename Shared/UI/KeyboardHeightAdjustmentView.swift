import UIKit

final class KeyboardHeightAdjustmentView: UIView {
    var onChange: ((CGFloat) -> Void)?
    let keyboard = KeyboardView()
    private let material = UIInputView(frame: .zero, inputViewStyle: .keyboard)
    private let grip = UIView()
    private let line = UIView()
    private var startingFactor: CGFloat = 1
    var factor: CGFloat = 1 {
        didSet { keyboard.heightFactor = factor; setNeedsLayout() }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        keyboard.isUserInteractionEnabled = false; keyboard.hasFullAccess = false
        material.addSubview(keyboard); addSubview(material)
        grip.backgroundColor = .tertiarySystemFill; grip.layer.cornerRadius = 10
        line.backgroundColor = .secondaryLabel; line.layer.cornerRadius = 3
        grip.addSubview(line); addSubview(grip)
        grip.accessibilityIdentifier = "vime.height.grip"
        grip.isAccessibilityElement = true; grip.accessibilityLabel = "上下拖动调整键盘高度"
        grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let height = keyboard.preferredHeight(for: bounds.width)
        material.frame = CGRect(x: 0, y: max(36, bounds.height - height), width: bounds.width, height: height)
        keyboard.frame = material.bounds
        grip.frame = CGRect(x: 8, y: material.frame.minY - 36, width: bounds.width - 16, height: 32)
        line.frame = CGRect(x: (grip.bounds.width - 44) / 2, y: 13, width: 44, height: 6)
    }
    func beginAdjustment() { startingFactor = factor }
    func adjust(translationY: CGFloat) {
        let metrics = KeyboardMetrics(width: max(1, bounds.width), compact: false, showsFooter: true)
        let keyPlane = metrics.rowStep * 3 + metrics.keyHeight
        let range = KeyboardPreferences.heightRange
        factor = min(CGFloat(range.upperBound), max(CGFloat(range.lowerBound), startingFactor - translationY / keyPlane))
        onChange?(factor)
    }
    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { beginAdjustment() }
        if pan.state == .began || pan.state == .changed || pan.state == .ended { adjust(translationY: pan.translation(in: self).y) }
        if pan.state == .cancelled { factor = startingFactor; onChange?(factor) }
    }
}
