import Foundation
import CoreGraphics

/// Measured from the supplied 1320 px screenshot (440 pt @3x).
/// These coordinates keep the small letter keys and the asymmetric bottom row
/// independent of labels, locale, and the host's return-key type.
struct KeyboardMetrics {
    /// Owned by the keyboard, never inferred from a host view's safe-area margin.
    static let toolbarTopInset: CGFloat = 8
    /// The docked iPad keyboard is at least this wide (iPad mini portrait is 744 pt).
    /// The floating keyboard is narrower and keeps the iPhone layout.
    static let padMinimumWidth: CGFloat = 600
    let width: CGFloat
    let compact: Bool
    let showsFooter: Bool
    var heightFactor: CGFloat = 1
    var availableHeight: CGFloat? = nil
    /// The keyboard runs on an iPad. Only a docked, full-width keyboard uses the iPad layout.
    var pad = false
    /// iPad's docked keyboard: the phone's key plan stretched across the width,
    /// with taller rows, tighter gaps and a toolbar that does not grow with the width.
    var regular: Bool { pad && !compact && width >= Self.padMinimumWidth }
    var scale: CGFloat { min(width / 440, 1.3) }
    var toolbarButtonDiameter: CGFloat { compact ? 30 : regular ? 36 : 34.5 * scale }
    /// Compact and iPad toolbars align to the painted key edges with fixed gaps;
    /// the portrait phone toolbar scales with the width.
    var alignsToolbarToKeys: Bool { compact || regular }
    // Use the painted first-row edges for every compact header and panel.
    // Toolbar gaps stay fixed even when UIKit changes the keyboard's width.
    var contentLeft: CGFloat { frame(row: 0, column: 0).minX }
    var contentRight: CGFloat { frame(row: 0, column: 9).maxX }
    var contentWidth: CGFloat { contentRight - contentLeft }
    static let toolbarGap: CGFloat = 8
    /// iPad has no system globe below the keyboard; it sits at the toolbar's leading edge.
    var showsToolbarGlobe: Bool { regular && showsFooter }
    func trailingToolbarFrame(index: Int) -> CGRect {
        let spacing = max(44, alignsToolbarToKeys ? toolbarButtonDiameter + Self.toolbarGap : 46 * width / 440)
        let x = alignsToolbarToKeys
            ? contentRight - toolbarButtonDiameter - CGFloat(index) * spacing
            : width - 46 * width / 440 - CGFloat(index) * spacing
        return CGRect(x: x, y: Self.toolbarTopInset, width: toolbarButtonDiameter, height: toolbarButtonDiameter)
    }
    /// The globe (iPad only), then the brand button, from the leading edge.
    func leadingToolbarFrame(index: Int) -> CGRect {
        let spacing = max(44, toolbarButtonDiameter + Self.toolbarGap)
        return CGRect(x: contentLeft + CGFloat(index) * spacing, y: Self.toolbarTopInset,
                      width: toolbarButtonDiameter, height: toolbarButtonDiameter)
    }
    // Include space below the toolbar, as well as its top inset and controls.
    // Otherwise a 30 pt control at y=8 touches the first key at y=38.
    var headerHeight: CGFloat {
        compact || regular ? Self.toolbarTopInset + toolbarButtonDiameter + (regular ? 10 : 8) : max(44, 56 * scale)
    }
    /// iPad keys grow with the screen: about 64 pt on an 11" iPad in portrait and
    /// 76 pt on a 13" iPad in landscape, with a fixed 10 pt gap between rows.
    private var padKeyHeight: CGFloat { min(76, 44 + width * 0.024) }
    private var baseKeyHeight: CGFloat { compact ? 39 : regular ? padKeyHeight : 46.5 * scale }
    private var baseRowStep: CGFloat { compact ? 48 : regular ? padKeyHeight + 10 : 56 * scale }
    /// Space below the last row. iPad has no system bar there, so its keys need their own margin.
    private var bottomInset: CGFloat { regular ? 8 : 1.5 * scale }
    // A shorter portrait preference must not squeeze the landscape key plane.
    private var effectiveHeightFactor: CGFloat {
        guard compact else {
            guard let availableHeight, availableHeight > 0 else { return heightFactor }
            // A host can retain a shorter input-view frame across reconnects.
            // Lay out all four rows in that actual space, while preferredHeight
            // continues to use the user's factor without a feedback loop.
            let keyPlane = availableHeight - headerHeight - footerHeight - bottomInset
            return max(0.1, keyPlane / (baseRowStep * 3 + baseKeyHeight))
        }
        let minimum = max(1, heightFactor)
        guard let availableHeight else { return minimum }
        // UIKit may give the extension more height after rotation. Fill that
        // actual key plane without feeding its imposed size into our intrinsic height.
        let keyPlane = availableHeight - headerHeight - footerHeight - bottomInset
        return max(1, keyPlane / (baseRowStep * 3 + baseKeyHeight))
    }
    var keyHeight: CGFloat { baseKeyHeight * effectiveHeightFactor }
    var rowStep: CGFloat { baseRowStep * effectiveHeightFactor }
    var contentHeight: CGFloat { headerHeight + rowStep * 3 + keyHeight + bottomInset }
    // Reserve a footer only for our own globe. UIKit owns the system controls
    // outside this view; reserving them here again leaves a blank bottom band.
    // The iPad globe lives in the toolbar instead.
    var footerHeight: CGFloat { showsFooter && !regular ? (compact ? 36 : 78 * scale) : 0 }
    var height: CGFloat { contentHeight + footerHeight }

    /// Stretching the phone plan across an iPad would also stretch its gaps.
    /// Widen each key around its center instead, so gaps stay near 11 pt.
    private func stretched(_ frame: CGRect) -> CGRect {
        let xScale = width / 440
        guard regular, xScale > 1.6 else { return frame }
        let grow = 7 * (xScale - 1.6)
        return frame.insetBy(dx: -grow / 2, dy: 0)
    }

    func numberPadFrame(row: Int, column: Int) -> CGRect {
        // Digits occupy the central 3 × 3 grid; utilities flank it.
        let positions: [CGFloat] = [5, 90, 184, 278, 372]
        let widths: [CGFloat] = [79, 88, 88, 88, 63]
        return stretched(CGRect(x: positions[column] * width / 440, y: headerHeight + CGFloat(row) * rowStep,
                                width: widths[column] * width / 440, height: keyHeight))
    }

    /// Flick kana: a 3 × 4 grid of kana keys between two utility columns.
    /// A key spanning two rows (確定) covers the gap between them.
    func kanaFrame(row: Int, column: Int, rows span: Int = 1) -> CGRect {
        let positions: [CGFloat] = [5, 74, 173.3, 272.7, 372]
        let widths: [CGFloat] = [63, 93.3, 93.3, 93.3, 63]
        return stretched(CGRect(x: positions[column] * width / 440, y: headerHeight + CGFloat(row) * rowStep,
                                width: widths[column] * width / 440, height: keyHeight + CGFloat(span - 1) * rowStep))
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
        return stretched(CGRect(x: x * xScale, y: y, width: keyWidth * xScale, height: keyHeight))
    }
}
