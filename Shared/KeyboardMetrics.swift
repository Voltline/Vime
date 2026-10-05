import Foundation
import CoreGraphics

/// Measured from the supplied 1320 px screenshot (440 pt @3x).
/// These coordinates keep the small letter keys and the asymmetric bottom row
/// independent of labels, locale, and the host's return-key type.
struct KeyboardMetrics {
    /// Owned by the keyboard, never inferred from a host view's safe-area margin.
    static let toolbarTopInset: CGFloat = 8
    let width: CGFloat
    let compact: Bool
    let showsFooter: Bool
    var heightFactor: CGFloat = 1
    var scale: CGFloat { min(width / 440, 1.3) }
    var headerHeight: CGFloat { compact ? 38 : 56 * scale }
    var keyHeight: CGFloat { (compact ? 33 : 46.5 * scale) * heightFactor }
    var rowStep: CGFloat { (compact ? 38 : 56 * scale) * heightFactor }
    var contentHeight: CGFloat { headerHeight + rowStep * 3 + keyHeight + 1.5 * scale }
    var footerHeight: CGFloat { showsFooter ? (compact ? 36 : 78 * scale) : 0 }
    var height: CGFloat { contentHeight + footerHeight }

    func numberPadFrame(row: Int, column: Int) -> CGRect {
        // Digits occupy the central 3 × 3 grid; utilities flank it.
        let positions: [CGFloat] = [5, 72, 172, 272, 372]
        let widths: [CGFloat] = [61, 94, 94, 94, 63]
        return CGRect(x: positions[column] * width / 440, y: headerHeight + CGFloat(row) * rowStep,
                      width: widths[column] * width / 440, height: keyHeight)
    }

    func frame(row: Int, column: Int, letters: Bool = true, prolonged: Bool = false) -> CGRect {
        let xScale = width / 440
        let y = headerHeight + CGFloat(row) * rowStep
        let x: CGFloat
        let keyWidth: CGFloat
        if row == 3 {
            let positions: [CGFloat] = [5, 70.7, 114.5, 158.3, 301.1, 348.6]
            let widths: [CGFloat] = [59.8, 36.8, 36.8, 136.5, 41.2, 86.4]
            x = positions[column]
            keyWidth = widths[column]
        } else if letters && row == 1 && !prolonged {
            x = 27.5 + CGFloat(column) * 43.75
            keyWidth = 36.8
        } else if row == 2 {
            let positions: [CGFloat] = [5, 70.7, 114.5, 158.3, 202.1, 245.9, 289.7, 333.5, 385.4]
            x = positions[column]
            keyWidth = column == 0 || column == 8 ? 49.6 : 36.8
        } else {
            x = 5 + CGFloat(column) * 43.8
            keyWidth = 36.8
        }
        return CGRect(x: x * xScale, y: y, width: keyWidth * xScale, height: keyHeight)
    }
}
