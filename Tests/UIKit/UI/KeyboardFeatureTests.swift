import XCTest
import UIKit
import CoreText
import Compression

@MainActor
final class KeyboardFeatureTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func fixture(session: KeyboardSession? = nil) throws -> (KeyboardView, KeyboardTouchSurface, UITextView, UIWindow) {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 240, width: 440, height: 350), session: session ?? KeyboardSession())
        keyboard.hasFullAccess = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        let text = UITextView(frame: CGRect(x: 0, y: 0, width: 440, height: 220))
        text.font = .systemFont(ofSize: 23)
        window.rootViewController?.view.addSubview(text)
        window.rootViewController?.view.addSubview(keyboard)
        window.isHidden = false
        keyboard.layoutIfNeeded()
        var x: CGFloat?
        let host = KeyboardHostConnection(setMarkedText: { text.setMarkedText($0, selectedRange: $1) },
            unmarkText: { text.unmarkText() }, insertText: { text.insertText($0) }, deleteBackward: { text.deleteBackward() },
            moveCursor: { KeyboardTextNavigation.move(in: text, horizontal: $0, vertical: $1, preferredX: &x) },
            deleteToLineStart: { KeyboardTextNavigation.deleteLinePrefix(in: text) },
            undoAnchor: {
                let value = text.text as NSString, range = text.selectedRange
                return KeyboardUndoAnchor(document: "fixture", before: value.substring(to: range.location),
                    after: value.substring(from: NSMaxRange(range)), selection: value.substring(with: range))
            })
        host.onUndoAvailabilityChange = { [weak keyboard] in keyboard?.canUndoLineDeletion = $0 }
        keyboard.onEdit = { host.apply($0) }; keyboard.onPreeditChange = { host.updatePreedit($0) }
        keyboard.onReplaceText = { host.replaceText($0) }
        keyboard.deletionAvailabilityProvider = { text.selectedRange.length > 0 || text.selectedRange.location > 0 }
        return (keyboard, try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first), text, window)
    }

    private func point(_ id: String, in surface: KeyboardTouchSurface) throws -> CGPoint {
        let region = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == id })
        return CGPoint(x: region.body.midX, y: region.body.midY)
    }

    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == id } as? UIButton)
    }

    private func attachAppearance(_ view: UIView, name: String) {
        view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image {
            UIColor.systemBackground.setFill(); $0.fill(view.bounds)
            view.layer.render(in: $0.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment) // Local xcresult only; never added to repository assets.
    }

    func testHorizontalSweepMovesCaretWithoutTypingAndRestoresKeys() throws {
        let session = KeyboardSession()
        let (keyboard, surface, text, window) = try fixture(session: session)
        defer { keyboard.stopInteractions(); window.isHidden = true }
        text.text = "abc👩🏽‍💻def"; text.selectedRange = NSRange(location: 0, length: 0)
        let q = try point("vime.key.q", in: surface)
        surface.beginPress(id: 1, at: q)
        let start = CGPoint(x: q.x + 80, y: q.y)
        surface.movePress(id: 1, to: start)
        XCTAssertTrue(surface.regions.allSatisfy { $0.key.alpha == 0 })
        let end = CGPoint(x: start.x + 24, y: start.y)
        surface.movePress(id: 1, to: end)
        surface.endPress(id: 1, at: end)
        XCTAssertEqual(text.selectedRange.location, "abc👩🏽‍💻".utf16.count, "Each step crosses a complete composed character")
        XCTAssertEqual(text.text, "abc👩🏽‍💻def")
        XCTAssertNil(session.preedit)
        XCTAssertTrue(surface.regions.allSatisfy { $0.key.alpha == 1 })
        surface.beginPress(id: 2, at: q)
        surface.movePress(id: 2, to: start)
        surface.endPress(id: 2, at: start, cancelled: true)
        XCTAssertTrue(surface.regions.allSatisfy { $0.key.alpha == 1 })
        XCTAssertEqual(text.text, "abc👩🏽‍💻def")
    }

    func testOneKeyHorizontalDriftInputsOriginalCharacterInHost() throws {
        let session = KeyboardSession()
        let (keyboard, surface, text, window) = try fixture(session: session)
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let origin = try point("vime.key.e", in: surface)
        let neighbor = try point("vime.key.w", in: surface)
        surface.beginPress(id: 1, at: origin)
        surface.movePress(id: 1, to: neighbor)
        XCTAssertTrue(text.text.isEmpty, "Moving one key does not edit the host or move its caret")
        surface.endPress(id: 1, at: neighbor)
        XCTAssertEqual(session.composition, "え")
        XCTAssertEqual(text.text, "え", "The original e key, not the neighboring w, reaches the host")
    }

    func testLongSpaceMovesAcrossLinesAndShortSpaceStillInserts() async throws {
        let (keyboard, surface, text, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true }
        text.text = "abcdef\nabcdef\nabcdef"; text.selectedRange = NSRange(location: 2, length: 0)
        text.layoutIfNeeded()
        let space = try point("vime.key.space", in: surface)
        surface.beginPress(id: 1, at: space)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(surface.regions.allSatisfy { $0.key.alpha == 0 })
        let down = CGPoint(x: space.x + 8 * surface.scale, y: space.y + 24 * surface.scale)
        surface.movePress(id: 1, to: down)
        surface.endPress(id: 1, at: down)
        XCTAssertEqual(text.selectedRange.location, 10, "Move right once and down to the same column")
        XCTAssertEqual(text.text, "abcdef\nabcdef\nabcdef", "Long space does not insert a space")
        surface.beginPress(id: 2, at: space); surface.endPress(id: 2, at: space)
        XCTAssertEqual(text.text, "abcdef\nabc def\nabcdef")

        let layout = KeyboardProxyCursorLayout()
        let prefix = "abc👩🏽‍💻"
        layout.beginGesture(before: prefix, after: "d\nx\nabc👩🏽‍💻d", width: 440)
        let offset = layout.moveInGesture(horizontal: 0, vertical: 1)
        XCTAssertEqual(offset, 3, "Proxy offset uses UTF-16 and clamps the preferred column on a short line")
        let next = layout.moveInGesture(horizontal: 0, vertical: 1)
        XCTAssertEqual(prefix.utf16.count + offset + next, "abc👩🏽‍💻d\nx\nabc👩🏽‍💻".utf16.count,
                       "Production gesture navigation restores the column after a short line without splitting emoji")
    }

    func testDeleteSwipeRemovesOnlyPrefixAndCancellationDoesNotDelete() throws {
        let (keyboard, surface, text, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let region = try XCTUnwrap(surface.regions.first { $0.key.repeats })
        let center = CGPoint(x: region.body.midX, y: region.body.midY)
        let up = CGPoint(x: center.x, y: center.y - 40 * surface.scale)
        text.text = "first\nprefixsuffix"; text.selectedRange = NSRange(location: 12, length: 0)
        surface.beginPress(id: 1, at: center)
        XCTAssertEqual(text.text, "first\nprefixsuffix", "No early backspace before the gesture is resolved")
        surface.movePress(id: 1, to: up); surface.endPress(id: 1, at: up)
        XCTAssertEqual(text.text, "first\nsuffix")
        XCTAssertEqual(text.selectedRange.location, 6)
        let undo = try button("vime.delete.undo", in: keyboard)
        XCTAssertFalse(undo.isHidden)
        undo.sendActions(for: .touchUpInside)
        XCTAssertEqual(text.text, "first\nprefixsuffix")
        XCTAssertTrue(undo.isHidden)
        surface.beginPress(id: 10, at: center)
        let prompt = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.delete.prompt" })
        XCTAssertTrue(prompt.isHidden, "Ordinary backspace must not show a floating prompt")
        XCTAssertLessThanOrEqual(prompt.frame.maxY, region.body.minY)
        surface.movePress(id: 10, to: up); keyboard.layoutIfNeeded()
        XCTAssertFalse(prompt.isHidden, "Show the prompt only after an upward deletion gesture")
        attachAppearance(keyboard, name: "delete-swipe-callout")
        surface.movePress(id: 10, to: center); surface.endPress(id: 10, at: center)
        XCTAssertEqual(text.text, "first\nprefixsuffix", "Sliding back cancels line deletion without a stray backspace")
        XCTAssertTrue(prompt.isHidden)
        surface.beginPress(id: 11, at: center)
        surface.movePress(id: 11, to: up); surface.endPress(id: 11, at: up)
        text.text = "different document"; text.selectedRange = NSRange(location: 0, length: 0)
        undo.sendActions(for: .touchUpInside)
        XCTAssertEqual(text.text, "different document", "Stale undo cannot insert at a different position/document")
        text.text = "first\nsuffix"; text.selectedRange = NSRange(location: 6, length: 0)
        surface.beginPress(id: 2, at: center)
        surface.movePress(id: 2, to: up); surface.endPress(id: 2, at: up)
        XCTAssertEqual(text.text, "first\nsuffix", "At the start of a line, preserve the preceding newline")
        text.selectedRange = NSRange(location: text.text.utf16.count, length: 0)
        surface.beginPress(id: 3, at: center)
        surface.movePress(id: 3, to: up); surface.endPress(id: 3, at: up, cancelled: true)
        XCTAssertEqual(text.text, "first\nsuffix")
        surface.beginPress(id: 4, at: center); surface.endPress(id: 4, at: center)
        XCTAssertEqual(text.text, "first\nsuffi", "An ordinary short backspace still deletes once")
    }

    func testKatakanaPanelExclusivityAndSymbolExit() async throws {
        let session = KeyboardSession()
        let (keyboard, surface, text, window) = try fixture(session: session)
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let brand = try button("vime.brand.settings", in: keyboard)
        let candidates = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates.panel" })
        brand.sendActions(for: .touchUpInside)
        let settings = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.settings" })
        XCTAssertFalse(settings.isHidden)
        XCTAssertTrue(surface.isHidden)
        XCTAssertTrue(candidates.isHidden)
        brand.sendActions(for: .touchUpInside)
        XCTAssertTrue(settings.isHidden)
        XCTAssertFalse(surface.isHidden)
        brand.sendActions(for: .touchUpInside)
        try button("vime.panel.close", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertTrue(settings.isHidden)
        XCTAssertFalse(surface.isHidden)
        for c in "nihongo" { try button("vime.key.\(c)", in: keyboard).sendActions(for: .touchUpInside) }
        let index = try XCTUnwrap(session.candidates.firstIndex(of: "ニホンゴ"))
        XCTAssertLessThan(index, session.candidates.count, "Direct katakana remains available without a reserved slot")
        let strip = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates" })
        XCTAssertFalse(strip.isHidden)
        try button("vime.candidates.expand", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertTrue(strip.isHidden)
        XCTAssertTrue(surface.isHidden)
        XCTAssertFalse(candidates.isHidden)
        XCTAssertTrue(settings.isHidden)
        try button("vime.panel.close", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertFalse(strip.isHidden)
        XCTAssertTrue(candidates.isHidden)
        keyboard.resetComposition()
        let emoji = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "表情" } as? UIButton)
        emoji.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        let panel = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardSymbolPanel }.first)
        let grid = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        for scroll in descendants(panel).compactMap({ $0 as? UIScrollView }) {
            XCTAssertEqual(scroll.contentInsetAdjustmentBehavior, .never)
            if #available(iOS 26.0, *) {
                XCTAssertTrue(scroll.topEdgeEffect.isHidden)
                XCTAssertTrue(scroll.bottomEdgeEffect.isHidden, "No glass overlay over the last emoji row")
            }
        }
        XCTAssertFalse(panel.isHidden)
        XCTAssertTrue(candidates.isHidden)
        XCTAssertTrue(settings.isHidden)
        XCTAssertEqual(panel.frame, keyboard.bounds, "Use the former header and footer for symbols")
        XCTAssertTrue(strip.superview?.isHidden ?? false, "No title/header above symbols")
        XCTAssertTrue(surface.isHidden)
        XCTAssertEqual(KeyboardSymbolCatalog.emoji.version, "18.0", "The generated catalog must be bundled in the app/extension")
        let items = KeyboardSymbolCatalog.emoji.groups.flatMap(\.items)
        XCTAssertEqual(items.count, 3972)
        XCTAssertEqual(Set(items.map(\.text)).count, items.count)
        XCTAssertTrue(items.contains { $0.text == "👩🏽‍💻" })
        XCTAssertTrue(items.contains { $0.text == "🇯🇵" })
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(grid.numberOfItems(inSection: 0), 100)
        panel.layoutIfNeeded(); grid.layoutIfNeeded()
        attachAppearance(keyboard, name: "emoji-panel")
        let mode = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.mode" } as? UISegmentedControl)
        mode.selectedSegmentIndex = 1; mode.sendActions(for: .valueChanged); panel.layoutIfNeeded()
        XCTAssertEqual(KeyboardSymbolCatalog.kaomoji.flatMap(\.items).count, 160)
        XCTAssertEqual(grid.numberOfItems(inSection: 10), 20)
        grid.layoutIfNeeded()
        attachAppearance(keyboard, name: "kaomoji-panel")
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: 10))
        XCTAssertEqual(text.text, "(^_^)")
        XCTAssertFalse(panel.isHidden, "Keep the panel open for repeated symbol insertion")
        try button("vime.symbols.close", in: panel).sendActions(for: .touchUpInside)
        XCTAssertTrue(panel.isHidden)
        XCTAssertFalse(surface.isHidden)
    }

    func testDeleteRepeatsStopFeedbackAtEmptyAndAtCaretStart() async throws {
        let (keyboard, surface, text, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let deletion = try XCTUnwrap(surface.regions.first { $0.key.repeats })
        let center = CGPoint(x: deletion.body.midX, y: deletion.body.midY)
        var feedback = 0
        deletion.key.feedback = { feedback += 1 }
        text.text = "ab"; text.selectedRange = NSRange(location: 2, length: 0)
        surface.beginPress(id: 1, at: center)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(text.text, "")
        XCTAssertGreaterThan(feedback, 0)
        let stopped = feedback
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(feedback, stopped, "No feedback continues after the final character is deleted")
        surface.endPress(id: 1, at: center)
        surface.beginPress(id: 2, at: center)
        try await Task.sleep(for: .milliseconds(500))
        surface.endPress(id: 2, at: center)
        XCTAssertEqual(feedback, stopped, "Pressing and holding an empty delete produces no sound/haptics")
        text.text = "suffix"; text.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertTrue(deletion.key.accessibilityActivate())
        XCTAssertEqual(feedback, stopped, "Text after the caret is not deletable content")
        XCTAssertEqual(text.text, "suffix")
        text.selectedRange = NSRange(location: 0, length: 6)
        XCTAssertTrue(deletion.key.accessibilityActivate())
        XCTAssertEqual(text.text, "")
        XCTAssertEqual(feedback, stopped + 1, "A selected range can be deleted even at the start")
        try button("vime.key.a", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertFalse(text.text.isEmpty)
        XCTAssertTrue(deletion.key.accessibilityActivate())
        XCTAssertEqual(text.text, "", "Uncommitted composition remains deletable")
    }

    func testNativeInputClickOwnerAndBlueActionReturn() throws {
        let (keyboard, _, _, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let oldSound = keyboard.preferences.sound
        defer { keyboard.preferences.sound = oldSound }
        let input = KeyboardInputView(keyboard: keyboard)
        let globe = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "切换系统键盘" } as? UIButton)
        keyboard.needsGlobe = true
        XCTAssertTrue(globe.actions(forTarget: keyboard, forControlEvent: .touchDown)?.contains("toolbarFeedback") == true)
        keyboard.needsGlobe = false
        XCTAssertTrue(globe.actions(forTarget: keyboard, forControlEvent: .touchDown)?.contains("toolbarFeedback") == true)
        keyboard.preferences.sound = true
        XCTAssertTrue(input.enableInputClicksWhenVisible)
        keyboard.preferences.sound = false
        XCTAssertFalse(input.enableInputClicksWhenVisible)
        keyboard.returnKeyType = .send
        let key = try XCTUnwrap(button("vime.key.return", in: keyboard) as? KeyboardKey)
        XCTAssertEqual(key.title(for: .normal), "发送")
        XCTAssertEqual(key.fillColor, UIColor(cgColor: VimeLogo.blue))
        XCTAssertEqual(key.titleColor(for: .normal), .white)
        try button("vime.key.a", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(key.title(for: .normal), "確定")
        XCTAssertNotEqual(key.fillColor, UIColor(cgColor: VimeLogo.blue))
        keyboard.resetComposition()
        XCTAssertEqual(key.fillColor, UIColor(cgColor: VimeLogo.blue))
        keyboard.returnKeyType = .default
        XCTAssertNotEqual(key.fillColor, UIColor(cgColor: VimeLogo.blue))
    }

    func testCategorizedSymbolsFromBothNumericLayouts() throws {
        let (keyboard, _, text, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let oldLayout = keyboard.preferences.nineKeyNumbers
        defer { keyboard.preferences.nineKeyNumbers = oldLayout }
        let settings = try button("vime.brand.settings", in: keyboard)
        keyboard.returnKeyType = .send
        attachAppearance(keyboard, name: "blue-logo-send")
        for nineKey in [true, false] {
            settings.sendActions(for: .touchUpInside)
            let layout = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.setting.numbers" } as? UISegmentedControl)
            layout.selectedSegmentIndex = nineKey ? 0 : 1; layout.sendActions(for: .valueChanged)
            settings.sendActions(for: .touchUpInside)
            let numeric = try XCTUnwrap(descendants(keyboard).first { ($0 as? UIButton)?.title(for: .normal) == "123" } as? UIButton)
            numeric.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
            let symbols = try button(nineKey ? "vime.number.符号" : "vime.key.symbols", in: keyboard)
            symbols.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
            let panel = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardSymbolPanel }.first)
            let mode = try XCTUnwrap(descendants(panel).compactMap { $0 as? UISegmentedControl }.first)
            XCTAssertEqual(mode.selectedSegmentIndex, KeyboardSymbolPanel.Mode.symbols.rawValue)
            let arrows = try XCTUnwrap(descendants(panel).first { ($0 as? UIButton)?.title(for: .normal) == "箭头" } as? UIButton)
            arrows.sendActions(for: .touchUpInside); panel.layoutIfNeeded()
            let grid = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
            XCTAssertGreaterThanOrEqual(grid.numberOfItems(inSection: 19), 4)
            text.text = ""; text.selectedRange = NSRange(location: 0, length: 0)
            for i in 0..<4 { panel.collectionView(grid, didSelectItemAt: IndexPath(item: i, section: 19)) }
            XCTAssertEqual(text.text, "↑↓←→")
            XCTAssertFalse(panel.isHidden)
            attachAppearance(keyboard, name: nineKey ? "symbols-arrows" : "symbols-arrows-full-numbers")
            try button("vime.symbols.close", in: panel).sendActions(for: .touchUpInside)
            let abc = try XCTUnwrap(descendants(keyboard).first { ($0 as? UIButton)?.title(for: .normal) == "ABC" } as? UIButton)
            abc.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        }
        XCTAssertGreaterThan(KeyboardSymbolCatalog.symbols.flatMap(\.items).count, 450)
        for group in KeyboardSymbolCatalog.symbols {
            XCTAssertFalse(group.items.contains { $0.text.isEmpty })
            XCTAssertEqual(Set(group.items.map(\.text)).count, group.items.count)
        }
        XCTAssertTrue(KeyboardSymbolCatalog.symbols[0].items.contains { $0.text == "|" })
    }

    func testSymbolsScrollContinuouslyAndTabsTrackCategoryBoundaries() async throws {
        let panel = KeyboardSymbolPanel(frame: CGRect(x: 0, y: 0, width: 440, height: 350))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController?.view.addSubview(panel)
        defer { window.isHidden = true }
        panel.layoutIfNeeded()
        let grid = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.grid" } as? UICollectionView)
        let modes = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.mode" } as? UISegmentedControl)
        let categories = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.categories" } as? UIScrollView)
        let indicator = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.category.indicator" })
        var groups = [[KeyboardSymbolCatalog.Item]]()
        for group in KeyboardSymbolCatalog.emoji.groups {
            groups.append(await withCheckedContinuation { continuation in
                KeyboardEmojiAvailability.load(group) { continuation.resume(returning: $0) }
            })
        }
        groups += KeyboardSymbolCatalog.kaomoji.map(\.items) + KeyboardSymbolCatalog.symbols.map(\.items)
        try await Task.sleep(for: .milliseconds(30)); panel.layoutIfNeeded(); grid.layoutIfNeeded()
        XCTAssertFalse(grid.isPagingEnabled, "Continuous scrolling must not snap to pages")
        XCTAssertEqual(descendants(panel).compactMap { $0 as? UICollectionView }.count, 1)
        XCTAssertEqual(grid.contentSize.height, grid.bounds.height, "No competing vertical scrolling")
        var inserted = [String](); panel.onSelect = { inserted.append($0) }
        func first(_ section: Int) throws -> CGRect {
            try XCTUnwrap(grid.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: section))).frame
        }
        let column = try first(0)
        let columnCells = (grid.collectionViewLayout.layoutAttributesForElements(in:
            CGRect(x: column.minX, y: 0, width: column.width, height: grid.bounds.height)) ?? [])
            .filter { $0.indexPath.section == 0 && abs($0.frame.minX - column.minX) < 0.1 }
        XCTAssertEqual(columnCells.count, 5, "Portrait uses the reference keyboard's five rows")
        XCTAssertLessThanOrEqual(columnCells.map(\.frame.minY).min() ?? 100, 4)
        XCTAssertGreaterThanOrEqual(columnCells.map(\.frame.maxY).max() ?? 0, grid.bounds.height - 4,
            "First and last rows fill the viewport without large top/bottom margins")
        let boundary = try first(1).minX - 6
        let columnStride = try first(0).width + 4
        grid.contentOffset.x = 37.3
        XCTAssertEqual(grid.contentOffset.x, 37.3, accuracy: 0.5, "A drag can stop between columns without snapping")
        grid.contentOffset.x = boundary - columnStride * 0.6
        XCTAssertEqual(indicator.frame.minX, 8 + 56 * 0.4, accuracy: 0.5)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: panel.bounds).image { panel.layer.render(in: $0.cgContext) })
        attachment.name = "emoji-continuous-category-boundary"; attachment.lifetime = .keepAlways; add(attachment)
        let travelBoundary = try first(5).minX - 6
        grid.contentOffset.x = travelBoundary - columnStride * 0.6
        let firstOffset = categories.contentOffset.x
        grid.contentOffset.x = travelBoundary - columnStride * 0.3
        XCTAssertEqual(categories.contentOffset.x - firstOffset, 56 * 0.3, accuracy: 0.5)
        let kaomojiBoundary = try first(10).minX - 6
        grid.contentOffset.x = kaomojiBoundary - columnStride * 0.4
        XCTAssertEqual(modes.selectedSegmentIndex, 1, "Both tab levels follow a cross-mode drag")
        try button("vime.symbols.category.1", in: panel).sendActions(for: .touchUpInside)
        XCTAssertEqual(grid.contentOffset.x, try first(11).minX - 6, accuracy: 0.5)
        // Every supported item must remain reachable and vertically fit the
        // viewport, including long skin-tone groups and short categories.
        for (section, items) in groups.enumerated() {
            XCTAssertEqual(grid.numberOfItems(inSection: section), items.count)
            var visited = Set<Int>()
            for item in stride(from: 0, to: items.count, by: 20) {
                grid.scrollToItem(at: IndexPath(item: item, section: section), at: .left, animated: false); grid.layoutIfNeeded()
                for path in grid.indexPathsForVisibleItems where path.section == section {
                    visited.insert(path.item)
                    let cell = try XCTUnwrap(grid.cellForItem(at: path))
                    XCTAssertGreaterThanOrEqual(cell.frame.minY, 0)
                    XCTAssertLessThanOrEqual(cell.frame.maxY, grid.bounds.height)
                    let label = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UILabel }.first)
                    XCTAssertEqual(cell.accessibilityIdentifier, "vime.symbol.\(items[path.item].text)")
                    if section >= 10 { XCTAssertEqual(label.text, items[path.item].text) }
                    if section < 10 { XCTAssertEqual(cell.contentView.backgroundColor, .clear) }
                }
                XCTAssertLessThan(grid.visibleCells.count, 90, "Only viewport cells are realized, including the denser grid")
            }
            XCTAssertEqual(visited.count, items.count, "Continuous layout cannot omit items")
        }
        XCTAssertTrue(inserted.isEmpty)
        panel.selectMode(.emoji)
        grid.scrollToItem(at: IndexPath(item: 80, section: 0), at: .left, animated: false); grid.layoutIfNeeded()
        panel.frame.size = CGSize(width: 860, height: 250); panel.compact = true; panel.layoutIfNeeded(); grid.layoutIfNeeded()
        XCTAssertTrue(grid.indexPathsForVisibleItems.contains(IndexPath(item: 80, section: 0)), "Rotation keeps the visible item")
        panel.selectMode(.kaomoji); panel.layoutIfNeeded()
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: 10))
        XCTAssertEqual(inserted, ["(^_^)"])
    }

    func testEmojiPanelReusesWarmImagesUntilPressureOrAppearanceChange() throws {
        let (keyboard, _, _, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true; KeyboardEmojiImages.clear() }
        let image = try XCTUnwrap(KeyboardEmojiImages.displayImage("😀", scale: 3))
        let generation = KeyboardEmojiImages.cacheGeneration
        for _ in 0..<3 {
            try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "表情" } as? UIButton)
                .sendActions(for: .touchUpInside)
            let panel = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardSymbolPanel }.first)
            XCTAssertFalse(panel.isHidden)
            XCTAssertTrue(KeyboardEmojiImages.cachedImage("😀", scale: 3) === image)
            try button("vime.symbols.close", in: panel).sendActions(for: .touchUpInside)
            XCTAssertTrue(panel.isHidden)
            XCTAssertEqual(KeyboardEmojiImages.cacheGeneration, generation)
            XCTAssertTrue(KeyboardEmojiImages.cachedImage("😀", scale: 3) === image)
        }
        XCTAssertLessThanOrEqual(KeyboardEmojiImages.retainedBytes, KeyboardEmojiImages.byteLimit)
        keyboard.handleMemoryPressure()
        XCTAssertNil(KeyboardEmojiImages.cachedImage("😀", scale: 3))
        XCTAssertEqual(KeyboardEmojiImages.retainedBytes, 0)
        try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "表情" } as? UIButton)
            .sendActions(for: .touchUpInside)
        _ = try XCTUnwrap(KeyboardEmojiImages.displayImage("😀", scale: 3))
        let oldSkin = KeyboardPalette.skin
        defer { KeyboardPalette.skin = oldSkin }
        var document = KeyboardSkinDocument(); document.palette.text = "#F01234"
        KeyboardPalette.skin = KeyboardSkinAppearance(document)
        try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardSymbolPanel }.first).applyTheme()
        XCTAssertNil(KeyboardEmojiImages.cachedImage("😀", scale: 3))
    }

    func testEmbeddedEmojiBitmapsCoverSupportedCatalog() async throws {
        defer { KeyboardEmojiImages.clear() }
        for group in KeyboardSymbolCatalog.emoji.groups {
            let items = await withCheckedContinuation { continuation in
                KeyboardEmojiAvailability.load(group) { continuation.resume(returning: $0) }
            }
            for item in items {
                let prepared = await KeyboardEmojiImages.image(item.text, scale: 3)
                autoreleasepool {
                    guard let image = prepared?.cgImage,
                          let data = image.dataProvider?.data else { return XCTFail("Embedded bitmap: \(item.text)") }
                    XCTAssertEqual(image.bitsPerPixel, 32)
                    let bytes = data as Data
                    let alphaFirst = image.alphaInfo == .first || image.alphaInfo == .premultipliedFirst
                    let littleEndian = image.bitmapInfo.contains(.byteOrder32Little)
                    let alpha = alphaFirst == littleEndian ? 3 : 0
                    XCTAssertTrue(bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                        stride(from: alpha, to: buffer.count, by: 4).contains { buffer[$0] != 0 }
                    }, "The complete supported catalog contains no empty glyph: \(item.text)")
                    XCTAssertLessThanOrEqual(KeyboardEmojiImages.retainedBytes, KeyboardEmojiImages.byteLimit)
                }
            }
        }
    }

    func testEmojiRequestsCoalesceCancelAndDoNotRefillClearedCache() async throws {
        KeyboardEmojiImages.clear()
        defer { KeyboardEmojiImages.clear() }
        var cancelledCalls = 0
        let cancelled = KeyboardEmojiImages.request("👩🏻‍❤️‍👨🏿", scale: 3) { _ in cancelledCalls += 1 }
        let ready = expectation(description: "Another subscriber receives the shared decode")
        var delivered: UIImage?
        KeyboardEmojiImages.request("👩🏻‍❤️‍👨🏿", scale: 3) { image in delivered = image; ready.fulfill() }
        KeyboardEmojiImages.cancel(cancelled)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNotNil(delivered)
        XCTAssertTrue(delivered === KeyboardEmojiImages.cachedImage("👩🏻‍❤️‍👨🏿", scale: 3))
        XCTAssertEqual(cancelledCalls, 0)
        KeyboardEmojiImages.clear()
        // No run-loop yield until cancellation: includes a running job and
        // queued speculative jobs from a cold rapid change of direction.
        for item in KeyboardSymbolCatalog.emoji.groups[0].items.prefix(100) {
            KeyboardEmojiImages.request(item.text, scale: 3)
        }
        XCTAssertLessThanOrEqual(KeyboardEmojiImages.pendingCount, KeyboardEmojiImages.prefetchLimit)
        KeyboardEmojiImages.clear()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(KeyboardEmojiImages.pendingCount, 0)
        XCTAssertEqual(KeyboardEmojiImages.retainedBytes, 0, "Old work cannot refill cleared cache")
        let recovered = await KeyboardEmojiImages.image("😀", scale: 3)
        XCTAssertNotNil(recovered, "A new generation recovers normally")
    }

    func testRapidEmojiReuseKeepsImagesMatchedToCurrentItems() async throws {
        KeyboardEmojiImages.clear()
        let panel = KeyboardSymbolPanel(frame: CGRect(x: 0, y: 0, width: 440, height: 350))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController?.view.addSubview(panel)
        defer { window.isHidden = true; KeyboardEmojiImages.clear() }
        for group in KeyboardSymbolCatalog.emoji.groups {
            _ = await withCheckedContinuation { continuation in
                KeyboardEmojiAvailability.load(group) { continuation.resume(returning: $0) }
            }
        }
        panel.layoutIfNeeded()
        let grid = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        for index in [1, 6, 2, 8, 3, 9, 0] {
            try button("vime.symbols.category.\(index)", in: panel).sendActions(for: .touchUpInside)
            panel.layoutIfNeeded(); grid.layoutIfNeeded()
        }
        // Clearing in-flight work must not strand cell request handles or
        // turn cancelled jobs into native-glyph fallbacks on reopening.
        panel.applyTheme(); KeyboardEmojiImages.clear()
        panel.isHidden = true; panel.isHidden = false
        let deadline = Date().addingTimeInterval(3)
        while grid.visibleCells.contains(where: { descendants($0).compactMap { $0 as? UIImageView }.first?.image == nil }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        for cell in grid.visibleCells {
            let identifier = try XCTUnwrap(cell.accessibilityIdentifier)
            let text = String(identifier.dropFirst("vime.symbol.".count))
            let image = try XCTUnwrap(descendants(cell).compactMap { $0 as? UIImageView }.first?.image)
            let prepared = await KeyboardEmojiImages.image(text, scale: window.screen.scale)
            let expected = try XCTUnwrap(prepared)
            XCTAssertEqual(image.cgImage?.dataProvider?.data as Data?, expected.cgImage?.dataProvider?.data as Data?, "A reused cell never receives its previous emoji")
        }
    }

    func testColdEmojiCategoryJumpsAreReadyInTheDisplayingTurn() async throws {
        let panel = KeyboardSymbolPanel(frame: CGRect(x: 0, y: 0, width: 440, height: 350))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController?.view.addSubview(panel)
        defer { window.isHidden = true; KeyboardEmojiImages.clear() }
        for group in KeyboardSymbolCatalog.emoji.groups {
            _ = await withCheckedContinuation { continuation in
                KeyboardEmojiAvailability.load(group) { continuation.resume(returning: $0) }
            }
        }
        panel.layoutIfNeeded()
        let grid = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        // No sleeps or main-queue drain between movement and inspection. Jump
        // beyond the lookahead, then reverse immediately with a cold cache.
        for index in [6, 1, 8, 2, 9, 0] {
            KeyboardEmojiImages.clear()
            try button("vime.symbols.category.\(index)", in: panel).sendActions(for: .touchUpInside)
            panel.layoutIfNeeded(); grid.layoutIfNeeded()
            let paths = grid.indexPathsForVisibleItems.filter { $0.section < 10 }
            XCTAssertFalse(paths.isEmpty)
            for path in paths {
                let cell = try XCTUnwrap(grid.cellForItem(at: path))
                let image = try XCTUnwrap(descendants(cell).compactMap { $0 as? UIImageView }.first)
                XCTAssertNotNil(image.image, "Ready before display, without asynchronous delivery: \(path)")
                XCTAssertTrue(try XCTUnwrap(descendants(cell).compactMap { $0 as? UILabel }.first).isHidden)
            }
        }
    }

    func testEmojiDecoderContinuesWhileMainThreadIsBusyWithBoundedDeliveries() async throws {
        _ = await KeyboardEmojiImages.image("😀", scale: 3)
        KeyboardEmojiImages.clear()
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false); KeyboardEmojiImages.clear() }
        for item in KeyboardSymbolCatalog.emoji.groups[0].items.prefix(80) {
            KeyboardEmojiImages.request(item.text, scale: 3)
        }
        // Simulate gesture/layout work without servicing main-thread delivery.
        // The former implementation could prepare only one image in this gap.
        func busyMainThread() { Thread.sleep(forTimeInterval: 0.05) }
        busyMainThread()
        let decoded = KeyboardPerformance.takeWindowReport()["emojiDecode"]?["windowCount"] ?? 0
        XCTAssertGreaterThan(decoded, 4, "Background throughput must not depend on a main-thread round trip per glyph")
        XCTAssertLessThanOrEqual(decoded, 24, "Completed images awaiting delivery have a hard bound")
        let alreadyCached = KeyboardSymbolCatalog.emoji.groups[0].items.prefix(80).filter {
            KeyboardEmojiImages.cachedImage($0.text, scale: 3) != nil
        }.count
        XCTAssertGreaterThan(alreadyCached, 4, "Prepared pixels are readable before any main-thread delivery")
        KeyboardEmojiImages.clear()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(KeyboardEmojiImages.pendingCount, 0)
        XCTAssertEqual(KeyboardEmojiImages.retainedBytes, 0)
    }

    func testVisibleEmojiBypassesSaturatedPreparationQueue() throws {
        KeyboardEmojiImages.clear()
        defer { KeyboardEmojiImages.clear() }
        for item in KeyboardSymbolCatalog.emoji.groups.flatMap(\.items).prefix(KeyboardEmojiImages.pendingLimit) {
            KeyboardEmojiImages.request(item.text, scale: 3, priority: .prepared)
        }
        XCTAssertEqual(KeyboardEmojiImages.pendingCount, KeyboardEmojiImages.pendingLimit)
        let text = "👩🏽‍💻"
        XCTAssertNotNil(KeyboardEmojiImages.displayImage(text, scale: 3), "A full speculative queue cannot leave a visible cell blank")
        XCTAssertNotNil(KeyboardEmojiImages.cachedImage(text, scale: 3))
        XCTAssertLessThanOrEqual(KeyboardEmojiImages.retainedBytes, KeyboardEmojiImages.byteLimit)
    }

    func testEmojiBitmapDecoderChecksDimensionsStreamsAndAlpha() throws {
        func fixture(_ alpha: UInt8 = 255, filter: UInt8 = 0) -> Data {
            let raw: [UInt8] = [alpha, filter, 64, 0, 0]
            var destination = [UInt8](repeating: 0, count: 1024)
            let count = raw.withUnsafeBufferPointer { source in
                destination.withUnsafeMutableBufferPointer {
                    compression_encode_buffer($0.baseAddress!, $0.count, source.baseAddress!, source.count, nil, COMPRESSION_LZFSE)
                }
            }
            var header = Data([0x65, 0x6d, 0x6a, 0x31, 0, 1, 1, 0xa1, 1, 0, 1, 0, 0, 0, 0, 0])
            header.append(contentsOf: destination.prefix(count)); return header
        }
        let valid = fixture()
        let image = try XCTUnwrap(EmojiBitmapDecoder.decode(valid))
        XCTAssertEqual(image.width, 1); XCTAssertEqual(image.height, 1)
        XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data, Data([32, 32, 32, 255]))
        let transparent = try XCTUnwrap(EmojiBitmapDecoder.decode(fixture(0)))
        XCTAssertEqual((try XCTUnwrap(transparent.dataProvider?.data) as Data).last, 0)
        XCTAssertNil(EmojiBitmapDecoder.decode(fixture(filter: 5)))
        for length in 0..<valid.count { XCTAssertNil(EmojiBitmapDecoder.decode(Data(valid.prefix(length)))) }
        var oversized = valid; oversized[8] = 1; oversized[9] = 2
        XCTAssertNil(EmojiBitmapDecoder.decode(oversized))
        var unknown = valid; unknown[4] = 2
        XCTAssertNil(EmojiBitmapDecoder.decode(unknown))
    }

    func testEmojiShapingAndLatestCategoryWins() async throws {
        for value in ["😀", "👩🏽‍💻", "🇯🇵", "1️⃣", "👨‍👩‍👧‍👦", "🏴", "❤️", "👍🏿", "🫱🏻‍🫲🏼", "👩🏻‍❤️‍👨🏿", "👩🏻‍🤝‍👨🏼"] {
            XCTAssertTrue(KeyboardEmojiAvailability.supports(value), value)
        }
        XCTAssertFalse(KeyboardEmojiAvailability.supports("a"))
        XCTAssertFalse(KeyboardEmojiAvailability.supports("\u{10FFFF}"))
        XCTAssertFalse(KeyboardEmojiAvailability.supports("😀😀"), "A decomposed multi-glyph sequence is not one supported emoji")
        let panel = KeyboardSymbolPanel(frame: CGRect(x: 0, y: 0, width: 440, height: 350))
        let grid = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        try button("vime.symbols.category.1", in: panel).sendActions(for: .touchUpInside)
        panel.selectMode(.symbols)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(grid.numberOfItems(inSection: 18), KeyboardSymbolCatalog.symbols[0].items.count,
            "An old emoji availability request must never overwrite the symbol category")
        panel.selectMode(.emoji)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(grid.numberOfItems(inSection: 0), 100)
    }

    func testEmojiCellsPreserveColorAndCompositeGlyphs() async throws {
        let samples = ["😀", "🫡", "👩🏽‍💻", "🇯🇵", "1️⃣", "❤️", "👍🏿", "🫱🏻‍🫲🏼", "👩🏻‍❤️‍👨🏿", "👩🏻‍🤝‍👨🏼", "👨‍👩‍👧‍👦", "🚶‍➡️", "🧑🏽‍🦯‍➡️", "♀️", "♂️", "⚕️"]
        let panel = KeyboardSymbolPanel(frame: CGRect(x: 0, y: 0, width: 440, height: 350))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController?.view.addSubview(panel)
        defer { window.isHidden = true }
        let grid = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 29, nil)
        func reference(_ text: String) -> UIImage {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, .foregroundColor: KeyboardPalette.text]))
            return UIGraphicsImageRenderer(size: CGSize(width: 36, height: 36)).image { renderer in
                let context = renderer.cgContext, ink = CTLineGetImageBounds(line, renderer.cgContext)
                guard !ink.isEmpty else { return }
                let scale = min(1, min(34 / ink.width, 34 / ink.height))
                context.translateBy(x: 18, y: 18); context.scaleBy(x: scale, y: -scale)
                context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
                CTLineDraw(line, context)
            }
        }
        func pixels(_ image: UIImage) throws -> [UInt8] {
            let image = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        // UIKit centers a typographic line; the reference centers ink. Compare
        // the actual colored shape after removing that intentional translation.
        func normalizedInk(_ image: UIImage) throws -> UIImage {
            let cg = try XCTUnwrap(image.cgImage), bytes = try pixels(image)
            var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
            for y in 0..<cg.height {
                for x in 0..<cg.width where bytes[(y * cg.width + x) * 4 + 3] > 8 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            XCTAssertGreaterThan(maxX, minX, "Emoji must contain visible ink")
            XCTAssertGreaterThan(minX, 0, "Keep the complete glyph inside the cell")
            XCTAssertGreaterThan(minY, 0)
            XCTAssertLessThan(maxX, cg.width - 1)
            XCTAssertLessThan(maxY, cg.height - 1)
            // The bitmap CGContext above has a bottom-left origin; CGImage's
            // cropping coordinates start at the top left.
            let cropped = try XCTUnwrap(cg.cropping(to: CGRect(x: minX, y: cg.height - maxY - 1,
                width: maxX - minX + 1, height: maxY - minY + 1)))
            let factor = min(32 / CGFloat(cropped.width), 32 / CGFloat(cropped.height))
            let size = CGSize(width: CGFloat(cropped.width) * factor, height: CGFloat(cropped.height) * factor)
            return UIGraphicsImageRenderer(size: CGSize(width: 36, height: 36)).image { _ in
                UIImage(cgImage: cropped).draw(in: CGRect(x: (36 - size.width) / 2, y: (36 - size.height) / 2,
                    width: size.width, height: size.height))
            }
        }
        var images = [UIImage]()
        for sample in samples {
            let groupIndex = try XCTUnwrap(KeyboardSymbolCatalog.emoji.groups.firstIndex { $0.items.contains { $0.text == sample } })
            let items = await withCheckedContinuation { continuation in
                KeyboardEmojiAvailability.load(KeyboardSymbolCatalog.emoji.groups[groupIndex]) { continuation.resume(returning: $0) }
            }
            try button("vime.symbols.category.\(groupIndex)", in: panel).sendActions(for: .touchUpInside)
            panel.layoutIfNeeded()
            let path = IndexPath(item: try XCTUnwrap(items.firstIndex { $0.text == sample }), section: groupIndex)
            grid.scrollToItem(at: path, at: .left, animated: false); grid.layoutIfNeeded()
            let deadline = Date().addingTimeInterval(2)
            while grid.cellForItem(at: path)?.contentView.subviews.compactMap({ $0 as? UIImageView }).first?.image == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let cell = try XCTUnwrap(grid.cellForItem(at: path))
            XCTAssertNotNil(cell.contentView.subviews.compactMap { $0 as? UILabel }.first)
            XCTAssertEqual(cell.accessibilityIdentifier, "vime.symbol.\(sample)")
            var selected: String?
            panel.onSelect = { selected = $0 }; panel.collectionView(grid, didSelectItemAt: path)
            XCTAssertEqual(selected, sample, "Insert the complete skin-tone/ZWJ sequence")
            let expected = try normalizedInk(reference(sample))
            let decoded = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIImageView }.first?.image, sample)
            let actual = try normalizedInk(decoded)
            let a = try pixels(actual), b = try pixels(expected)
            let opaque = stride(from: 3, to: a.count, by: 4).filter { a[$0] > 32 }.count
            XCTAssertGreaterThan(opaque, 100, "Missing emoji ink: \(sample)")
            let error = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            print("VIME_EMOJI_RASTER sample=\(sample) mean_pixel_error=\(error) ink_pixels=\(opaque)")
            // Native text and bitmap drawing can use different font strikes
            // and antialiasing. Verify coverage and color rather than exact
            // pixels; the gallery also exposes misplaced composite overlays.
            let referenceOpaque = stride(from: 3, to: b.count, by: 4).filter { b[$0] > 32 }.count
            let coverage = Double(opaque) / Double(referenceOpaque)
            XCTAssertGreaterThan(coverage, 0.8, "A composite glyph must not lose an overlay: \(sample)")
            XCTAssertLessThan(coverage, 1.2)
            func meanColor(_ bytes: [UInt8], channel: Int) -> Double {
                let pixels = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 3] > 32 }
                return pixels.reduce(0.0) { $0 + Double(bytes[$1 + channel]) } / Double(pixels.count)
            }
            for channel in 0..<3 {
                XCTAssertLessThan(abs(meanColor(a, channel: channel) - meanColor(b, channel: channel)), 12,
                    "Preserve emoji colors, including mixed skin tones: \(sample)")
            }
            images += [expected, actual]
        }
        let gallery = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(samples.count) * 72, height: 144)).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: samples.count * 72, height: 144))
            for (index, image) in images.enumerated() {
                image.draw(in: CGRect(x: (index / 2) * 72 + 18, y: (index % 2) * 72 + 18, width: 36, height: 36))
            }
        }
        let attachment = XCTAttachment(image: gallery)
        attachment.name = "emoji-reference-top-current-bottom"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testCompleteEmojiCatalogCanLoadEveryCategory() async throws {
        var rows: [[String: Any]] = []
        for group in KeyboardSymbolCatalog.emoji.groups {
            let started = ProcessInfo.processInfo.systemUptime
            let available = await withCheckedContinuation { continuation in
                KeyboardEmojiAvailability.load(group) { continuation.resume(returning: $0) }
            }
            XCTAssertFalse(available.isEmpty, group.name)
            XCTAssertEqual(Set(available.map(\.text)).count, available.count)
            let supported = Set(available.map(\.text))
            rows.append(["group": group.name, "catalogCount": group.items.count,
                "availableCount": available.count,
                "backgroundLoadMs": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                "unavailable": group.items.filter { !supported.contains($0.text) }.map(\.name)])
        }
        let report: [String: Any] = ["os": UIDevice.current.systemVersion,
            "version": KeyboardSymbolCatalog.emoji.version, "groups": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "emoji-native-coverage"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSoftWrappedTextMovesVerticallyWithoutNewlines() async throws {
        let (keyboard, surface, text, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let value = String(repeating: "这是自动折行的日语与Emoji👩🏽‍💻文字。", count: 6)
        text.frame.size.width = 180; text.font = .systemFont(ofSize: 17)
        let start = value.prefix(45).utf16.count
        text.text = value; text.selectedRange = NSRange(location: start, length: 0)
        text.layoutManager.ensureLayout(for: text.textContainer)
        let space = try point("vime.key.space", in: surface)
        surface.beginPress(id: 1, at: space)
        try await Task.sleep(for: .milliseconds(400))
        let up = CGPoint(x: space.x, y: space.y - 24 * surface.scale)
        surface.movePress(id: 1, to: up); surface.endPress(id: 1, at: up)
        XCTAssertLessThan(text.selectedRange.location, start)
        XCTAssertEqual(text.text, value)

        let layout = KeyboardProxyCursorLayout()
        let ns = value as NSString
        layout.beginGesture(before: ns.substring(to: start), after: ns.substring(from: start), width: 180)
        let offset = layout.moveInGesture(horizontal: 0, vertical: -1)
        XCTAssertLessThan(offset, 0, "A soft wrap must not resolve to the old zero offset")
        let moved = start + offset
        let back = layout.moveInGesture(horizontal: 0, vertical: 1)
        XCTAssertGreaterThan(back, 0)
        XCTAssertEqual(moved + back, start, "Keep the horizontal column across wrapped lines")
        // A host may expose no after-context, even after moving up. Preserve
        // this gesture's original text so downward movement can retrace it.
        layout.beginGesture(before: ns.substring(to: start), after: "", width: 180)
        let gestureUp = layout.moveInGesture(horizontal: 0, vertical: -1)
        XCTAssertLessThan(gestureUp, 0)
        let gestureDown = layout.moveInGesture(horizontal: 0, vertical: 1)
        XCTAssertEqual(gestureUp + gestureDown, 0)
    }

    func testHeightDragAndSharedPreferenceReachExtension() throws {
        let preferences = KeyboardPreferences()
        let old = preferences.heightFactor
        defer { preferences.heightFactor = old }
        let adjustment = KeyboardHeightAdjustmentView(frame: CGRect(x: 0, y: 0, width: 440, height: 540))
        adjustment.factor = 1; adjustment.layoutIfNeeded()
        let baseline = adjustment.keyboard.preferredHeight(for: 440)
        adjustment.beginAdjustment(); adjustment.adjust(translationY: -45); adjustment.layoutIfNeeded()
        XCTAssertGreaterThan(adjustment.keyboard.preferredHeight(for: 440), baseline)
        adjustment.keyboard.layoutIfNeeded()
        let surface = try XCTUnwrap(descendants(adjustment.keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        let q = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.q" })
        XCTAssertNotNil(surface.resolvedKey(at: CGPoint(x: q.cell.maxX, y: q.body.midY)))
        attachAppearance(adjustment, name: "height-drag-preview")
        preferences.heightFactor = Double(adjustment.factor)
        XCTAssertNotNil(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup))
        let group = try XCTUnwrap(UserDefaults(suiteName: KeyboardPreferences.appGroup))
        XCTAssertEqual(group.double(forKey: "vime.heightFactor"), Double(adjustment.factor), accuracy: 0.0001)
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded(); controller.viewWillAppear(false)
        let extensionKeyboard = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardView }.first)
        XCTAssertEqual(extensionKeyboard.heightFactor, adjustment.factor, accuracy: 0.0001)
        controller.viewWillDisappear(false)
        adjustment.beginAdjustment(); adjustment.adjust(translationY: 10000)
        XCTAssertEqual(Double(adjustment.factor), KeyboardPreferences.heightRange.lowerBound)
    }

    func testThemeChoicePersistsAndAppliesToExistingKeys() throws {
        let old = KeyboardPreferences().theme
        defer { KeyboardPreferences().theme = old; KeyboardPalette.theme = old }
        let (keyboard, surface, _, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let settings = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "键盘设置" } as? UIButton)
        settings.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        XCTAssertNotNil(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.setting.numbers" })
        for id in ["theme", "ranking", "suggestions", "prolonged", "previews"] {
            XCTAssertNil(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.setting.\(id)" })
        }
        // The containing app writes the same preferences; existing keys should
        // adopt the new theme on keyboard re-entry.
        KeyboardPreferences().theme = .midnight
        keyboard.reloadPreferences()
        XCTAssertEqual(KeyboardPreferences().theme, .midnight)
        XCTAssertEqual(keyboard.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(surface.regions.first?.key.titleColor(for: .normal), .white)
        try button("vime.panel.close", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertFalse(surface.isHidden)
        attachAppearance(keyboard, name: "midnight-keyboard")
    }

    func testDoubleTapShiftLocksCapitalsUntilTappedAgain() throws {
        let (keyboard, _, text, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true }
        func tap(_ id: String) throws { try button(id, in: keyboard).sendActions(for: .touchUpInside) }
        try tap("vime.key.language")
        try tap("vime.key.shift"); try tap("vime.key.a"); try tap("vime.key.b")
        XCTAssertEqual(text.text, "Ab", "A single shift capitalizes one letter")
        try tap("vime.key.shift")
        XCTAssertTrue(keyboard.shifted && !keyboard.capsLocked, "A letter between two quick Shift taps does not lock")
        try tap("vime.key.shift")
        XCTAssertTrue(keyboard.capsLocked)
        XCTAssertEqual(try button("vime.key.shift", in: keyboard).image(for: .normal), UIImage(systemName: "capslock.fill"))
        try tap("vime.key.c"); try tap("vime.key.d")
        XCTAssertEqual(text.text, "AbCD", "Caps lock keeps capitals after each letter")
        try tap("vime.key.shift"); try tap("vime.key.e")
        XCTAssertFalse(keyboard.capsLocked)
        XCTAssertEqual(text.text, "AbCDe")

        // The second release may come well after the first, as in a relaxed
        // double tap; two separate taps still just toggle.
        keyboard.lastShiftTap = 0
        keyboard.shift(at: 100); keyboard.shift(at: 100.4)
        XCTAssertTrue(keyboard.capsLocked)
        keyboard.shift(at: 101)
        XCTAssertFalse(keyboard.capsLocked || keyboard.shifted)
        keyboard.shift(at: 200); keyboard.shift(at: 200.6)
        XCTAssertFalse(keyboard.capsLocked || keyboard.shifted)
    }

    func testEnglishAutoCapitalizationAndDoubleSpacePeriodAreOptIn() throws {
        let (keyboard, _, text, window) = try fixture()
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let preferences = keyboard.preferences
        let old = (preferences.autoCapitalize, preferences.doubleSpacePeriod)
        defer { preferences.autoCapitalize = old.0; preferences.doubleSpacePeriod = old.1; keyboard.reloadPreferences() }
        keyboard.leftContextProvider = { text.text }
        func tap(_ id: String) throws { try button(id, in: keyboard).sendActions(for: .touchUpInside) }
        preferences.autoCapitalize = false; preferences.doubleSpacePeriod = false
        keyboard.reloadPreferences()
        try tap("vime.key.language")
        try tap("vime.key.a")
        keyboard.space(at: 10); keyboard.space(at: 10.2)
        XCTAssertEqual(text.text, "a  ", "Both options stay off by default")

        text.text = ""
        preferences.autoCapitalize = true; preferences.doubleSpacePeriod = true
        keyboard.reloadPreferences()
        keyboard.hostContextDidChange()
        XCTAssertTrue(keyboard.shifted, "An empty field starts a sentence")
        try tap("vime.key.h"); try tap("vime.key.i")
        keyboard.space(at: 20); keyboard.space(at: 20.3)
        XCTAssertEqual(text.text, "Hi. ")
        XCTAssertTrue(keyboard.shifted, "The period starts a new sentence")
        try tap("vime.key.o"); try tap("vime.key.k")
        keyboard.space(at: 30); keyboard.space(at: 31)
        XCTAssertEqual(text.text, "Hi. Ok  ", "Slow spaces stay spaces")

        keyboard.autocapitalizationType = .none
        text.text = ""; keyboard.hostContextDidChange()
        XCTAssertFalse(keyboard.shifted, "Fields without capitalization stay lowercase")
        XCTAssertTrue(KeyboardView.capitalizes(after: "one ", type: .words))
        XCTAssertFalse(KeyboardView.capitalizes(after: "one", type: .words))
        XCTAssertTrue(KeyboardView.capitalizes(after: "Done!\n", type: .sentences))
        XCTAssertFalse(KeyboardView.capitalizes(after: "e.g, ", type: .sentences))
    }

    func testJapaneseSpaceWidthFollowsTheSettingAndShiftPicksTheOther() throws {
        let session = KeyboardSession()
        let (keyboard, _, text, window) = try fixture(session: session)
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let preferences = keyboard.preferences
        let old = preferences.fullWidthSpace
        defer { preferences.fullWidthSpace = old; keyboard.reloadPreferences() }
        func tap(_ id: String) throws { try button(id, in: keyboard).sendActions(for: .touchUpInside) }
        preferences.fullWidthSpace = false; keyboard.reloadPreferences()
        keyboard.space(at: 10)
        XCTAssertEqual(text.text, " ", "Half width stays the default")
        keyboard.shift(at: 15); keyboard.space(at: 20)
        XCTAssertEqual(text.text, " \u{3000}")
        XCTAssertFalse(keyboard.shifted, "Shift applies to one space")
        preferences.fullWidthSpace = true; keyboard.reloadPreferences()
        keyboard.space(at: 30)
        keyboard.shift(at: 35); keyboard.space(at: 40)
        XCTAssertEqual(text.text, " \u{3000}\u{3000} ")
        try tap("vime.key.a"); keyboard.space(at: 50)
        XCTAssertTrue(session.isComposing, "Space still converts a reading")
        _ = session.confirmAll(); text.text = ""
        try tap("vime.key.language"); keyboard.space(at: 60)
        XCTAssertEqual(text.text, " ", "English keeps a half-width space")
    }

    func testTextReplacementsReplaceLatinWordsAndFeedKanaReadings() throws {
        let (keyboard, _, text, window) = try fixture()
        let preferences = keyboard.preferences
        let old = (preferences.textReplacements, preferences.englishCompletion)
        defer {
            preferences.textReplacements = old.0; preferences.englishCompletion = old.1
            keyboard.reloadPreferences(); JapaneseSystemShortcuts.update([])
            keyboard.stopInteractions(); window.isHidden = true
        }
        keyboard.leftContextProvider = { text.text }
        keyboard.learningContextProvider = { KeyboardLearningContext(document: "fixture", before: text.text, after: "") }
        func tap(_ id: String) throws { try button(id, in: keyboard).sendActions(for: .touchUpInside) }
        preferences.textReplacements = true; preferences.englishCompletion = false; keyboard.reloadPreferences()
        keyboard.setTextReplacements([("omw", "On my way!"), ("おつ", "お疲れさまです")])
        XCTAssertEqual(JapaneseSystemShortcuts.entries.map(\.word), ["お疲れさまです"], "Only kana shortcuts join conversion")
        try tap("vime.key.language")
        try tap("vime.key.shift")
        for key in "omw" { try tap("vime.key.\(key)") }
        XCTAssertEqual(text.text, "Omw")
        let item = try XCTUnwrap(keyboard.quickCandidateItems().first)
        XCTAssertEqual(item.title, "On my way!", "Shortcuts match regardless of case")
        keyboard.selectQuickCandidate(item)
        XCTAssertEqual(text.text, "On my way! ")
        XCTAssertTrue(keyboard.quickCandidateItems().isEmpty)

        preferences.textReplacements = false; keyboard.reloadPreferences()
        XCTAssertTrue(JapaneseSystemShortcuts.entries.isEmpty)
        for key in "omw" { try tap("vime.key.\(key)") }
        XCTAssertTrue(keyboard.quickCandidateItems().isEmpty, "The setting turns replacements off")
    }

    func testEnglishCompletionsKeepTheWordsCaseAndCanBeTurnedOff() throws {
        let (keyboard, _, text, window) = try fixture()
        let preferences = keyboard.preferences
        let old = preferences.englishCompletion
        defer { preferences.englishCompletion = old; keyboard.reloadPreferences(); keyboard.stopInteractions(); window.isHidden = true }
        keyboard.leftContextProvider = { text.text }
        keyboard.learningContextProvider = { KeyboardLearningContext(document: "fixture", before: text.text, after: "") }
        func tap(_ id: String) throws { try button(id, in: keyboard).sendActions(for: .touchUpInside) }
        preferences.englishCompletion = true; keyboard.reloadPreferences()
        try tap("vime.key.language")
        try tap("vime.key.shift")
        for key in "hel" { try tap("vime.key.\(key)") }
        let items = keyboard.quickCandidateItems()
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.title.hasPrefix("Hel") && $0.title != "Hel" }, "\(items.map(\.title))")
        keyboard.selectQuickCandidate(items[0])
        XCTAssertEqual(text.text, items[0].title + " ")
        XCTAssertTrue(keyboard.quickCandidateItems().isEmpty, "A finished word has nothing to complete")
        XCTAssertTrue(keyboard.completions(for: "HEL").allSatisfy { $0 == $0.uppercased() })
        XCTAssertTrue(keyboard.completions(for: "h").isEmpty, "One letter is too little to guess from")

        preferences.englishCompletion = false; keyboard.reloadPreferences()
        for key in "hel" { try tap("vime.key.\(key)") }
        XCTAssertTrue(keyboard.quickCandidateItems().isEmpty)
    }

    func testBackspaceUndoSettingAppliesWhenTheKeyboardStarts() throws {
        let preferences = KeyboardPreferences()
        let old = preferences.undoConversionOnBackspace
        defer { preferences.undoConversionOnBackspace = old }
        preferences.undoConversionOnBackspace = true
        preferences.undoConversionOnBackspace = false
        let session = KeyboardSession()
        let (keyboard, _, text, window) = try fixture(session: session)
        defer { keyboard.stopInteractions(); window.isHidden = true }
        XCTAssertFalse(session.undoesCommitOnBackspace, "A keyboard started with the option off never undoes a conversion")
        keyboard.reloadPreferences()
        XCTAssertFalse(session.undoesCommitOnBackspace)
        preferences.undoConversionOnBackspace = true
        keyboard.reloadPreferences()
        XCTAssertTrue(session.undoesCommitOnBackspace)

        preferences.undoConversionOnBackspace = false
        keyboard.reloadPreferences()

        // After a conversion the next-word row starts with a chip that returns it to its reading.
        keyboard.apply(session.type("nihongo"))
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.fullConsumption && $0.text != "にほんご" })
        let converted = session.candidateSnapshots[index].text
        keyboard.apply(session.choose(index))
        XCTAssertEqual(text.text, converted)
        let chip = try button("vime.reconvertCommit", in: keyboard)
        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(chip.configuration?.title, "にほんご")
        XCTAssertEqual(chip.frame.minX, 0, "The chip leads the row")
        XCTAssertTrue(keyboard.stripButtons.allSatisfy { $0.frame.minX >= chip.frame.maxX })
        chip.sendActions(for: .touchUpInside)
        XCTAssertEqual(text.text, "にほんご", "The conversion is replaced by its marked reading")
        XCTAssertNotNil(text.markedTextRange)
        XCTAssertEqual(session.preedit, "にほんご")
        XCTAssertTrue(chip.isHidden, "The chip leaves while the reading is composed again")
    }

    func testOneHandedModeNarrowsKeysTowardOneSideAndRestores() throws {
        let (keyboard, surface, _, window) = try fixture()
        let preferences = keyboard.preferences
        let old = preferences.oneHanded
        defer { preferences.oneHanded = old; keyboard.reloadPreferences(); keyboard.stopInteractions(); window.isHidden = true }
        preferences.oneHanded = .off; keyboard.reloadPreferences(); keyboard.layoutIfNeeded()
        let fullQ = try button("vime.key.q", in: keyboard).frame, fullP = try button("vime.key.p", in: keyboard).frame
        XCTAssertTrue(keyboard.oneHandedButton.isHidden)

        preferences.oneHanded = .right; keyboard.reloadPreferences(); keyboard.layoutIfNeeded()
        let q = try button("vime.key.q", in: keyboard).frame, p = try button("vime.key.p", in: keyboard).frame
        let restore = keyboard.oneHandedButton
        XCTAssertFalse(restore.isHidden)
        XCTAssertLessThan(p.width, fullP.width)
        XCTAssertGreaterThan(q.minX, restore.frame.maxX, "Keys sit beside the restore strip")
        XCTAssertLessThan(p.maxX, keyboard.bounds.width)
        XCTAssertTrue(surface.regions.allSatisfy { $0.cell.minX >= restore.frame.maxX - 0.5 }, "No key claims the strip")

        preferences.oneHanded = .left; keyboard.reloadPreferences(); keyboard.layoutIfNeeded()
        XCTAssertEqual(try button("vime.key.q", in: keyboard).frame.minX, fullQ.minX * (keyboard.oneHandedKeyArea.upperBound / keyboard.bounds.width), accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(restore.frame.minX, try button("vime.key.p", in: keyboard).frame.maxX)
        keyboard.compact = true; keyboard.layoutIfNeeded()
        XCTAssertTrue(restore.isHidden, "Landscape keeps the full width")
        keyboard.compact = false; keyboard.layoutIfNeeded()

        restore.sendActions(for: .touchUpInside)
        keyboard.layoutIfNeeded()
        XCTAssertEqual(preferences.oneHanded, .off)
        XCTAssertTrue(restore.isHidden)
        XCTAssertEqual(try button("vime.key.q", in: keyboard).frame, fullQ)
    }
}
