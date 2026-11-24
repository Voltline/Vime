import UIKit

/// The small Vime mark on a lead a late correction replaced: the V redraws
/// while a band of colours sweeps across it and settles on brand blue, and
/// the cursor bar pops in. The mark then stays, showing the lead was changed.
final class VimeCorrectionMarkView: UIView {
    static let side: CGFloat = 13
    /// Brand blue around the hue wheel, at matched lightness and chroma.
    static let sweep: [UIColor] = [0x2474F5, 0x7C5CF2, 0xE0529C, 0xF0605A, 0xF5A524].map { hex in
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private let gradient = CAGradientLayer()
    private let strokes = CALayer()
    private let stroke = CAShapeLayer()
    private let bar = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        let blue = UIColor(cgColor: VimeLogo.blue).cgColor
        gradient.colors = Self.sweep.map(\.cgColor) + [blue, blue]
        gradient.locations = [0, 0.15, 0.3, 0.45, 0.6, 0.72, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        for shape in [stroke, bar] {
            shape.fillColor = nil
            shape.strokeColor = UIColor.black.cgColor
            shape.lineCap = .round
            shape.lineJoin = .round
            strokes.addSublayer(shape)
        }
        layer.addSublayer(gradient)
        gradient.mask = strokes
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = bounds.width, unit = side / 100
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Four widths of colour: the visible quarter starts on the band and
        // ends on its blue tail.
        // At rest the blue tail shows; play() sweeps there from the band.
        gradient.frame = CGRect(x: -side * 3, y: 0, width: side * 4, height: bounds.height)
        let v = UIBezierPath()
        v.move(to: CGPoint(x: 25 * unit, y: 35 * unit))
        v.addLine(to: CGPoint(x: 46 * unit, y: 69 * unit))
        v.addLine(to: CGPoint(x: 75 * unit, y: 28 * unit))
        stroke.path = v.cgPath
        stroke.lineWidth = 10.5 * unit
        let barRect = CGRect(x: 65 * unit, y: 69 * unit - 5.25 * unit, width: 12 * unit, height: 10.5 * unit)
        bar.frame = barRect
        let line = UIBezierPath()
        line.move(to: CGPoint(x: 0, y: barRect.height / 2))
        line.addLine(to: CGPoint(x: barRect.width, y: barRect.height / 2))
        bar.path = line.cgPath
        bar.lineWidth = 10.5 * unit
        // The mask lives in the gradient's space, so it offsets the gradient's shift.
        strokes.frame = CGRect(x: side * 3, y: 0, width: side, height: bounds.height)
        CATransaction.commit()
    }

    func play() {
        guard !UIAccessibility.isReduceMotionEnabled else { show(); return }
        layer.removeAllAnimations()
        [gradient, strokes, stroke, bar].forEach { $0.removeAllAnimations() }
        isHidden = false
        layoutIfNeeded()
        let side = bounds.width
        let now = CACurrentMediaTime()

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.38
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        stroke.add(draw, forKey: "draw")

        let pop = CAKeyframeAnimation(keyPath: "transform.scale.x")
        pop.values = [0, 1.25, 1]
        pop.keyTimes = [0, 0.8, 1]
        pop.beginTime = now + 0.16
        pop.duration = 0.42
        pop.fillMode = .backwards
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
        bar.add(pop, forKey: "pop")

        // The band slides left under the strokes; the mask slides right to stay put.
        let sweepTiming = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = side * 2
        slide.toValue = -side
        slide.duration = 0.9
        slide.timingFunction = sweepTiming
        gradient.add(slide, forKey: "sweep")
        let hold = CABasicAnimation(keyPath: "position.x")
        hold.fromValue = side / 2
        hold.toValue = side / 2 + side * 3
        hold.duration = 0.9
        hold.timingFunction = sweepTiming
        strokes.add(hold, forKey: "hold")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 1
        let appear = CAAnimationGroup()
        appear.animations = [fade, grow]
        appear.duration = 0.2
        appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = 1
        layer.add(appear, forKey: "appear")
    }

    /// The settled mark, for a list rebuilt after the mark played.
    func show() {
        guard isHidden else { return }
        [layer, gradient, strokes, stroke, bar].forEach { $0.removeAllAnimations() }
        layer.opacity = 1
        isHidden = false
    }

    func stop() {
        layer.removeAllAnimations()
        isHidden = true
    }
}
