import XCTest
import UIKit

@MainActor
final class KeyboardPresentationTests: XCTestCase {
    private final class AttachedInputView: UIInputView {
        let keyboard: KeyboardView
        init(keyboard: KeyboardView) {
            self.keyboard = keyboard
            super.init(frame: keyboard.frame, inputViewStyle: .keyboard)
            allowsSelfSizing = true; addSubview(keyboard)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var intrinsicContentSize: CGSize { keyboard.intrinsicContentSize }
        override func layoutSubviews() { super.layoutSubviews(); keyboard.frame = bounds }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
    private func capture(_ view: UIView, name: String) {
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: view.bounds).image {
            UIColor.systemBackground.setFill(); $0.fill(view.bounds); view.layer.render(in: $0.cgContext)
        })
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPortraitFitsShortReconnectFrameAndKeepsBottomRowHittable() throws {
        let keyboard = KeyboardView(frame: .zero, session: KeyboardSession())
        defer { keyboard.stopInteractions() }
        keyboard.showsFooter = false
        keyboard.heightFactor = 1
        let preferred = keyboard.preferredHeight(for: 440)
        for height in [CGFloat(224), 239, preferred, preferred + 12] {
            keyboard.frame = CGRect(x: 0, y: 0, width: 440, height: height)
            keyboard.layoutIfNeeded()
            let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
            for region in surface.regions {
                XCTAssertTrue(keyboard.bounds.contains(region.body), "Every row must fit the host's actual portrait frame")
            }
            for id in ["vime.key.space", "vime.key.return"] {
                let key = try button(id, in: keyboard)
                XCTAssertGreaterThanOrEqual(key.bounds.height, 36)
                XCTAssertLessThan(key.frame.maxY, height)
                XCTAssertLessThan(height - key.frame.maxY, 2)
            }
            let emoji = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "表情" } as? UIButton)
            let center = emoji.convert(CGPoint(x: emoji.bounds.midX, y: emoji.bounds.midY), to: keyboard)
            XCTAssertTrue(keyboard.bounds.contains(center))
            XCTAssertNotNil(keyboard.hitTest(center, with: nil))
            XCTAssertTrue(surface.resolvedKey(at: surface.convert(center, from: keyboard)) === emoji)
            XCTAssertEqual(keyboard.preferredHeight(for: 440), preferred,
                "An imposed short frame must never become the next preferred size")
            if height == 224 { capture(keyboard, name: "portrait-short-reconnect-complete-bottom-row") }
        }
    }

    func testLandscapeToolbarAndAllRowsStaySeparatedAcrossSizesAndPages() throws {
        let keyboard = KeyboardView(frame: .zero, session: KeyboardSession())
        defer { keyboard.stopInteractions() }
        keyboard.compact = true
        keyboard.showsFooter = false
        for width in [CGFloat(568), 680, 956] {
            for factor in [CGFloat(0.85), 1, 1.6] {
                keyboard.heightFactor = factor
                for type in [UIKeyboardType.default, .numberPad] {
                    keyboard.keyboardType = type
                    keyboard.frame = CGRect(x: 0, y: 0, width: width,
                        height: keyboard.preferredHeight(for: width))
                    keyboard.layoutIfNeeded()
                    let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
                    let firstKeyY = try XCTUnwrap(surface.regions.map { $0.body.minY }.min())
                    let controls = try [button("vime.brand.settings", in: keyboard),
                        button("vime.candidates.expand", in: keyboard),
                        XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "切换平假名和片假名" } as? UIButton)]
                    for control in controls {
                        let frame = control.convert(control.bounds, to: keyboard)
                        XCTAssertGreaterThanOrEqual(frame.minY, 8)
                        XCTAssertGreaterThanOrEqual(firstKeyY - frame.maxY, 8,
                            "The toolbar needs breathing room above the first key row")
                    }
                    let brand = controls[0].convert(controls[0].bounds, to: keyboard)
                    let arrow = controls[1].convert(controls[1].bounds, to: keyboard)
                    let mode = controls[2].convert(controls[2].bounds, to: keyboard)
                    XCTAssertEqual(arrow.minX - mode.maxX, 8, accuracy: 0.001,
                        "The trailing toolbar is a group, not proportionally spaced individual buttons")
                    if type == .default {
                        let q = try button("vime.key.q", in: keyboard)
                        let p = try button("vime.key.p", in: keyboard)
                        XCTAssertEqual(brand.minX, q.frame.minX, accuracy: 0.001)
                        XCTAssertEqual(arrow.maxX, p.frame.maxX, accuracy: 0.001)
                    }
                    for region in surface.regions {
                        XCTAssertTrue(keyboard.bounds.contains(region.body))
                        XCTAssertGreaterThanOrEqual(keyboard.bounds.maxY - region.body.maxY, 1)
                        for other in surface.regions where other.key !== region.key {
                            XCTAssertFalse(region.body.intersects(other.body), "Painted keys must stay separated")
                        }
                    }
                    if factor == 0.85 {
                        capture(keyboard, name: "landscape-\(Int(width))-\(type.rawValue)-complete-layout")
                    }
                }
            }
        }
    }

    func testLandscapeHeadersAndPanelsShareKeyPlaneEdges() throws {
        for width in [CGFloat(568), 722, 956] {
            let session = KeyboardSession()
            let keyboard = KeyboardView(frame: .zero, session: session)
            defer { keyboard.stopInteractions() }
            keyboard.compact = true; keyboard.showsFooter = false
            keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.preferredHeight(for: width))
            keyboard.layoutIfNeeded()
            let q = try button("vime.key.q", in: keyboard)
            let p = try button("vime.key.p", in: keyboard)
            let left = q.frame.minX, right = p.frame.maxX
            _ = session.type("nihongo"); session.onCandidatesChange?(); keyboard.layoutIfNeeded()
            let strip = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates" })
            let stripFrame = strip.convert(strip.bounds, to: keyboard)
            let arrow = try button("vime.candidates.expand", in: keyboard)
            XCTAssertEqual(stripFrame.minX, left, accuracy: 0.001)
            XCTAssertEqual(arrow.frame.minX - stripFrame.maxX, 8, accuracy: 0.001)
            capture(keyboard, name: "landscape-\(Int(width))-candidate-strip")
            arrow.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
            let title = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates.title" })
            let close = try button("vime.panel.close", in: keyboard)
            let range = try [button("vime.segment.shorten", in: keyboard), button("vime.segment.lengthen", in: keyboard), button("vime.segment.whole", in: keyboard)]
            XCTAssertEqual(title.frame.minX, left, accuracy: 0.001)
            XCTAssertEqual(close.frame.maxX, right, accuracy: 0.001)
            if !range[0].isHidden {
                let controls = [title] + range + [close]
                for (first, second) in zip(controls, controls.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(second.frame.minX - first.frame.maxX, 8)
                    XCTAssertEqual(first.frame.midY, second.frame.midY, accuracy: 0.001)
                }
            }
            capture(keyboard, name: "landscape-\(Int(width))-expanded-candidates")
            close.sendActions(for: .touchUpInside); session.reset(); session.onCandidatesChange?(); keyboard.layoutIfNeeded()
            try button("vime.brand.settings", in: keyboard).sendActions(for: .touchUpInside)
            keyboard.layoutIfNeeded()
            let settings = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.settings" })
            settings.layoutIfNeeded()
            let stack = try XCTUnwrap(settings.subviews.compactMap { $0 as? UIStackView }.first)
            // Auto Layout rounds the stack to physical pixels; manual key
            // frames retain subpixel coordinates until rendering.
            let pixel = 1 / keyboard.traitCollection.displayScale
            XCTAssertEqual(stack.frame.minX, left, accuracy: pixel)
            XCTAssertEqual(stack.frame.maxX, right, accuracy: pixel)
            capture(keyboard, name: "landscape-\(Int(width))-settings")
            try button("vime.panel.close", in: keyboard).sendActions(for: .touchUpInside)
            let emoji = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "表情" } as? UIButton)
            emoji.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
            let panel = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardSymbolPanel }.first)
            for mode in [KeyboardSymbolPanel.Mode.emoji, .kaomoji, .symbols] {
                panel.selectMode(mode); panel.layoutIfNeeded()
                let symbolClose = try button("vime.symbols.close", in: panel)
                let tabs = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.mode" })
                let grid = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.grid" })
                XCTAssertEqual(tabs.frame.minX, left, accuracy: 0.001)
                XCTAssertEqual(symbolClose.frame, close.frame)
                XCTAssertLessThanOrEqual(tabs.frame.maxX + 8, symbolClose.frame.minX)
                let viewport = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.pages" })
                let viewportFrame = viewport.convert(viewport.bounds, to: keyboard)
                XCTAssertEqual(viewportFrame.minX, left, accuracy: 0.001)
                XCTAssertEqual(viewportFrame.maxX, right, accuracy: 0.001)
                let gridFrame = grid.convert(grid.bounds, to: keyboard)
                // UIScrollView rounds large page offsets to display pixels.
                // The viewport must align exactly; rendered cells within it
                // can differ by the subpixel remainder of that rounding.
                XCTAssertEqual(gridFrame.minX, left, accuracy: pixel)
                XCTAssertEqual(gridFrame.maxX, right, accuracy: pixel)
                capture(keyboard, name: "landscape-\(Int(width))-symbols-\(mode.rawValue)")
            }
        }
    }

    func testLandscapeMinimumFillsAvailableHeightWithoutDuplicatingSystemFooter() throws {
        let keyboard = KeyboardView(frame: .zero, session: KeyboardSession())
        defer { keyboard.stopInteractions() }
        keyboard.heightFactor = CGFloat(KeyboardPreferences.heightRange.lowerBound)
        for width in [CGFloat(568), 680, 956] {
            for footer in [false, true] {
                keyboard.compact = true
                keyboard.showsFooter = footer
                keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.preferredHeight(for: width))
                keyboard.layoutIfNeeded()
                let space = try button("vime.key.space", in: keyboard)
                let enter = try button("vime.key.return", in: keyboard)
                for key in [space, enter] {
                    XCTAssertGreaterThanOrEqual(key.bounds.height, 39)
                    let remaining = keyboard.bounds.maxY - key.frame.maxY
                    if footer {
                        XCTAssertGreaterThanOrEqual(remaining, 36, "Our own globe needs its footer")
                    } else {
                        XCTAssertGreaterThanOrEqual(remaining, 1)
                        XCTAssertLessThanOrEqual(remaining, 2,
                            "System controls outside the input view must not leave a second empty footer inside it")
                    }
                    let point = key.convert(CGPoint(x: key.bounds.midX, y: key.bounds.midY), to: keyboard)
                    XCTAssertNotNil(keyboard.hitTest(point, with: nil))
                }
                let minimum = keyboard.bounds.height
                keyboard.heightFactor = 1
                XCTAssertEqual(keyboard.preferredHeight(for: width), minimum, accuracy: 0.001)
                keyboard.heightFactor = CGFloat(KeyboardPreferences.heightRange.lowerBound)
            }
        }
        keyboard.compact = false
        let shortPortrait = keyboard.preferredHeight(for: 440)
        keyboard.heightFactor = 1
        XCTAssertGreaterThan(keyboard.preferredHeight(for: 440), shortPortrait,
            "Rotating back must preserve the portrait height preference")
    }

    func testLandscapeFitsActualHostHeightWithoutGrowingIntrinsicSize() throws {
        let keyboard = KeyboardView(frame: .zero, session: KeyboardSession())
        defer { keyboard.stopInteractions() }
        keyboard.compact = true
        keyboard.heightFactor = 0.85
        for footer in [false, true] {
            keyboard.showsFooter = footer
            let preferred = keyboard.preferredHeight(for: 722)
            for extra in [CGFloat(0), 9, 17] {
                keyboard.frame = CGRect(x: 0, y: 0, width: 722, height: preferred + extra)
                keyboard.layoutIfNeeded()
                let space = try button("vime.key.space", in: keyboard)
                let margin = keyboard.bounds.maxY - space.frame.maxY
                XCTAssertEqual(margin, footer ? 37.95 : 1.95, accuracy: 0.001,
                    "Extra host height belongs to the key plane, not a blank band below it")
                let first = try button("vime.key.q", in: keyboard)
                let toolbar = try button("vime.brand.settings", in: keyboard)
                XCTAssertEqual(first.frame.minY - toolbar.frame.maxY, 8, accuracy: 0.001)
                XCTAssertEqual(keyboard.intrinsicContentSize.height, preferred, accuracy: 0.001,
                    "An imposed host height must not cause a growing height feedback loop")
            }
            keyboard.heightFactor = 1.6
            keyboard.frame.size.height = preferred
            keyboard.setNeedsLayout(); keyboard.layoutIfNeeded()
            let space = try button("vime.key.space", in: keyboard)
            XCTAssertEqual(keyboard.bounds.maxY - space.frame.maxY, footer ? 37.95 : 1.95, accuracy: 0.001,
                "A tall portrait preference must not overflow a smaller actual landscape view")
            XCTAssertGreaterThanOrEqual(space.bounds.height, 39)
            keyboard.heightFactor = 0.85
        }
    }

    func testHeldPreviewStaysAboveCandidatesAfterLayoutAndPublication() throws {
        let session = KeyboardSession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(keyboard); window.isHidden = false
        defer { keyboard.stopInteractions(); window.isHidden = true }
        _ = session.type("nihongo"); session.onCandidatesChange?(); keyboard.layoutIfNeeded()
        let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        let q = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.q" })
        q.key.showsPreview = true
        let p = CGPoint(x: q.body.midX, y: q.body.midY)
        surface.beginPress(id: 1, at: p)
        // Reproduce a candidate publication and keyboard relayout while held.
        session.onCandidatesChange?(); keyboard.setNeedsLayout(); keyboard.layoutIfNeeded()
        let bubble = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.swipe.preview" })
        let strip = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates" })
        var ancestor = strip
        while ancestor.superview !== keyboard { ancestor = try XCTUnwrap(ancestor.superview) }
        var previewRoot = bubble
        while previewRoot.superview !== keyboard { previewRoot = try XCTUnwrap(previewRoot.superview) }
        XCTAssertGreaterThan(try XCTUnwrap(keyboard.subviews.firstIndex(of: previewRoot)),
            try XCTUnwrap(keyboard.subviews.firstIndex(of: ancestor)), "A held preview must stay above header/candidates after any layout")
        XCTAssertEqual(bubble.alpha, 1)
        XCTAssertEqual(try XCTUnwrap(bubble.backgroundColor).resolvedColor(with: keyboard.traitCollection).cgColor.alpha, 1)
        XCTAssertFalse(previewRoot.isUserInteractionEnabled, "Preview must not intercept keyboard/candidate touches")
        capture(keyboard, name: "opaque-key-preview-over-candidates")
        surface.endPress(id: 1, at: p)
        XCTAssertFalse(descendants(keyboard).contains { $0.accessibilityIdentifier == "vime.swipe.preview" })
        XCTAssertEqual(session.raw, "nihongoq")
    }

    func testSymbolTopSpacingInInputViewSurvivesReopenAndResize() throws {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: KeyboardSession())
        let input = AttachedInputView(keyboard: keyboard)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        input.frame.origin.y = window.bounds.height - input.bounds.height
        window.rootViewController?.view.addSubview(input)
        defer { keyboard.stopInteractions(); window.isHidden = true }
        keyboard.layoutIfNeeded()
        let emoji = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "表情" } as? UIButton)
        emoji.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        let panel = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardSymbolPanel }.first)
        panel.layoutIfNeeded()
        let close = try button("vime.symbols.close", in: panel)
        let modes = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.mode" })
        capture(input, name: "symbol-top-spacing")
        let initial = close.frame.minY
        XCTAssertGreaterThan(initial, 0, "Own a fixed top inset instead of allowing edge-flush controls")
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        let initialKeyboard = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardView }.first)
        let height = try XCTUnwrap(controller.view.constraints.first { $0.identifier == "vime.keyboard.height" })
        XCTAssertEqual(height.constant, initialKeyboard.preferredHeight(for: controller.view.bounds.width), accuracy: 0.001,
            "The very first height must match loaded preferences/footer, not a temporary default")
        let beforeLayout = height.constant
        controller.viewWillLayoutSubviews(); controller.viewWillLayoutSubviews()
        XCTAssertEqual(height.constant, beforeLayout, accuracy: 0.001)
        for factor in [CGFloat(1.3), 1] {
            keyboard.heightFactor = factor
            input.frame.size.height = keyboard.preferredHeight(for: input.bounds.width)
            input.setNeedsLayout()
            input.layoutIfNeeded(); keyboard.layoutIfNeeded(); panel.layoutIfNeeded()
            XCTAssertEqual(close.frame.minY, initial, accuracy: 0.001)
            XCTAssertEqual(modes.frame.midY, close.frame.midY, accuracy: 0.001)
            XCTAssertEqual(panel.frame, keyboard.bounds)
        }
        close.sendActions(for: .touchUpInside)
        emoji.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded(); panel.layoutIfNeeded()
        XCTAssertEqual(close.frame.minY, initial, accuracy: 0.001)
    }
}
