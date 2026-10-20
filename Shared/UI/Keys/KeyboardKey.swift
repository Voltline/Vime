import UIKit

final class KeyboardKey: UIButton {
    /// Owned, nonoverlapping touch cell in this key's local coordinates.
    /// The painted frame remains unchanged.
    var touchBounds: CGRect?
    var action: (() -> Void)?
    var feedback: (() -> Void)?
    /// Recheck the host before each repeat, including accessibility activation.
    var canRepeat: (() -> Bool)?
    var alternateAction: (() -> Void)?
    var alternateTitle: String?
    private var swipe = KeySwipeSelection()
    private var touchOrigin = CGPoint.zero
    let hintLabel = UILabel()
    var hint: String? { didSet { hintLabel.text = hint; setNeedsLayout() } }
    private var usedAlternate = false
    var repeats = false
    var isUtility = false
    private var resolvedRepeatOccurred = false
    var showsPreview = false
    weak var previewContainer: UIView?
    var fillColor: UIColor = KeyboardPalette.key { didSet { updateAppearance() } }
    private var repeatTimer: Timer?
    private var delayTimer: Timer?
    private var preview: UILabel?
    private let artwork = UIImageView()
    private let skinCaption = KeyboardSkinCaption()
    private var skin: KeyboardSkinAppearance?
    private var skinKeyID = ""
    private var isSkinLetter: Bool { skinKeyID.hasPrefix("letter.") || skinKeyID == "letter" }
    var hasSkinArtwork: Bool { artwork.image != nil }
    func applySkin(_ skin: KeyboardSkinAppearance?, key: String) {
        self.skin = skin
        skinKeyID = key
        artwork.image = skin?.image(for: key) ?? (key.hasPrefix("letter.") ? skin?.image(for: "letter") : nil)
        artwork.contentMode = .scaleAspectFit; artwork.isUserInteractionEnabled = false
        if artwork.superview == nil { insertSubview(artwork, at: 0) }
        if skinCaption.superview == nil {
            skinCaption.isUserInteractionEnabled = false
            skinCaption.isAccessibilityElement = false
            skinCaption.accessibilityIdentifier = "vime.skin.caption"
            addSubview(skinCaption)
        }
        layer.shadowOpacity = Float(skin?.document.style.shadowOpacity ?? 0.30)
        setNeedsLayout()
    }
    func applySkinMetrics(size: CGFloat, scale: CGFloat) {
        if let skin {
            layer.cornerRadius = skin.document.style.cornerRadius * scale
            titleLabel?.font = skin.font(size: hasSkinArtwork ? min(size, 18 * scale) : size)
        }
        updateShadowPath()
    }

