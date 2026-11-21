import XCTest
@testable import Vime

@MainActor
final class KeyboardTactilePhase1Tests: XCTestCase {
    private final class MockImpactGenerator: KeyboardHaptics.Generator {
        var prepared = 0
        var impacts: [CGFloat] = []
        func prepare() { prepared += 1 }
        func impactOccurred(intensity: CGFloat) { impacts.append(intensity) }
    }

    private final class MockSelectionGenerator: KeyboardHaptics.SelectionGenerator {
        var prepared = 0
        var selections = 0
        func prepare() { prepared += 1 }
        func selectionChanged() { selections += 1 }
    }

    func testDifferentiatedHapticsThrottlingAndUnifiedRotation() {
        var letterGens: [MockImpactGenerator] = []
        var utilGens: [MockImpactGenerator] = []
        var selGens: [MockSelectionGenerator] = []
        var clock: TimeInterval = 100.0

        let haptics = KeyboardHaptics(
            makeGenerator: { let g = MockImpactGenerator(); letterGens.append(g); return g },
            makeUtilityGenerator: { let g = MockImpactGenerator(); utilGens.append(g); return g },
            makeSelectionGenerator: { let g = MockSelectionGenerator(); selGens.append(g); return g },
            now: { clock }
        )

        // 1. Compound bottom-out: letter fires 1.0x heavy; utility fires 1.0x heavy + 0.80x rigid.
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .letter))
        XCTAssertEqual(letterGens.last?.impacts, [1.0])
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .utility))
        XCTAssertEqual(letterGens.last?.impacts, [1.0, 1.0])
        XCTAssertEqual(utilGens.last?.impacts, [0.80])

        // 2. Repeat delete throttles at 85ms and scales intensity by 0.40.
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .repeatDelete))
        XCTAssertEqual(letterGens.last?.impacts.last ?? 0, 0.40, accuracy: 1e-4)
        clock += 0.040
        XCTAssertFalse(haptics.play(intensity: 1.0, style: .repeatDelete))
        clock += 0.050
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .repeatDelete))

        // 3. Cursor tick throttles at 50ms and uses selection generator.
        XCTAssertTrue(haptics.play(intensity: 0.8, style: .cursorTick))
        XCTAssertEqual(selGens.last?.selections, 1)
        clock += 0.020
        XCTAssertFalse(haptics.play(intensity: 0.8, style: .cursorTick))
        clock += 0.035
        XCTAssertTrue(haptics.play(intensity: 0.8, style: .cursorTick))
        XCTAssertEqual(selGens.last?.selections, 2)

        // 4. Unified rotation across all generator types at 128 total events.
        for _ in 0..<125 {
            _ = haptics.play(intensity: 0.5, style: .tick)
        }
        XCTAssertGreaterThanOrEqual(selGens.count, 2)
    }

    func testCandidateButtonDefersVisualUpdateWhilePressedAndAppliesAfterRelease() {
        let button = KeyboardCandidateButton(frame: CGRect(x: 0, y: 0, width: 80, height: 36))
        let sessionID = UUID()
        let token1 = CandidateSelectionToken(sessionID: sessionID, generation: 1, index: 0, kind: .composition)
        let token2 = CandidateSelectionToken(sessionID: sessionID, generation: 2, index: 0, kind: .composition)
        var first = CandidatePresentation(text: "你好", source: .conversion, consumedInputCount: 5, correction: nil)
        first.selectionToken = token1
        var second = CandidatePresentation(text: "泥嚎", source: .conversion, consumedInputCount: 5, correction: nil)
        second.selectionToken = token2

        button.present(first, index: 0, highlighted: true)
        XCTAssertEqual(button.title(for: .normal), "你好")

        // User presses down on the candidate button.
        button.sendActions(for: .touchDown)

        // Async reranking arrives while finger is still down: visual title must NOT jump!
        button.present(second, index: 0, highlighted: true)
        XCTAssertEqual(button.title(for: .normal), "你好")

        // Releasing takes the armed token ("你好") and then applies the pending visual update ("泥嚎").
        let taken = button.takeSelectionToken()
        XCTAssertEqual(taken, token1)
        XCTAssertEqual(button.title(for: .normal), "泥嚎")
    }

    func testPreviewBubbleCachesShadowPathAndFiresAlternateActivationOnce() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let key = KeyboardKey(title: "A")
        key.frame = CGRect(x: 60, y: 80, width: 40, height: 46)
        key.previewContainer = container
        key.showsPreview = true
        key.hint = "@"
        key.alternateTitle = "@"
        key.alternateAction = {}
        container.addSubview(key)

        var activations = 0
        key.onAlternateActivate = { activations += 1 }

        key.beginResolvedPress()
        key.presentResolvedPress(alternate: false)
        let bubble = container.subviews.first { $0.accessibilityIdentifier == "vime.swipe.preview" }
        XCTAssertNotNil(bubble)
        XCTAssertNotNil(bubble?.layer.shadowPath)
        XCTAssertEqual(activations, 0)

        // Swipe up crosses threshold -> fires once.
        key.presentResolvedPress(alternate: true)
        XCTAssertEqual(activations, 1)
        // Staying in alternate does not re-fire.
        key.presentResolvedPress(alternate: true)
        XCTAssertEqual(activations, 1)

        key.stopTracking()
    }

    func testTrailingWordDeletionCount() {
        XCTAssertEqual(KeyboardTextNavigation.trailingWordDeletionCount(in: "hello world"), 5)
        XCTAssertEqual(KeyboardTextNavigation.trailingWordDeletionCount(in: "hello world  "), 7)
        XCTAssertEqual(KeyboardTextNavigation.trailingWordDeletionCount(in: "今天天气很好"), 2)
        XCTAssertEqual(KeyboardTextNavigation.trailingWordDeletionCount(in: "你好\n"), 1)
        XCTAssertEqual(KeyboardTextNavigation.trailingWordDeletionCount(in: "ok!"), 1)
    }

    func testCursorSpeedGainSmoothsVelocityAndPreservesRemainder() {
        let surface = KeyboardTouchSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let key = KeyboardKey(title: "a")
        let body = CGRect(x: 100, y: 80, width: 40, height: 46)
        surface.regions = [.init(key: key, body: body, cell: CGRect(x: 0, y: 0, width: 390, height: 220))]

        var clock: TimeInterval = 10.0
        surface.now = { clock }
        var steps: [Int] = []
        surface.onCursorMove = { dx, _ in steps.append(dx) }

        // Enter horizontal cursor gesture at x = 185 (65pt right of center 120).
        let origin = CGPoint(x: 120, y: 100)
        XCTAssertTrue(surface.beginPress(id: 1, at: origin))
        surface.movePress(id: 1, to: CGPoint(x: 185, y: 100))
        XCTAssertEqual(steps, [1])
        steps.removeAll()

        // 1. Slow micro-drag (40 pt/s <= 80 pt/s: +2pt every 50ms for 8 frames = +16pt total):
        //    Stays at baseline 8.0 pt/step without deceleration, yielding exactly 2 steps via remainder accumulation.
        var x: CGFloat = 185
        for _ in 0..<8 {
            clock += 0.050
            x += 2
            surface.movePress(id: 1, to: CGPoint(x: x, y: 100))
        }
        let slowTotal = steps.reduce(0, +)
        XCTAssertEqual(slowTotal, 2)
        steps.removeAll()

        // 2. Fast flick (500 pt/s: +5pt every 10ms for 10 frames = +50pt total):
        //    Smoothed speed accelerates toward fast (~4.5 pt/step), yielding significantly more steps per pt.
        for _ in 0..<10 {
            clock += 0.010
            x += 5
            surface.movePress(id: 1, to: CGPoint(x: x, y: 100))
        }
        let fastTotal = steps.reduce(0, +)
        XCTAssertGreaterThanOrEqual(fastTotal, 9)
        surface.endPress(id: 1, at: CGPoint(x: x, y: 100))
    }
}
