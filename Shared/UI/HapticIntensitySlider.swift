import UIKit

/// Continuous while dragging; release near a marker settles on that marker.
final class HapticIntensitySlider: UISlider {
    var onValue: ((Double, Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumValue = 0; maximumValue = 1
        // The keyboard host needs rendered pixels over the full tracking region,
        // including the transparent area surrounding the thumb and track
        backgroundColor = KeyboardTouchBacking.color
        accessibilityLabel = "振动强度"
        accessibilityIdentifier = "vime.setting.haptics"
        addTarget(self, action: #selector(changed), for: .valueChanged)
        addTarget(self, action: #selector(settle), for: [.touchUpInside, .touchUpOutside])
        disableNativeTrackingGestures()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setIntensity(_ intensity: Double) {
        value = Float(HapticIntensity.normalized(intensity))
        accessibilityValue = HapticIntensity.description(Double(value))
    }
    @objc private func changed() {
        accessibilityValue = HapticIntensity.description(Double(value))
        onValue?(Double(value), false)
    }
    @objc private func settle() {
        setIntensity(HapticIntensity.snapped(Double(value)))
        onValue?(Double(value), true)
    }
    private var ownedTouch: UITouch?
    private var startingValue: Float = 0
    private var thumbOffset: CGFloat = 0
    var isAdjusting: Bool { ownedTouch != nil }
    // The extension host delivers raw touch endings, but UISlider's tracking
    // hooks do not reliably finish there. Own this setting control's touch only.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard ownedTouch == nil, let touch = touches.first else { return }
        ownedTouch = touch; startingValue = value
        let point = touch.location(in: self)
        let thumb = thumbRect(forBounds: bounds, trackRect: trackRect(forBounds: bounds), value: value)
        thumbOffset = thumb.contains(point) ? point.x - thumb.midX : 0
        updateTouch(at: point)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = ownedTouch, touches.contains(touch) else { return }
        updateTouch(at: touch.location(in: self))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = ownedTouch, touches.contains(touch) else { return }
        updateTouch(at: touch.location(in: self))
        ownedTouch = nil
        // Dispatch settlement directly: the keyboard host does not reliably
        // forward UISlider touch-up control actions
        settle()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = ownedTouch, touches.contains(touch) else { return }
        cancelOwnedTouch()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        disableNativeTrackingGestures()
        if window == nil { cancelOwnedTouch() }
    }
    // Modern UISlider also tracks with internal recognizers. They must not
    // update the value after this control has settled its owned touch.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { false }
    private func disableNativeTrackingGestures() {
        gestureRecognizers?.forEach { $0.isEnabled = false }
    }
    private func cancelOwnedTouch() {
        guard ownedTouch != nil else { return }
        ownedTouch = nil; setIntensity(Double(startingValue))
        onValue?(Double(value), false)
    }
    private func updateTouch(at point: CGPoint) {
        let track = trackRect(forBounds: bounds)
        let thumb = thumbRect(forBounds: bounds, trackRect: track, value: value)
        let width = max(1, track.width - thumb.width)
        setIntensity(Double((point.x - thumbOffset - track.minX - thumb.width / 2) / width))
        sendActions(for: .valueChanged)
    }
    // VoiceOver uses intentional discrete reference points; touch remains continuous.
    override func accessibilityIncrement() {
        setIntensity(HapticIntensity.levels.first { $0.value > Double(value) + 1e-6 }?.value ?? 1)
        onValue?(Double(value), true)
    }
    override func accessibilityDecrement() {
        setIntensity(HapticIntensity.levels.last { $0.value < Double(value) - 1e-6 }?.value ?? 0)
        onValue?(Double(value), true)
    }
}

final class HapticIntensityScale: UIView {
    private var labels: [UILabel] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        for level in HapticIntensity.levels {
            let label = UILabel()
            label.text = level.title; label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
            addSubview(label); labels.append(label)
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: HapticIntensityScale, _: UITraitCollection) in
            view.invalidateIntrinsicContentSize(); view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIFont.preferredFont(forTextStyle: .caption1).lineHeight + 10)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for (label, level) in zip(labels, HapticIntensity.levels) {
            let size = label.intrinsicContentSize
            let center = 8 + max(0, bounds.width - 16) * level.value
            let x = min(max(0, center - size.width / 2), max(0, bounds.width - size.width))
            label.frame = CGRect(x: x, y: 5, width: size.width, height: size.height)
        }
    }
}

/// Keep horizontal control drags out of the quick panel's vertical scrolling.
final class KeyboardSettingsScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        var current: UIView? = view
        while let item = current, item !== self {
            if item is UISlider { return false }
            current = item.superview
        }
        return super.touchesShouldCancel(in: view)
    }
}
