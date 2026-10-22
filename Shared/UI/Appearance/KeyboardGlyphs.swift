import UIKit

enum KeyboardGlyphs {
    static func logo(size: CGFloat = 32, appIcon: Bool = false) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { renderer in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            if appIcon {
                UIColor(cgColor: VimeLogo.blue).setFill(); renderer.fill(rect)
            }
            VimeLogo.draw(in: renderer.cgContext, rect: rect,
                          color: appIcon ? UIColor.white.cgColor : VimeLogo.blue)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Two-segment pill: the input language on the left, English on the right,
    /// with the active side filled.
    static func language(active: KeyboardInputLanguage, other: KeyboardInputLanguage) -> UIImage {
        let size = CGSize(width: 38, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let outline = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75),
                                       cornerRadius: size.height / 2)
            outline.lineWidth = 1.2
            UIColor.label.withAlphaComponent(0.35).setStroke()
            outline.stroke()
            let segments = active == .english ? [other, active] : [active, other]
            for (index, language) in segments.enumerated() {
                let half = CGRect(x: CGFloat(index) * size.width / 2, y: 0, width: size.width / 2, height: size.height)
                let isActive = language == active
                if isActive {
                    let fill = half.insetBy(dx: 2.5, dy: 2.5)
                    UIColor.label.setFill()
                    UIBezierPath(roundedRect: fill, cornerRadius: fill.height / 2).fill()
                }
                let text = language.glyph as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: isActive ? UIColor.systemBackground : UIColor.label.withAlphaComponent(0.45),
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: half.midX - textSize.width / 2, y: half.midY - textSize.height / 2),
                          withAttributes: attributes)
            }
        }.withRenderingMode(.alwaysOriginal)
    }

}
