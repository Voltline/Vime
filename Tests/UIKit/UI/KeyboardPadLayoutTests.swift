import XCTest
import UIKit

/// The docked iPad keyboard at 11" and 13" widths, in portrait and landscape,
/// and the floating keyboard's fallback to the iPhone layout.
@MainActor
final class KeyboardPadLayoutTests: XCTestCase {
    /// iPad mini, 11" and 13" iPads: (portrait, landscape) keyboard widths.
    private let sizes: [(name: String, portrait: CGFloat, landscape: CGFloat)] = [
        ("mini", 744, 1133), ("11in", 834, 1194), ("13in", 1032, 1376)]
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func view(_ id: String, in view: UIView) throws -> UIView {
        try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == id })
    }
    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(self.view(id, in: view) as? UIButton)
    }
    private func frame(_ view: UIView, in keyboard: UIView) -> CGRect { view.convert(view.bounds, to: keyboard) }
    private func capture(_ view: UIView, name: String) {
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: view.bounds).image {
            UIColor.systemBackground.setFill(); $0.fill(view.bounds); view.layer.render(in: $0.cgContext)
        })
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func makeKeyboard(width: CGFloat, kana: Bool = false, nineKeyNumbers: Bool = true,
                              session: KeyboardSession? = nil) -> KeyboardView {
        let suite = "VimePadLayoutTests." + UUID().uuidString
        suites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.phraseSuggestions = false
        preferences.kanaLayout = kana
        preferences.nineKeyNumbers = nineKeyNumbers
        let keyboard = KeyboardView(frame: .zero, session: session ?? KeyboardSession(), preferences: preferences)
        // iPad keyboards always need their own globe.
        keyboard.pad = true; keyboard.showsFooter = true; keyboard.needsGlobe = true
        keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.preferredHeight(for: width))
        keyboard.layoutIfNeeded()
        return keyboard
    }

    private func assertKeysSeparated(_ keyboard: KeyboardView, file: StaticString = #filePath, line: UInt = #line) throws {
        let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        XCTAssertFalse(surface.regions.isEmpty, file: file, line: line)
        for region in surface.regions {
            XCTAssertTrue(keyboard.bounds.contains(region.body), "\(region.body) leaves the keyboard", file: file, line: line)
            XCTAssertGreaterThanOrEqual(keyboard.bounds.maxY - region.body.maxY, 6,
                "iPad has no system bar below the last row", file: file, line: line)
            XCTAssertGreaterThanOrEqual(region.body.minY - keyboard.header.frame.maxY, 0, file: file, line: line)
            for other in surface.regions where other.key !== region.key {
                XCTAssertFalse(region.body.intersects(other.body), "Painted keys must stay separated", file: file, line: line)
            }
        }
    }

    func testDockedKeyboardFillsTheWidthWithIPadKeysInBothOrientations() throws {
        for size in sizes {
            let portrait = makeKeyboard(width: size.portrait).preferredHeight(for: size.portrait)
            let landscape = makeKeyboard(width: size.landscape).preferredHeight(for: size.landscape)
            XCTAssertGreaterThan(landscape, portrait, "\(size.name): landscape iPad keys are taller")
            for (orientation, width) in [("portrait", size.portrait), ("landscape", size.landscape)] {
                let keyboard = makeKeyboard(width: width)
                defer { keyboard.stopInteractions() }
                let metrics = KeyboardMetrics(width: width, compact: false, showsFooter: true, pad: true)
                XCTAssertTrue(metrics.regular)
                XCTAssertEqual(metrics.footerHeight, 0, "The iPad globe lives in the toolbar, not a footer band")
                XCTAssertEqual(keyboard.preferredHeight(for: width), metrics.contentHeight, accuracy: 0.001)
                XCTAssertTrue((300...420).contains(keyboard.bounds.height), "\(size.name) \(orientation): \(keyboard.bounds.height)")
                let q = try button("vime.key.q", in: keyboard), w = try button("vime.key.w", in: keyboard)
                let p = try button("vime.key.p", in: keyboard)
                XCTAssertTrue((60...76).contains(q.frame.height), "\(size.name) \(orientation): key height \(q.frame.height)")
                XCTAssertGreaterThan(q.frame.width, 60, "iPad letter keys are wider than any iPhone key")
                XCTAssertEqual(w.frame.minX - q.frame.maxX, 11.2, accuracy: 0.2, "Gaps stay fixed as keys widen")
                XCTAssertLessThanOrEqual(q.frame.minX, 16)
                XCTAssertGreaterThanOrEqual(p.frame.maxX, width - 16)
                // Toolbar: globe, then brand at the leading key edge; arrow at the trailing edge.
                let globe = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "切换系统键盘" } as? UIButton)
                let brand = try button("vime.brand.settings", in: keyboard)
                let arrow = try button("vime.candidates.expand", in: keyboard)
                XCTAssertFalse(globe.isHidden)
                let globeFrame = frame(globe, in: keyboard), brandFrame = frame(brand, in: keyboard)
                let arrowFrame = frame(arrow, in: keyboard)
                XCTAssertEqual(globeFrame.minX, q.frame.minX, accuracy: 0.001)
                XCTAssertEqual(brandFrame.midX - globeFrame.midX, 44, accuracy: 0.001)
                XCTAssertEqual(arrowFrame.maxX, p.frame.maxX, accuracy: 0.001)
                XCTAssertEqual(globeFrame.midY, brandFrame.midY, accuracy: 0.001)
                XCTAssertLessThanOrEqual(globeFrame.maxY + 8, q.frame.minY, "The toolbar needs room above the first row")
                XCTAssertTrue(keyboard.hitTest(CGPoint(x: globeFrame.midX, y: globeFrame.midY), with: nil) === globe)
                XCTAssertTrue(keyboard.hitTest(CGPoint(x: brandFrame.midX, y: brandFrame.midY), with: nil) === brand)
                try assertKeysSeparated(keyboard)
                capture(keyboard, name: "pad-\(size.name)-\(orientation)-letters")
                keyboard.keyboardType = .numberPad; keyboard.layoutIfNeeded()
                try assertKeysSeparated(keyboard)
                capture(keyboard, name: "pad-\(size.name)-\(orientation)-number-pad")
            }
        }
    }

    func testFlickKanaAndFullNumberPagesFitTheIPadKeyPlane() throws {
        for width in [CGFloat(834), 1376] {
            let kana = makeKeyboard(width: width, kana: true)
            defer { kana.stopInteractions() }
            try assertKeysSeparated(kana)
            let surface = try XCTUnwrap(descendants(kana).compactMap { $0 as? KeyboardTouchSurface }.first)
            let letters = makeKeyboard(width: width)
            defer { letters.stopInteractions() }
            let q = try button("vime.key.q", in: letters).frame
            XCTAssertEqual(surface.regions.map(\.body.minX).min() ?? 0, q.minX, accuracy: 0.001,
                "The flick pad shares the letter keys' edges")
            capture(kana, name: "pad-\(Int(width))-kana")
            let numbers = makeKeyboard(width: width, nineKeyNumbers: false)
            defer { numbers.stopInteractions() }
            numbers.keyboardType = .numbersAndPunctuation; numbers.layoutIfNeeded()
            try assertKeysSeparated(numbers)
            capture(numbers, name: "pad-\(Int(width))-numbers-full")
        }
    }

    func testIPadPanelsAlignToTheKeyPlaneAndKeepReadableLists() throws {
        for width in [CGFloat(834), 1032, 1194, 1376] {
            let session = KeyboardSession()
            let keyboard = makeKeyboard(width: width, session: session)
            defer { keyboard.stopInteractions() }
            let q = try button("vime.key.q", in: keyboard), p = try button("vime.key.p", in: keyboard)
            let left = q.frame.minX, right = p.frame.maxX
            let globe = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "切换系统键盘" } as? UIButton)

            _ = session.type("nihongo"); session.onCandidatesChange?(); keyboard.layoutIfNeeded()
            let strip = frame(try view("vime.candidates", in: keyboard), in: keyboard)
            let arrow = try button("vime.candidates.expand", in: keyboard)
            XCTAssertFalse(globe.isHidden, "The globe stays available while composing")
            XCTAssertGreaterThanOrEqual(strip.minX - globe.frame.midX, 22, "Candidates never cover the globe")
            XCTAssertGreaterThanOrEqual(arrow.frame.midX - strip.maxX, 22)
            capture(keyboard, name: "pad-\(Int(width))-candidate-strip")

            arrow.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
            let title = try view("vime.candidates.title", in: keyboard)
            let close = try button("vime.panel.close", in: keyboard)
            XCTAssertGreaterThanOrEqual(title.frame.minX, globe.frame.maxX)
            XCTAssertEqual(close.frame.maxX, right, accuracy: 0.001)
            let panel = try XCTUnwrap(view("vime.candidates.panel", in: keyboard) as? UIScrollView)
            let cells = panel.subviews.compactMap { $0 as? KeyboardCandidateButton }.filter { !$0.isHidden }
            XCTAssertGreaterThanOrEqual(Set(cells.map(\.frame.minY)).count, 1)
            XCTAssertGreaterThanOrEqual(cells.filter { $0.frame.minY == cells.first?.frame.minY }.count, 5,
                "A wide iPad shows more candidates per row")
            for cell in cells {
                XCTAssertGreaterThanOrEqual(cell.frame.minX, left - 0.001)
                XCTAssertLessThanOrEqual(cell.frame.maxX, right + 0.001)
            }
            capture(keyboard, name: "pad-\(Int(width))-expanded-candidates")
            close.sendActions(for: .touchUpInside); session.reset(); session.onCandidatesChange?(); keyboard.layoutIfNeeded()

            try button("vime.brand.settings", in: keyboard).sendActions(for: .touchUpInside)
            keyboard.layoutIfNeeded()
            let settings = try view("vime.settings", in: keyboard)
            settings.layoutIfNeeded()
            let stack = try XCTUnwrap(settings.subviews.compactMap { $0 as? UIStackView }.first)
            let pixel = 1 / keyboard.traitCollection.displayScale
            XCTAssertLessThanOrEqual(stack.frame.width, KeyboardView.padListWidth + pixel, "Settings keep a readable width")
            XCTAssertEqual(stack.frame.midX, width / 2, accuracy: pixel, "and sit centered over the keys")
            capture(keyboard, name: "pad-\(Int(width))-settings")

            keyboard.openClipboardHistory(); keyboard.layoutIfNeeded()
            let list = try view("vime.clipboard.history.list", in: keyboard)
            let listFrame = frame(list, in: keyboard)
            XCTAssertLessThanOrEqual(listFrame.width, KeyboardView.padListWidth + pixel)
            XCTAssertEqual(listFrame.midX, width / 2, accuracy: pixel)
            capture(keyboard, name: "pad-\(Int(width))-clipboard-history")
            try button("vime.clipboard.history.back", in: keyboard).sendActions(for: .touchUpInside)
            try button("vime.panel.close", in: keyboard).sendActions(for: .touchUpInside)
            keyboard.layoutIfNeeded()

            try button("vime.key.emoji", in: keyboard).sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
            let symbols = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardSymbolPanel }.first)
            XCTAssertTrue(globe.isHidden, "The symbol panel has its own header")
            for mode in [KeyboardSymbolPanel.Mode.emoji, .kaomoji, .symbols] {
                symbols.selectMode(mode); symbols.layoutIfNeeded()
                let grid = try XCTUnwrap(view("vime.symbols.grid", in: symbols) as? UICollectionView)
                grid.layoutIfNeeded()
                let gridFrame = frame(grid, in: keyboard)
                XCTAssertTrue(keyboard.bounds.insetBy(dx: -pixel, dy: -pixel).contains(gridFrame))
                let cells = grid.visibleCells.filter { !$0.isHidden }
                XCTAssertFalse(cells.isEmpty)
                XCTAssertGreaterThanOrEqual(Set(cells.map { $0.frame.minY.rounded() }).count, 5,
                    "The taller iPad panel shows at least as many rows as the iPhone")
                for cell in cells {
                    XCTAssertGreaterThanOrEqual(cell.frame.height, 40)
                    XCTAssertLessThanOrEqual(cell.frame.maxY, grid.bounds.height + pixel)
                }
                capture(keyboard, name: "pad-\(Int(width))-symbols-\(mode.rawValue)")
            }
        }
    }

    func testFloatingIPadKeyboardFallsBackToThePhoneLayout() throws {
        for width in [CGFloat(320), 375] {
            let keyboard = makeKeyboard(width: width)
            defer { keyboard.stopInteractions() }
            let phone = KeyboardMetrics(width: width, compact: false, showsFooter: true)
            let metrics = KeyboardMetrics(width: width, compact: false, showsFooter: true, pad: true)
            XCTAssertFalse(metrics.regular)
            XCTAssertEqual(keyboard.preferredHeight(for: width), phone.height, accuracy: 0.001)
            let q = try button("vime.key.q", in: keyboard)
            let expected = phone.frame(row: 0, column: 0)
            XCTAssertEqual(q.frame.minX, expected.minX, accuracy: 0.001)
            XCTAssertEqual(q.frame.width, expected.width, accuracy: 0.001)
            XCTAssertEqual(q.frame.height, expected.height, accuracy: 0.001)
            let globe = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "切换系统键盘" } as? UIButton)
            XCTAssertFalse(globe.isHidden)
            XCTAssertGreaterThanOrEqual(globe.frame.minY, phone.contentHeight, "The floating keyboard keeps the footer globe")
            try assertKeysSeparated(keyboard)
            capture(keyboard, name: "pad-floating-\(Int(width))")
        }
    }

    func testPhoneLayoutIsUnchangedAtIPadWidthsWithoutTheIPadFlag() {
        for width in [CGFloat(375), 440, 1032] {
            let phone = KeyboardMetrics(width: width, compact: false, showsFooter: false)
            XCTAssertFalse(phone.regular)
            let scale = min(width / 440, 1.3)
            XCTAssertEqual(phone.keyHeight, 46.5 * scale, accuracy: 0.001)
            XCTAssertEqual(phone.rowStep, 56 * scale, accuracy: 0.001)
            XCTAssertEqual(phone.height, max(44, 56 * scale) + 56 * scale * 3 + 46.5 * scale + 1.5 * scale, accuracy: 0.001)
            XCTAssertEqual(phone.frame(row: 0, column: 0).width, 36.8 * width / 440, accuracy: 0.001)
        }
    }

    func testInputRootSizesTheDockedIPadKeyboard() throws {
        let keyboard = makeKeyboard(width: 1032)
        defer { keyboard.stopInteractions() }
        let input = KeyboardInputView(keyboard: keyboard)
        input.frame = CGRect(x: 0, y: 0, width: 1032, height: 224)
        input.refreshSizing()
        XCTAssertEqual(input.intrinsicContentSize.height, keyboard.preferredHeight(for: 1032), accuracy: 0.001)
        input.frame.size.width = 1376; input.refreshSizing()
        XCTAssertEqual(input.intrinsicContentSize.height, keyboard.preferredHeight(for: 1376), accuracy: 0.001)
        keyboard.pad = false
        XCTAssertEqual(input.intrinsicContentSize.height, KeyboardMetrics(width: 1376, compact: false, showsFooter: true).height,
            accuracy: 0.001, "Leaving the iPad (e.g. a test host) restores the phone height")
    }
}
