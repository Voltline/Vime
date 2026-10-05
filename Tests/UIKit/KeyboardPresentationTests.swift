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
