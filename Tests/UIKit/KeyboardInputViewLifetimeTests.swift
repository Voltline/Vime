import XCTest
import UIKit

@MainActor
final class KeyboardInputViewLifetimeTests: XCTestCase {
    private final class References {
        weak var keyboard: KeyboardView?
        weak var session: KeyboardSession?
    }

    private final class NativeHostEditor: UITextView {
        var suppliedKeyboard: KeyboardViewController?
        override var inputViewController: UIInputViewController? { suppliedKeyboard }
    }

    private final class RootReference {
        weak var value: KeyboardInputView?
    }

    private func nativeHostRootsAfterTeardown() async throws -> [RootReference] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let editor = NativeHostEditor(frame: CGRect(x: 20, y: 80, width: 300, height: 120))
        host.view.addSubview(editor)
        defer {
            editor.resignFirstResponder()
            editor.suppliedKeyboard = nil
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }
        var roots: [RootReference] = []
        for _ in 0..<8 {
            try autoreleasepool {
                let controller = KeyboardViewController()
                controller.loadViewIfNeeded()
                let reference = RootReference()
                reference.value = try XCTUnwrap(controller.view as? KeyboardInputView)
                roots.append(reference)
                editor.suppliedKeyboard = controller
            }
            XCTAssertTrue(editor.becomeFirstResponder())
            // Exercise UIKit's native input hosting, including its content
            // wrappers; constructing and dropping a root alone misses the leak.
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                roots.last?.value?.window != nil
            }, object: nil)
            await fulfillment(of: [visible], timeout: 3)
            XCTAssertNotNil(roots.last?.value?.window)
            XCTAssertTrue(editor.resignFirstResponder())
            editor.suppliedKeyboard = nil
            try await Task.sleep(for: .milliseconds(350))
        }
        editor.removeFromSuperview()
        return roots
    }

    func testNativeHostReleasesSupersededInputRoots() async throws {
        let roots = try await nativeHostRootsAfterTeardown()
        // In-process UIKit hosting caches its most recent input view even
        // after the editor is removed. Earlier connections must not pile up.
        let superseded = Array(roots.dropLast())
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            superseded.allSatisfy { $0.value == nil }
        }, object: nil)
        await fulfillment(of: [released], timeout: 5)
        print("NATIVE_HOST_RETAINED_ROOTS \(roots.enumerated().compactMap { $0.element.value == nil ? nil : $0.offset })")
        XCTAssertTrue(superseded.allSatisfy { $0.value == nil }, "Superseded roots must release after native host teardown")
        XCTAssertNil(roots.last?.value?.keyboard, "The last cached root must release its keyboard tree")
    }

    func testThirtyRetainedInputViewsDoNotKeepDetachedKeyboardsOrSessionsAlive() {
        var references: [References] = []
        let retained = (0..<30).map { _ in
            autoreleasepool {
                let session = KeyboardSession(asynchronousCandidates: true)
                let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
                let reference = References()
                reference.keyboard = keyboard; reference.session = session
                references.append(reference)
                let input = KeyboardInputView(keyboard: keyboard)
                input.detachKeyboard()
                return input
            }
        }
        XCTAssertEqual(retained.count, 30)
        for (index, reference) in references.enumerated() {
            XCTAssertNil(reference.keyboard, "Old input view \(index) must release its keyboard tree")
            XCTAssertNil(reference.session, "Old input view \(index) must release its conversion session")
            XCTAssertNil(retained[index].keyboard)
        }
    }

    func testSameInputViewCanReattachKeyboardAndRestoreLayout() {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: KeyboardSession())
        let input = KeyboardInputView(keyboard: keyboard)
        let height = input.intrinsicContentSize.height
        input.detachKeyboard()
        XCTAssertNil(keyboard.superview)
        XCTAssertFalse(input.enableInputClicksWhenVisible)
        input.attachKeyboard(keyboard)
        input.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        input.layoutIfNeeded()
        XCTAssertTrue(keyboard.superview === input)
        XCTAssertTrue(input.keyboard === keyboard)
        XCTAssertEqual(keyboard.frame.origin, input.bounds.origin)
        XCTAssertEqual(keyboard.frame.width, input.bounds.width)
        XCTAssertEqual(keyboard.frame.height, input.bounds.height, accuracy: 1 / input.traitCollection.displayScale)
        XCTAssertEqual(input.intrinsicContentSize.height, keyboard.intrinsicContentSize.height)
    }

    func testVisibleHierarchyOwnsKeyboardUntilExplicitDetach() {
        weak var reference: KeyboardView?
        let input = autoreleasepool {
            let keyboard = KeyboardView(frame: .zero, session: KeyboardSession())
            reference = keyboard
            return KeyboardInputView(keyboard: keyboard)
        }
        XCTAssertNotNil(reference, "The visible hierarchy must keep the keyboard alive")
        autoreleasepool { input.detachKeyboard() }
        XCTAssertNil(reference)
    }

    func testDetachedRootRetainsOnlySizingAndAdoptsReplacementPreferences() {
        let keyboard = KeyboardView(frame: .zero, session: KeyboardSession())
        defer { keyboard.stopInteractions() }
        let input = KeyboardInputView(keyboard: keyboard)
        for compact in [false, true, false] {
            for footer in [false, true] {
                for factor in [CGFloat(0.85), 1.6] {
                    input.attachKeyboard(keyboard)
                    keyboard.compact = compact
                    keyboard.showsFooter = footer
                    keyboard.heightFactor = factor
                    input.detachKeyboard()
                    // Repeated cleanup must not discard the sizing snapshot.
                    input.detachKeyboard()
                    for width in [CGFloat(375), 844] {
                        let proposed = CGSize(width: width, height: 224)
                        XCTAssertEqual(input.systemLayoutSizeFitting(proposed).height,
                            keyboard.preferredHeight(for: width), accuracy: 0.001)
                    }
                    XCTAssertNil(input.keyboard)
                    XCTAssertNil(keyboard.superview)
                }
            }
        }
    }

    func testRepeatedControllerCallbacksKeepOneSetOfRootOwnedConstraints() throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        let input = try XCTUnwrap(controller.view as? KeyboardInputView)
        let keyboard = try XCTUnwrap(input.keyboard)
        func edges() -> [NSLayoutConstraint] {
            input.constraints.filter { ($0.firstItem as? UIView) === keyboard && ($0.secondItem as? UIView) === input }
        }
        for _ in 0..<10 {
            controller.viewWillAppear(false)
            controller.viewWillAppear(false)
            XCTAssertTrue(input.keyboard === keyboard)
            XCTAssertEqual(edges().count, 4, "The input root owns the child's layout")
            XCTAssertEqual(input.constraints.filter { $0.identifier == "vime.keyboard.height" }.count, 1)
            // A cancelled disappearance never reaches didDisappear.
            controller.viewWillDisappear(false)
            controller.viewWillDisappear(false)
            XCTAssertTrue(keyboard.superview === input)
            controller.viewWillAppear(false)
            XCTAssertEqual(edges().count, 4)
            controller.viewWillDisappear(false)
            controller.viewDidDisappear(false)
            controller.viewDidDisappear(false)
            XCTAssertNil(input.keyboard)
            XCTAssertNil(keyboard.superview)
            XCTAssertTrue(edges().isEmpty)
            XCTAssertEqual(input.constraints.filter { $0.identifier == "vime.keyboard.height" }.count, 1,
                "Releasing the child must preserve the root's sizing constraint")
        }
        controller.viewWillAppear(false)
        XCTAssertEqual(edges().count, 4)
        XCTAssertTrue(keyboard.superview === input)
    }

    func testReattachedControllerUpdatesLayoutAcrossWidthAndTraitChanges() throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        let input = try XCTUnwrap(controller.view as? KeyboardInputView)
        let keyboard = try XCTUnwrap(input.keyboard)
        for (width, style) in [(CGFloat(440), UIUserInterfaceStyle.light), (844, .dark), (390, .light)] {
            controller.viewWillDisappear(false)
            controller.viewDidDisappear(false)
            controller.overrideUserInterfaceStyle = style
            controller.viewWillAppear(false)
            input.bounds.size.width = width
            controller.viewWillLayoutSubviews()
            let height = try XCTUnwrap(input.constraints.first { $0.identifier == "vime.keyboard.height" })
            XCTAssertTrue(height.isActive)
            XCTAssertEqual(height.constant, keyboard.preferredHeight(for: width))
            input.bounds.size.height = height.constant
            input.setNeedsLayout(); input.layoutIfNeeded()
            XCTAssertEqual(keyboard.frame.origin, input.bounds.origin)
            XCTAssertEqual(keyboard.frame.width, input.bounds.width)
            XCTAssertEqual(keyboard.frame.height, input.bounds.height, accuracy: 1 / input.traitCollection.displayScale)
            XCTAssertFalse(keyboard.bounds.isEmpty)
            XCTAssertTrue(input.keyboard === keyboard)
        }
    }

    func testNewControllerGetsIndependentSizingWhileOldHostRetainsItsRoot() async throws {
        weak var previous: KeyboardViewController?
        let (input, oldHeight) = try autoreleasepool {
            let controller = KeyboardViewController()
            previous = controller
            controller.loadViewIfNeeded()
            let input = try XCTUnwrap(controller.view as? KeyboardInputView)
            let height = try XCTUnwrap(input.constraints.first { $0.identifier == "vime.keyboard.height" })
            input.keyboard?.heightFactor = 0.85
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            return (input, height)
        }
        XCTAssertTrue(oldHeight.isActive)
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in previous == nil }, object: nil)
        await fulfillment(of: [released], timeout: 5)
        XCTAssertNil(previous, "The old host may retain its root after releasing the controller")
        let replacement = KeyboardViewController()
        replacement.loadViewIfNeeded()
        replacement.viewWillAppear(false)
        let replacementInput = try XCTUnwrap(replacement.view as? KeyboardInputView)
        XCTAssertFalse(replacementInput === input, "UIKit roots must not move between controller/host connections")
        let keyboard = try XCTUnwrap(replacementInput.keyboard)
        let previousHeight = oldHeight.constant
        keyboard.heightFactor = 1.6
        let heights = replacementInput.constraints.filter { $0.identifier == "vime.keyboard.height" }
        XCTAssertEqual(heights.count, 1)
        XCTAssertTrue(heights[0].isActive)
        XCTAssertFalse(heights[0] === oldHeight)
        XCTAssertEqual(heights[0].constant, keyboard.preferredHeight(for: replacementInput.bounds.width), accuracy: 0.001)
        XCTAssertEqual(oldHeight.constant, previousHeight, "An old root keeps only its own sizing state")
        XCTAssertNil(input.keyboard)
    }
}
