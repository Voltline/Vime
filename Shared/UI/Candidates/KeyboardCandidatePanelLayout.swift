import CoreGraphics

/// Lays out the expanded candidate panel as a flow over the keyboard's column
/// grid. A candidate spans as many columns as its text needs, so short words
/// stay packed in the familiar grid while a long sentence takes a wider slot,
/// at most the whole row. A sentence wider than the row wraps onto a second
/// line; the button truncates anything beyond that in the middle, keeping the
/// sentence's start and end visible.
///
/// Candidates keep their ranked order: a slot that does not fit the rest of a
/// row starts the next row, and the row's last candidate grows to the row end
/// so every row stays aligned with the grid. Pure value math on widths that
/// KeyboardCandidateTextMetrics has already cached, so it runs in O(n).
nonisolated struct KeyboardCandidatePanelLayout: Equatable {
    struct Item: Equatable {
        var frame: CGRect
        /// Title lines the candidate shows; only a full-row candidate gets two.
        var lines: Int
    }

    /// Wrapping beyond two lines would push other candidates off screen.
    static let maximumLines = 2
    static let rowPitch: CGFloat = 46
    static let rowHeight: CGFloat = 41

    let items: [Item]
    let contentHeight: CGFloat

    /// - Parameters:
    ///   - widths: Each candidate's preferred width including its insets.
    ///   - left: The x of the first column.
    ///   - cellWidth: One column's pitch, including the trailing gap.
    ///   - gap: The space between neighbouring candidates.
    ///   - columns: Columns per row.
    ///   - extraLineHeight: Height a second title line adds.
    init(widths: [CGFloat], left: CGFloat, cellWidth: CGFloat, gap: CGFloat, columns: Int, extraLineHeight: CGFloat) {
        let columns = max(1, columns)
        let rowWidth = CGFloat(columns) * cellWidth - gap
        var items: [Item] = []
        items.reserveCapacity(widths.count)
        var column = 0, y: CGFloat = 0, rowLines = 1, rowStart = 0

        func finishRow() {
            // The row's last candidate takes any columns left unfilled.
            if let last = items.indices.last, last >= rowStart {
                items[last].frame.size.width = left + rowWidth - items[last].frame.minX
            }
            y += Self.rowPitch + CGFloat(rowLines - 1) * extraLineHeight
            column = 0; rowLines = 1; rowStart = items.count
        }

        for width in widths {
            let span = min(columns, max(1, Int(((width + gap) / cellWidth).rounded(.up))))
            if column > 0 && column + span > columns { finishRow() }
            let lines = span == columns && width > rowWidth ? Self.maximumLines : 1
            rowLines = max(rowLines, lines)
            let frame = CGRect(x: left + CGFloat(column) * cellWidth, y: y,
                width: CGFloat(span) * cellWidth - gap,
                height: Self.rowHeight + CGFloat(lines - 1) * extraLineHeight)
            items.append(Item(frame: frame, lines: lines))
            column += span
            if column == columns { finishRow() }
        }
        if column > 0 {
            // A partial last row keeps its natural widths; nothing follows it.
            y += Self.rowPitch + CGFloat(rowLines - 1) * extraLineHeight
        }
        self.items = items
        self.contentHeight = y
    }
}
