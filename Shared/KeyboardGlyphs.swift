import UIKit

enum KeyboardGlyphs {
    static func settings() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { _ in
            let path = UIBezierPath()
            for (y, knob) in [(7.0, 10.0), (13.0, 17.0), (19.0, 8.0)] {
                path.move(to: CGPoint(x: 4, y: y)); path.addLine(to: CGPoint(x: 22, y: y))
                let circle = UIBezierPath(ovalIn: CGRect(x: knob - 2.5, y: y - 2.5, width: 5, height: 5))
                UIColor.systemGreen.setFill(); circle.fill()
            }
            path.lineWidth = 1.8; path.lineCapStyle = .round
            UIColor.systemGreen.setStroke(); path.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    static func language(english: Bool = false) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
            ((english ? "英" : "日") as NSString).draw(at: CGPoint(x: 3, y: 1), withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor.label])
            ((english ? "日" : "英") as NSString).draw(at: CGPoint(x: 17, y: 15), withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor(white: 0.66, alpha: 1)])
            let arrows = UIBezierPath()
            arrows.move(to: CGPoint(x: 19, y: 7))
            arrows.addLine(to: CGPoint(x: 22, y: 7))
            arrows.addQuadCurve(to: CGPoint(x: 26, y: 11), controlPoint: CGPoint(x: 26, y: 7))
            arrows.addLine(to: CGPoint(x: 26, y: 14))
            arrows.move(to: CGPoint(x: 12, y: 25))
            arrows.addLine(to: CGPoint(x: 9, y: 25))
            arrows.addQuadCurve(to: CGPoint(x: 5, y: 21), controlPoint: CGPoint(x: 5, y: 25))
            arrows.addLine(to: CGPoint(x: 5, y: 18))
            arrows.lineWidth = 1.5
            UIColor(white: 0.7, alpha: 1).setStroke()
            arrows.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

}
