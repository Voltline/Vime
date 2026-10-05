import XCTest
import UIKit

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
        keyboard.onEdit = { host.apply($0) }; keyboard.onMarkedTextChange = { host.updateMarkedText($0) }
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

        var column: Int?
        let offset = KeyboardTextNavigation.verticalOffset(before: "abc👩🏽‍💻", after: "d\nx\nabcdef", steps: 1, column: &column)
        XCTAssertEqual(offset, 3, "Proxy offset uses UTF-16 and clamps the preferred column on a short line")
        let next = KeyboardTextNavigation.verticalOffset(before: "abc👩🏽‍💻d\nx", after: "\nabcdef", steps: 1, column: &column)
        XCTAssertEqual(next, 5, "The next long line restores the preferred character column")
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
        for c in "nihongo" { try button("vime.key.\(c)", in: keyboard).sendActions(for: .touchUpInside) }
        let index = try XCTUnwrap(session.candidates.firstIndex(of: "ニホンゴ"))
        XCTAssertLessThan(index, session.candidates.count, "Direct katakana remains available without a reserved slot")
        let strip = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates" })
        XCTAssertFalse(strip.isHidden)
        try button("vime.candidates.expand", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertTrue(strip.isHidden)
        XCTAssertTrue(surface.isHidden)
        try button("vime.panel.close", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertFalse(strip.isHidden)
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
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 20)
        grid.layoutIfNeeded()
        attachAppearance(keyboard, name: "kaomoji-panel")
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: 0))
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
            XCTAssertGreaterThan(grid.numberOfItems(inSection: 0), 40)
            text.text = ""; text.selectedRange = NSRange(location: 0, length: 0)
            for i in 0..<4 { panel.collectionView(grid, didSelectItemAt: IndexPath(item: i, section: 0)) }
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
        XCTAssertEqual(grid.numberOfItems(inSection: 0), KeyboardSymbolCatalog.symbols[0].items.count,
            "An old emoji availability request must never overwrite the symbol category")
        panel.selectMode(.emoji)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThan(grid.numberOfItems(inSection: 0), 100)
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
        var x: CGFloat?
        let offset = layout.verticalOffset(before: ns.substring(to: start), after: ns.substring(from: start),
            steps: -1, width: 180, preferredX: &x)
        XCTAssertLessThan(offset, 0, "A soft wrap must not resolve to the old zero offset")
        let moved = start + offset
        let back = layout.verticalOffset(before: ns.substring(to: moved), after: ns.substring(from: moved),
            steps: 1, width: 180, preferredX: &x)
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
        let choice = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.setting.theme" } as? UISegmentedControl)
        choice.selectedSegmentIndex = try XCTUnwrap(KeyboardTheme.allCases.firstIndex(of: .midnight))
        choice.sendActions(for: .valueChanged)
        XCTAssertEqual(KeyboardPreferences().theme, .midnight)
        XCTAssertEqual(keyboard.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(surface.regions.first?.key.titleColor(for: .normal), .white)
        try button("vime.panel.close", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertFalse(surface.isHidden)
        attachAppearance(keyboard, name: "midnight-keyboard")
    }
}
