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
    var availableHeight: CGFloat? = nil
    var scale: CGFloat { min(width / 440, 1.3) }
    var toolbarButtonDiameter: CGFloat { compact ? 30 : 34.5 * scale }
    // Use the painted first-row edges for every compact header and panel.
    // Toolbar gaps stay fixed even when UIKit changes the keyboard's width.
    var contentLeft: CGFloat { frame(row: 0, column: 0).minX }
    var contentRight: CGFloat { frame(row: 0, column: 9).maxX }
    var contentWidth: CGFloat { contentRight - contentLeft }
    static let toolbarGap: CGFloat = 8
    func trailingToolbarFrame(index: Int) -> CGRect {
        let spacing = max(44, compact ? toolbarButtonDiameter + Self.toolbarGap : 46 * width / 440)
        let x = compact
            ? contentRight - toolbarButtonDiameter - CGFloat(index) * spacing
            : width - 46 * width / 440 - CGFloat(index) * spacing
        return CGRect(x: x, y: Self.toolbarTopInset, width: toolbarButtonDiameter, height: toolbarButtonDiameter)
    }
    // Include space below the toolbar, as well as its top inset and controls.
    // Otherwise a 30 pt control at y=8 touches the first key at y=38.
    var headerHeight: CGFloat { compact ? Self.toolbarTopInset + toolbarButtonDiameter + 8 : max(44, 56 * scale) }
    // A shorter portrait preference must not squeeze the landscape key plane.
    private var effectiveHeightFactor: CGFloat {
        guard compact else {
            guard let availableHeight, availableHeight > 0 else { return heightFactor }
            // A host can retain a shorter input-view frame across reconnects.
            // Lay out all four rows in that actual space, while preferredHeight
            // continues to use the user's factor without a feedback loop.
            let keyPlane = availableHeight - headerHeight - footerHeight - 1.5 * scale
            return max(0.1, keyPlane / ((56 * 3 + 46.5) * scale))
        }
        let minimum = max(1, heightFactor)
        guard let availableHeight else { return minimum }
        // UIKit may give the extension more height after rotation. Fill that
        // actual key plane without feeding its imposed size into our intrinsic height.
        let keyPlane = availableHeight - headerHeight - footerHeight - 1.5 * scale
        return max(1, keyPlane / (48 * 3 + 39))
    }
    var keyHeight: CGFloat { (compact ? 39 : 46.5 * scale) * effectiveHeightFactor }
    var rowStep: CGFloat { (compact ? 48 : 56 * scale) * effectiveHeightFactor }
    var contentHeight: CGFloat { headerHeight + rowStep * 3 + keyHeight + 1.5 * scale }
    // Reserve a footer only for our own globe. UIKit owns the system controls
    // outside this view; reserving them here again leaves a blank bottom band.
    var footerHeight: CGFloat { showsFooter ? (compact ? 36 : 78 * scale) : 0 }
    var height: CGFloat { contentHeight + footerHeight }

    func numberPadFrame(row: Int, column: Int) -> CGRect {
        // Digits occupy the central 3 × 3 grid; utilities flank it.
        let positions: [CGFloat] = [5, 90, 184, 278, 372]
        let widths: [CGFloat] = [79, 88, 88, 88, 63]
        return CGRect(x: positions[column] * width / 440, y: headerHeight + CGFloat(row) * rowStep,
                      width: widths[column] * width / 440, height: keyHeight)
    }

    /// Flick kana: a 3 × 4 grid of kana keys between two utility columns.
    /// A key spanning two rows (確定) covers the gap between them.
    func kanaFrame(row: Int, column: Int, rows span: Int = 1) -> CGRect {
        let positions: [CGFloat] = [5, 74, 173.3, 272.7, 372]
        let widths: [CGFloat] = [63, 93.3, 93.3, 93.3, 63]
        return CGRect(x: positions[column] * width / 440, y: headerHeight + CGFloat(row) * rowStep,
                      width: widths[column] * width / 440, height: keyHeight + CGFloat(span - 1) * rowStep)
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
