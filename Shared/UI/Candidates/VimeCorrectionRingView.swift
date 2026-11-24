import UIKit

/// A soft glow along the corrected lead's box edge. It lights white, then
/// the mark's colours spread clockwise from the mark's corner on a spring
/// until the whole edge is coloured, and keep flowing, quieter, while the
/// corrected lead stays.
final class VimeCorrectionRingView: UIView {
    /// Off: the shipped style is the mark alone. Kept for later use.
    static let isEnabled = false
    /// The band at the box edge and how far it blurs to either side.
    static let band: CGFloat = 2.5
    static let blur: CGFloat = 4
    /// The glow's corners, rounder than the plain candidate box.
    static func cornerRadius(for height: CGFloat) -> CGFloat { min(height / 2, 16) }
    /// One trip of the colours around the box.
    static let period: CFTimeInterval = 2.4
    static let settledOpacity: Float = 0.55

    private let white = CALayer()
    private let colorHost = CALayer()
    /// Squeezes the colours' square to the box, so they move along the long
    /// edges as fast as along the short ones.
    private let squeeze = CALayer()
    private let gradient = CAGradientLayer()
    private let wedge = CAShapeLayer()
    private let shape = CAShapeLayer()
    private var margin: CGFloat { Self.band / 2 + Self.blur * 2 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        white.backgroundColor = UIColor.white.cgColor
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        let colors = VimeCorrectionMarkView.sweep.map(\.cgColor)
        gradient.colors = colors + [colors[0]]
        // The colours show through a thick stroke along the edge that grows
        // clockwise from the mark's corner, its round tip leading.
        wedge.fillColor = nil
        wedge.strokeColor = UIColor.black.cgColor
        wedge.lineCap = .round
        squeeze.addSublayer(gradient)
        colorHost.addSublayer(squeeze)
        colorHost.mask = wedge
        // The mask is the band's blurred shadow alone, so the glow fades out
        // to both sides of the edge.
        shape.fillColor = nil
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 1
        shape.shadowRadius = Self.blur
        shape.shadowOffset = .zero
        layer.addSublayer(white)
        layer.addSublayer(colorHost)
        layer.mask = shape
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Glows along `box` (in the superview's space), whose corners are `radius`.
    func surround(_ box: CGRect, radius: CGFloat) {
        frame = box.insetBy(dx: -margin, dy: -margin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        white.frame = bounds
        colorHost.frame = bounds
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = bounds.height * 1.5
        squeeze.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        squeeze.position = centre
        squeeze.setAffineTransform(CGAffineTransform(scaleX: bounds.width / max(1, bounds.height), y: 1))
        gradient.bounds = CGRect(x: 0, y: 0, width: side * 1.5, height: side * 1.5)
        gradient.position = CGPoint(x: side / 2, y: side / 2)
        let box = bounds.insetBy(dx: margin, dy: margin)
        let edge = Self.edge(box, radius: radius)
        wedge.frame = bounds
        wedge.path = edge
        wedge.lineWidth = margin * 2
        shape.frame = bounds
        shape.shadowPath = edge.copy(strokingWithWidth: Self.band, lineCap: .round, lineJoin: .round, miterLimit: 1)
        CATransaction.commit()
    }

    func play() {
        guard !UIAccessibility.isReduceMotionEnabled else { stop(); return }
        [layer, gradient, wedge].forEach { $0.removeAllAnimations() }
        isHidden = false
        flow()
        let now = CACurrentMediaTime()
        let open = CASpringAnimation(keyPath: "strokeEnd")
        open.fromValue = 0
        open.toValue = 1
        open.mass = 1
        open.stiffness = 90
        open.damping = 16
        open.beginTime = now + 0.15
        open.duration = open.settlingDuration
        open.fillMode = .backwards
        wedge.strokeEnd = 1
        wedge.add(open, forKey: "open")
        let settle = CAKeyframeAnimation(keyPath: "opacity")
        settle.values = [0, 1, 1, Self.settledOpacity]
        settle.keyTimes = [0, 0.1, 0.65, 1]
        settle.duration = 1.8
        layer.opacity = Self.settledOpacity
        layer.add(settle, forKey: "settle")
    }

    /// The settled glow, for a list rebuilt after it played.
    func show() {
        guard isHidden, !UIAccessibility.isReduceMotionEnabled else { return }
        [layer, gradient, wedge].forEach { $0.removeAllAnimations() }
        wedge.strokeEnd = 1
        layer.opacity = Self.settledOpacity
        isHidden = false
        flow()
    }

    private func flow() {
        let flow = CABasicAnimation(keyPath: "transform.rotation.z")
        flow.fromValue = 0
        flow.toValue = Double.pi * 2
        flow.duration = Self.period
        flow.repeatCount = .infinity
        gradient.add(flow, forKey: "flow")
    }

    /// The box's rounded edge, clockwise from the top-right corner.
    private static func edge(_ box: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, box.height / 2, box.width / 2)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: box.maxX - r, y: box.minY))
        path.addArc(withCenter: CGPoint(x: box.maxX - r, y: box.minY + r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))
        path.addArc(withCenter: CGPoint(x: box.maxX - r, y: box.maxY - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
        path.addArc(withCenter: CGPoint(x: box.minX + r, y: box.maxY - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + r))
        path.addArc(withCenter: CGPoint(x: box.minX + r, y: box.minY + r), radius: r, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
        path.close()
        return path.cgPath
    }

    func stop() {
        [layer, gradient, wedge].forEach { $0.removeAllAnimations() }
        isHidden = true
    }
}
