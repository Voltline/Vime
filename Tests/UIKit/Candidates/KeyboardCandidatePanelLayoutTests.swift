import XCTest

/// The expanded panel's flow over the column grid, as pure layout math.
final class KeyboardCandidatePanelLayoutTests: XCTestCase {
    /// iPhone portrait, not aligned to keys: three 115 pt columns, 5 pt gaps.
    private func layout(_ widths: [CGFloat], columns: Int = 3, cell: CGFloat = 115, gap: CGFloat = 5,
                        left: CGFloat = 8) -> KeyboardCandidatePanelLayout {
        KeyboardCandidatePanelLayout(widths: widths, left: left, cellWidth: cell, gap: gap, columns: columns,
            extraLineHeight: 22)
    }

    func testShortWordsKeepTheColumnGrid() {
        let value = layout([60, 70, 50, 60, 48])
        XCTAssertEqual(value.items.map(\.frame), [
            CGRect(x: 8, y: 0, width: 110, height: 41), CGRect(x: 123, y: 0, width: 110, height: 41),
            CGRect(x: 238, y: 0, width: 110, height: 41),
            CGRect(x: 8, y: 46, width: 110, height: 41), CGRect(x: 123, y: 46, width: 110, height: 41)])
        XCTAssertEqual(value.items.map(\.lines), [1, 1, 1, 1, 1])
        XCTAssertEqual(value.contentHeight, 92)
    }

    func testCandidateSpansTheColumnsItsTextNeeds() {
        // 110 fits one column exactly; 111 needs two; 226 needs three.
        let value = layout([110, 111, 60, 226])
        XCTAssertEqual(value.items.map(\.frame.width), [110, 225, 340, 340])
        XCTAssertEqual(value.items.map(\.frame.minX), [8, 123, 8, 8])
        XCTAssertEqual(value.items.map(\.frame.minY), [0, 0, 46, 92], "A slot that does not fit starts the next row")
        XCTAssertEqual(value.items.map(\.lines), [1, 1, 1, 1])
    }

    func testRankedOrderIsKeptAndTheRowEndIsFilled() {
        // The 60 pt word would fit beside the first, but candidates never jump ahead.
        let value = layout([200, 200, 60])
        XCTAssertEqual(value.items.map(\.frame.minY), [0, 46, 46])
        XCTAssertEqual(value.items[0].frame, CGRect(x: 8, y: 0, width: 340, height: 41),
            "The last candidate of a row grows to the row end")
        XCTAssertEqual(value.items[1].frame.width, 225)
        XCTAssertEqual(value.items[2].frame, CGRect(x: 238, y: 46, width: 110, height: 41))
        XCTAssertEqual(value.contentHeight, 92)
    }

    func testPartialLastRowKeepsNaturalWidths() {
        let value = layout([60])
        XCTAssertEqual(value.items.first?.frame.width, 110)
        XCTAssertEqual(value.contentHeight, 46)
    }

    func testOverlongSentenceTakesTheRowAndWrapsToTwoLines() {
        let value = layout([60, 900, 60])
        XCTAssertEqual(value.items[0].frame, CGRect(x: 8, y: 0, width: 340, height: 41))
        XCTAssertEqual(value.items[1].frame, CGRect(x: 8, y: 46, width: 340, height: 63),
            "Never wider than the row, at most two lines tall")
        XCTAssertEqual(value.items[1].lines, KeyboardCandidatePanelLayout.maximumLines)
        XCTAssertEqual(value.items[2].frame, CGRect(x: 8, y: 114, width: 110, height: 41),
            "Rows after a two-line sentence move down by the extra line")
        XCTAssertEqual(value.contentHeight, 160)
    }

    func testSentenceThatFitsTheRowStaysOnOneLine() {
        let value = layout([340])
        XCTAssertEqual(value.items.first?.lines, 1)
        XCTAssertEqual(value.items.first?.frame.width, 340)
    }

    func testFramesNeverOverlapOrLeaveTheRow() {
        let widths: [CGFloat] = (0..<300).map { CGFloat(30 + ($0 * 97) % 700) }
        for (columns, cell, gap, left) in [(3, 115.0, 5.0, 8.0), (5, 166.4, 8.0, 12.0), (8, 160.0, 8.0, 20.0)] {
            let value = layout(widths, columns: columns, cell: CGFloat(cell), gap: CGFloat(gap), left: CGFloat(left))
            let right = CGFloat(left) + CGFloat(columns) * CGFloat(cell) - CGFloat(gap)
            XCTAssertEqual(value.items.count, widths.count)
            for (index, item) in value.items.enumerated() {
                XCTAssertGreaterThanOrEqual(item.frame.minX, CGFloat(left) - 0.001)
                XCTAssertLessThanOrEqual(item.frame.maxX, right + 0.001)
                XCTAssertGreaterThanOrEqual(item.frame.width, min(widths[index], right - CGFloat(left)) - 0.001,
                    "Every candidate fits, up to the whole row")
                if index > 0 {
                    let previous = value.items[index - 1].frame
                    XCTAssertTrue(item.frame.minY > previous.minY
                        || (item.frame.minY == previous.minY && item.frame.minX >= previous.maxX + CGFloat(gap) - 0.001),
                        "Reading order follows ranking")
                }
            }
            XCTAssertEqual(value.contentHeight, value.items.map(\.frame.maxY).max()! + 5, accuracy: 0.001)
        }
    }

    func testSingleColumnFloatingFallback() {
        let value = layout([40, 400], columns: 1, cell: 300, gap: 5)
        XCTAssertEqual(value.items.map(\.frame.width), [295, 295])
        XCTAssertEqual(value.items.map(\.lines), [1, 2])
    }
}
