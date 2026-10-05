import AppKit

// Run: swiftc Shared/VimeLogo.swift Scripts/generate_icon.swift -o /tmp/vime-icon
//      /tmp/vime-icon
@main
struct GenerateVimeIcon {
    static func main() throws {
        let size = 1024
        let drawing = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        drawing.setFillColor(VimeLogo.blue); drawing.fill(rect)
        // Use UIKit's downward y axis, so the logo has exactly the same geometry.
        drawing.translateBy(x: 0, y: CGFloat(size)); drawing.scaleBy(x: 1, y: -1)
        VimeLogo.draw(in: drawing, rect: rect, color: NSColor.white.cgColor)
        let url = URL(fileURLWithPath: "Vime/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
        let bitmap = NSBitmapImageRep(cgImage: drawing.makeImage()!)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
