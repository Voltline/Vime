import XCTest
import UIKit

@MainActor
final class KeyboardInputViewLifetimeTests: XCTestCase {
    private final class References {
        weak var keyboard: KeyboardView?
        weak var session: KeyboardSession?
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
        XCTAssertEqual(keyboard.frame, input.bounds)
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

    func testRepeatedControllerCallbacksKeepExactlyOneSetOfEdgeConstraints() throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        let input = try XCTUnwrap(controller.inputView as? KeyboardInputView)
        let keyboard = try XCTUnwrap(input.keyboard)
        func edges() -> [NSLayoutConstraint] {
            input.constraints.filter { ($0.firstItem as? UIView) === keyboard && ($0.secondItem as? UIView) === input }
        }
        for _ in 0..<10 {
            controller.viewWillAppear(false)
            controller.viewWillAppear(false)
            XCTAssertTrue(input.keyboard === keyboard)
            XCTAssertEqual(edges().count, 4)
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
        }
        controller.viewWillAppear(false)
        XCTAssertEqual(edges().count, 4)
        XCTAssertTrue(keyboard.superview === input)
    }

    func testReattachedControllerUpdatesLayoutAcrossWidthAndTraitChanges() throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        let input = try XCTUnwrap(controller.inputView as? KeyboardInputView)
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
            XCTAssertEqual(keyboard.frame, input.bounds)
            XCTAssertFalse(keyboard.bounds.isEmpty)
            XCTAssertTrue(input.keyboard === keyboard)
        }
    }

    func testRetiredRootCanBeReusedOnlyAfterItsControllerIsReleased() {
        var owner: UIViewController? = UIViewController()
        let firstKeyboard = KeyboardView(frame: .zero, session: KeyboardSession())
        let input = KeyboardInputView.acquire(keyboard: firstKeyboard, owner: owner!)
        input.detachKeyboard(); input.offerForReuse()
        let nextOwner = UIViewController()
        let nextKeyboard = KeyboardView(frame: .zero, session: KeyboardSession())
        let whileOwned = KeyboardInputView.acquire(keyboard: nextKeyboard, owner: nextOwner)
        XCTAssertFalse(whileOwned === input, "A hidden but live controller can still reappear")
        owner = nil
        let replacementOwner = UIViewController()
        let replacementKeyboard = KeyboardView(frame: .zero, session: KeyboardSession())
        let recycled = KeyboardInputView.acquire(keyboard: replacementKeyboard, owner: replacementOwner)
        XCTAssertTrue(recycled === input)
        XCTAssertTrue(recycled.keyboard === replacementKeyboard)
        XCTAssertTrue(replacementKeyboard.superview === recycled)
        XCTAssertNil(firstKeyboard.superview)
    }

    func testRetiredRootStillInAViewHierarchyCannotBeReused() {
        let parent = UIView()
        var owner: UIViewController? = UIViewController()
        let input = KeyboardInputView.acquire(keyboard: KeyboardView(frame: .zero, session: KeyboardSession()), owner: owner!)
        input.detachKeyboard(); input.offerForReuse()
        owner = nil
        parent.addSubview(input)
        let replacementOwner = UIViewController()
        let replacement = KeyboardInputView.acquire(keyboard: KeyboardView(frame: .zero, session: KeyboardSession()), owner: replacementOwner)
        XCTAssertFalse(replacement === input)
        XCTAssertTrue(input.superview === parent)
        input.removeFromSuperview()
    }

    func testNewControllerReusesRetiredRootWithoutKeepingOldHeightConstraint() async throws {
        weak var previous: KeyboardViewController?
        let (input, oldHeight) = try autoreleasepool {
            let controller = KeyboardViewController()
            previous = controller
            controller.loadViewIfNeeded()
            let input = try XCTUnwrap(controller.inputView as? KeyboardInputView)
            let height = try XCTUnwrap(input.constraints.first { $0.identifier == "vime.keyboard.height" })
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            return (input, height)
        }
        XCTAssertFalse(oldHeight.isActive)
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in previous == nil }, object: nil)
        await fulfillment(of: [released], timeout: 5)
        XCTAssertNil(previous, "Do not test reuse until UIKit has released the previous controller")
        let replacement = KeyboardViewController()
        replacement.loadViewIfNeeded()
        replacement.viewWillAppear(false)
        XCTAssertTrue(replacement.inputView === input)
        let heights = input.constraints.filter { $0.identifier == "vime.keyboard.height" }
        XCTAssertEqual(heights.count, 1)
        XCTAssertTrue(heights[0].isActive)
        XCTAssertFalse(heights[0] === oldHeight)
        XCTAssertNotNil(input.keyboard)
    }
}
