import CoreGraphics

/// A folded V and a short cursor stroke. Shared geometry for the icon and toolbar.
enum VimeLogo {
    static let blue = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [36 / 255, 116 / 255, 245 / 255, 1])!

    static func draw(in context: CGContext, rect: CGRect, color: CGColor) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width, y: rect.height)
        context.setStrokeColor(color)
        context.setLineWidth(0.105)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: 0.25, y: 0.35))
        context.addLine(to: CGPoint(x: 0.46, y: 0.69))
        context.addLine(to: CGPoint(x: 0.75, y: 0.28))
        context.strokePath()
        context.move(to: CGPoint(x: 0.65, y: 0.69))
        context.addLine(to: CGPoint(x: 0.77, y: 0.69))
        context.strokePath()
        context.restoreGState()
    }
}