    /// Without a path, Core Animation derives each key's shadow from its
    /// rendered alpha in an offscreen pass. For an opaque fill without artwork
    /// that shape is exactly the rounded bounds; translucent skins keep the
    /// derived shadow, which follows their artwork and partial transparency.
    private var shadowPathShape: (bounds: CGRect, radius: CGFloat)?
    private func updateShadowPath() {
        let opaque = !hasSkinArtwork && (backgroundColor?.resolvedColor(with: traitCollection).cgColor.alpha ?? 0) >= 1
        guard opaque else {
            if shadowPathShape != nil { layer.shadowPath = nil; shadowPathShape = nil }
            return
        }
        let shape = (bounds: bounds, radius: layer.cornerRadius)
        guard shadowPathShape?.bounds != shape.bounds || shadowPathShape?.radius != shape.radius else { return }
        shadowPathShape = shape
        // Circular arcs, matching CALayer's default cornerCurve.
        let radius = min(layer.cornerRadius, bounds.width / 2, bounds.height / 2)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    init(title: String? = nil, symbol: String? = nil) {
        super.init(frame: .zero)
        layer.cornerRadius = 6.2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.30
        layer.shadowOffset = CGSize(width: 0, height: 0.8)
        layer.shadowRadius = 0
        titleLabel?.font = .systemFont(ofSize: 21, weight: .regular)
        hintLabel.font = .systemFont(ofSize: 9)
        hintLabel.textColor = UIColor(white: 0.63, alpha: 1)
        hintLabel.textAlignment = .center
        hintLabel.isUserInteractionEnabled = false
        addSubview(hintLabel)
        setTitleColor(KeyboardPalette.text, for: .normal)
        tintColor = KeyboardPalette.text
        if let title { setTitle(title, for: .normal); accessibilityLabel = title }
        if let symbol { setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)), for: .normal) }
        addTarget(self, action: #selector(down), for: .touchDown)
        addTarget(self, action: #selector(up), for: .touchUpInside)
        addTarget(self, action: #selector(cancel), for: .touchCancel)
        addTarget(self, action: #selector(upOutside), for: .touchUpOutside)
        addTarget(self, action: #selector(reenter), for: .touchDragEnter)
        updateAppearance()
        // Dynamic fills can change opacity between light and dark appearance.
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingColorAppearance) { (key: KeyboardKey, _: UITraitCollection) in
            key.updateShadowPath()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let inside = (touchBounds ?? bounds).contains(point)
        KeyboardTouchDiagnostics.record("KeyboardKey.pointInside", point: point, view: self,
            result: inside ? self : nil)
        return inside
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateShadowPath()
        hintLabel.frame = CGRect(x: 0, y: 2, width: bounds.width, height: 11)
        if hint != nil { titleLabel?.center.y = bounds.height * 0.59 }
        imageView?.isHidden = hasSkinArtwork
        titleLabel?.isHidden = hasSkinArtwork
        titleLabel?.alpha = hasSkinArtwork ? 0 : 1
        skinCaption.isHidden = !hasSkinArtwork
        if hasSkinArtwork {
            let content = bounds.insetBy(dx: 2, dy: 2)
            artwork.isHidden = false
            artwork.frame = content
            skinCaption.text = title(for: .normal)
            skinCaption.font = titleLabel?.font ?? .systemFont(ofSize: 17)
            skinCaption.textColor = titleColor(for: .normal) ?? KeyboardPalette.text
            if let title = title(for: .normal), !title.isEmpty {
                let label = skinCaption
                let gap: CGFloat = 2
                let height = min(content.height, label.glyphSize.height + 4)
                let width = label.glyphSize.width + 4
                // Wide action keys keep useful artwork beside a full-height caption.
                // Letter keys keep captions below; reserve actual glyph height and a gap.
                if !isSkinLetter && content.width >= width + gap + 24 {
                    label.frame = CGRect(x: content.maxX - width, y: content.midY - height / 2,
                                         width: width, height: height)
                    artwork.frame.size.width = label.frame.minX - gap - content.minX
                } else {
                    label.frame = CGRect(x: content.minX, y: content.maxY - height,
                                         width: content.width, height: height)
                    artwork.frame.size.height = max(0, label.frame.minY - gap - content.minY)
                    // At small heights, the action name takes priority over decoration.
                    if artwork.frame.height < 10 {
                        artwork.isHidden = true
                        label.frame = content
                    }
                }
                bringSubviewToFront(label)
            }
            hintLabel.isHidden = true
        } else { hintLabel.isHidden = false }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchOrigin = touch.location(in: self)
        swipe.reset()
        return super.beginTracking(touch, with: event)
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        updateSwipe(x: point.x - touchOrigin.x, y: point.y - touchOrigin.y)
        _ = super.continueTracking(touch, with: event)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch {
            let point = touch.location(in: self)
            updateSwipe(x: point.x - touchOrigin.x, y: point.y - touchOrigin.y, allowActivation: false)
        }
        finishSwipe(cancelled: touch == nil)
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        finishSwipe(cancelled: true)
        super.cancelTracking(with: event)
    }

    // Shared by touch tracking and regression tests; insertion happens on release only.
    @discardableResult
    func updateSwipe(x: CGFloat, y: CGFloat, allowActivation: Bool = true) -> Bool {
        guard alternateAction != nil else { return false }
        swipe.move(x: Double(x), y: Double(y), allowActivation: allowActivation && touchOrigin.y + y <= -2)
        if swipe.alternate {
            showPreview(alternateTitle ?? hint ?? "", alternate: true)
        } else if showsPreview {
            showPreview(title(for: .normal) ?? "", alternate: false)
        } else { preview?.removeFromSuperview(); preview = nil }
        return swipe.alternate
    }

    func beginResolvedPress(deferRepeatingAction: Bool = false) {
        let startedAt = KeyboardPerformance.start()
        swipe.reset()
        if !isHighlighted { resolvedRepeatOccurred = false }
        isHighlighted = true
        pressDown(deferred: deferRepeatingAction)
        KeyboardPerformance.record(.touchDownToVisual, since: startedAt)
    }

    func presentResolvedPress(alternate: Bool) {
        if alternate { showPreview(alternateTitle ?? hint ?? "", alternate: true) }
        else if showsPreview { showPreview(title(for: .normal) ?? "", alternate: false) }
        else { preview?.removeFromSuperview(); preview = nil }
    }

    func finishResolvedPress(cancelled: Bool, alternate: Bool, stillPressed: Bool, deferredRepeat: Bool = false) {
        KeyboardTouchDiagnostics.record("KeyboardKey.resolvedRelease", view: self,
            detail: "cancelled=\(cancelled) alternate=\(alternate) stillPressed=\(stillPressed)")
        if !stillPressed {
            isHighlighted = false
            stopTracking()
        }
        // The surface owns selection per finger; UIButton's shared swipe/up
        // state must not decide another simultaneous finger's character.
        if !cancelled && !repeats {
            if alternate { alternateAction?() }
            else { action?() }
        }
        if !cancelled && repeats && deferredRepeat && !resolvedRepeatOccurred && repeatIsAllowed { action?() }
    }

    override func accessibilityActivate() -> Bool {
        guard !repeats || repeatIsAllowed else { return true }
        feedback?()
        action?()
        return true
    }

    func finishSwipe(cancelled: Bool) {
        usedAlternate = cancelled || swipe.alternate
        if !cancelled && swipe.alternate { alternateAction?() }
        swipe.reset()
        stopTracking()
    }

    private func showPreview(_ text: String, alternate: Bool) {
        let bubble = preview ?? UILabel()
        let container = previewContainer ?? superview?.superview ?? self
        var rect = convert(CGRect(x: -8, y: -48, width: bounds.width + 16, height: 44), to: container)
        // Compact keyboards can have less than 48 pt above the first row.
        // Keep the preview within our own input view rather than its clipped edge.
        rect.origin.y = max(container.bounds.minY, rect.minY)
        rect.origin.x = min(max(container.bounds.minX, rect.minX), max(container.bounds.minX, container.bounds.maxX - rect.width))
        bubble.frame = rect
        bubble.text = text
        bubble.font = .systemFont(ofSize: alternate ? 27 : 30, weight: alternate ? .medium : .regular)
        bubble.textAlignment = .center
        bubble.textColor = alternate ? KeyboardPalette.accent : KeyboardPalette.text
        bubble.alpha = 1
        bubble.backgroundColor = KeyboardPalette.key.withAlphaComponent(1)
        bubble.isOpaque = true
        bubble.layer.cornerRadius = 8
        bubble.layer.masksToBounds = true
        bubble.isUserInteractionEnabled = false
        bubble.accessibilityIdentifier = "vime.swipe.preview"
        if bubble.superview !== container { container.addSubview(bubble) }
        preview = bubble
        container.bringSubviewToFront(bubble)
    }

    override var isHighlighted: Bool { didSet { updateAppearance() } }

    private func updateAppearance() {
        backgroundColor = isHighlighted ? KeyboardPalette.pressed : fillColor; artwork.alpha = isHighlighted ? 0.75 : 1
        updateShadowPath()
    }

    @objc private func down() {
        pressDown(deferred: false)
    }

    private func pressDown(deferred: Bool) {
        KeyboardTouchDiagnostics.record("KeyboardKey.touchDown", view: self)
        usedAlternate = false
        guard !repeats || repeatIsAllowed else { return }
        feedback?()
        if repeats {
            if !deferred { action?() }
            // Two fingers can own this key. Keep one repeat stream and don't
            // overwrite an active timer, which would leave it uncancellable.
            guard isHighlighted || isTracking, delayTimer == nil, repeatTimer == nil else { return }
            let delay = Timer(timeInterval: 0.42, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.delayTimer = nil
                guard self.repeatIsAllowed else { self.resolvedRepeatOccurred = true; self.stopTracking(); return }
                if deferred { self.resolvedRepeatOccurred = true; self.action?() }
                guard self.isHighlighted || self.isTracking else { return }
                let timer = Timer(timeInterval: 0.065, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    guard self.repeatIsAllowed else { self.stopTracking(); return }
                    self.resolvedRepeatOccurred = true; self.feedback?(); self.action?()
                }
                self.repeatTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            delayTimer = delay
            RunLoop.main.add(delay, forMode: .common)
        } else if showsPreview, let title = title(for: .normal), title.count == 1 {
            showPreview(title, alternate: false)
        }
    }

    private var repeatIsAllowed: Bool { canRepeat?() ?? true }

    @objc private func up() {
        KeyboardTouchDiagnostics.record("KeyboardKey.touchUpInside", view: self)
        stopTracking()
        if !repeats && !usedAlternate { action?() }
    }

    @objc private func cancel() {
        KeyboardTouchDiagnostics.record("KeyboardKey.touchCancel", view: self)
        stopTracking()
    }
    @objc private func upOutside() {
        KeyboardTouchDiagnostics.record("KeyboardKey.touchUpOutside", view: self)
        stopTracking()
    }
    @objc private func reenter() { if repeats { down() } }

    func stopTracking() {
        delayTimer?.invalidate()
        repeatTimer?.invalidate()
        delayTimer = nil
        repeatTimer = nil
        preview?.removeFromSuperview()
        preview = nil
    }

    override func didMoveToWindow() { if window == nil { stopTracking() } }
    deinit { delayTimer?.invalidate(); repeatTimer?.invalidate() }
}

/// The same UIKit keyboard is used by the extension and the containing app's sandbox.
