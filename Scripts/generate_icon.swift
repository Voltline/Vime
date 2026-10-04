import AppKit

let size = 1024
let drawing = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let context = NSGraphicsContext(cgContext: drawing, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(srgbRed: 0.08, green: 0.65, blue: 0.39, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let glyph = NSAttributedString(string: "あ", attributes: [
    .font: NSFont.systemFont(ofSize: 610, weight: .medium),
    .foregroundColor: NSColor.white
])
let measured = glyph.size()
glyph.draw(at: NSPoint(x: (1024 - measured.width) / 2, y: (1024 - measured.height) / 2 + 12))
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: "Vime/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let bitmap = NSBitmapImageRep(cgImage: drawing.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: url)
