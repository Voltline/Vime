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

        // 1. Profile comparison at full intensity (1.0):
        // - .compound (Scheme 2): letter fires 1.0x heavy; utility fires 1.0x heavy + 0.80x rigid.
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .letter, profile: .compound))
        XCTAssertEqual(letterGens.last?.impacts, [1.0])
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .utility, profile: .compound))
        XCTAssertEqual(letterGens.last?.impacts, [1.0, 1.0])
        XCTAssertEqual(utilGens.last?.impacts, [0.80])

        // - .stepped (Scheme 1): letter scales down to 0.72x heavy; utility fires full 1.0x heavy.
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .letter, profile: .stepped))
        XCTAssertEqual(letterGens.last?.impacts.last ?? 0, 0.72, accuracy: 1e-4)
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .utility, profile: .stepped))
        XCTAssertEqual(letterGens.last?.impacts.last ?? 0, 1.0, accuracy: 1e-4)

        // - .rigidUtility: utility fires 1.0x rigid.
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .utility, profile: .rigidUtility))
        XCTAssertEqual(utilGens.last?.impacts.last ?? 0, 1.0, accuracy: 1e-4)

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
}
