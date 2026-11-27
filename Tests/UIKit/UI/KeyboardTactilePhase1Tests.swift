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

        // 1. Compound bottom-out: letter fires 1.0x rigid + 0.55x heavy; utility fires 1.0x rigid + 0.90x heavy.
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .letter))
        XCTAssertEqual(letterGens.last?.impacts, [1.0])
        XCTAssertEqual(utilGens.last?.impacts, [CGFloat(KeyboardHaptics.letterBodyScale)])
        XCTAssertTrue(haptics.play(intensity: 1.0, style: .utility))
        XCTAssertEqual(letterGens.last?.impacts, [1.0, 1.0])
        XCTAssertEqual(utilGens.last?.impacts, [CGFloat(KeyboardHaptics.letterBodyScale), CGFloat(KeyboardHaptics.utilityBodyScale)])

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

    func testLanguageSwitchGuardShadowModeAndQuickRevert() {
        let guardEngine = LanguageSwitchGuard()
        guardEngine.enforcementEnabled = false
        // Explicit shadow mode: recommends suppress on fast left-edge graze, but still allows toggle.
        XCTAssertFalse(guardEngine.enforcementEnabled)

        // Programmatic / direct action (nil context) always passes cleanly.
        let direct = guardEngine.evaluate(context: nil)
        XCTAssertTrue(direct.shouldToggleLanguage)
        XCTAssertEqual(direct.reason, .directAction)

        // Fast left-edge tap right after a letter -> shadow recommendation is suppress, effective is allow.
        let graze = guardEngine.evaluate(context: .init(
            dx: -0.35, dy: 0.0, ikiSinceLastLetter: 0.14, hasOtherHeldKey: false, isComposing: true, timestamp: 10.0
        ))
        XCTAssertEqual(graze.recommendation, .suppress)
        XCTAssertEqual(graze.effectiveDecision, .allow)
        XCTAssertEqual(graze.reason, .leftEdgeFast)
        XCTAssertTrue(graze.shouldToggleLanguage)

        // User reverts within 1.8 s -> counted as quick_revert ground truth.
        let revert = guardEngine.evaluate(context: .init(
            dx: 0.0, dy: 0.0, ikiSinceLastLetter: nil, hasOtherHeldKey: false, isComposing: false, timestamp: 10.9
        ))
        XCTAssertEqual(revert.recommendation, .allow)
        XCTAssertEqual(guardEngine.quickRevertCount, 1)

        // Composing alone after a 2-second pause (nil IKI) on left edge must NOT be flagged.
        let deliberate = guardEngine.evaluate(context: .init(
            dx: -0.35, dy: 0.0, ikiSinceLastLetter: nil, hasOtherHeldKey: false, isComposing: true, timestamp: 15.0
        ))
        XCTAssertEqual(deliberate.recommendation, .allow)
        XCTAssertEqual(deliberate.reason, .normal)
    }

    func testLanguageSwitchGuardEnforcementOverrideAndUnretriedCount() {
        let guardEngine = LanguageSwitchGuard()
        guardEngine.enforcementEnabled = true

        // 1. Rolling overlap suppresses first tap; immediate retry within 1.0 s overrides & allows.
        let first = guardEngine.evaluate(context: .init(
            dx: 0.0, dy: 0.0, ikiSinceLastLetter: 0.30, hasOtherHeldKey: true, isComposing: false, timestamp: 20.0
        ))
        XCTAssertFalse(first.shouldToggleLanguage)
        XCTAssertEqual(first.reason, .rollingOverlap)

        let retry = guardEngine.evaluate(context: .init(
            dx: 0.0, dy: 0.0, ikiSinceLastLetter: 0.10, hasOtherHeldKey: true, isComposing: false, timestamp: 20.6
        ))
        XCTAssertTrue(retry.shouldToggleLanguage)
        XCTAssertEqual(retry.effectiveDecision, .overrideAllow)
        XCTAssertEqual(retry.reason, .doubleTapOverride)
        XCTAssertEqual(guardEngine.overrideAllowCount, 1)

        // 2. Suppressed fast top-edge tap followed by other typing (> 1.8 s later) counts as unretried_suppress.
        let topGraze = guardEngine.evaluate(context: .init(
            dx: 0.0, dy: -0.30, ikiSinceLastLetter: 0.15, hasOtherHeldKey: false, isComposing: false, timestamp: 30.0
        ))
        XCTAssertFalse(topGraze.shouldToggleLanguage)
        XCTAssertEqual(topGraze.reason, .fastEdge)
        guardEngine.noteOtherActivity(at: 32.5)
        XCTAssertEqual(guardEngine.unretriedSuppressCount, 1)
    }

    func testLanguageSwitchGuardEnabledByDefaultSuppressesFastLeftEdgeAndAllowsRetry() {
        let guardEngine = LanguageSwitchGuard()
        XCTAssertTrue(guardEngine.enforcementEnabled)

        let suppressed = guardEngine.evaluate(context: .init(
            dx: -0.35, dy: 0.0, ikiSinceLastLetter: 0.15, hasOtherHeldKey: false, isComposing: false, timestamp: 40.0
        ))
        XCTAssertEqual(suppressed.effectiveDecision, .suppress)
        XCTAssertEqual(suppressed.reason, .leftEdgeFast)
        XCTAssertFalse(suppressed.shouldToggleLanguage)

        let retried = guardEngine.evaluate(context: .init(
            dx: -0.35, dy: 0.0, ikiSinceLastLetter: 0.15, hasOtherHeldKey: false, isComposing: false, timestamp: 40.5
        ))
        XCTAssertEqual(retried.effectiveDecision, .overrideAllow)
        XCTAssertEqual(retried.reason, .doubleTapOverride)
        XCTAssertTrue(retried.shouldToggleLanguage)
    }

    func testEmojiKeyIgnoresAGrazeWhileTypingButOpensOnRetryOrACalmTap() throws {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 390, height: 260),
                                    session: KeyboardSession(),
                                    preferences: KeyboardPreferences())
        keyboard.layoutIfNeeded()
        func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(all) }
        let surface = try XCTUnwrap(all(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        var clock: TimeInterval = 50
        surface.languageGuardNow = { clock }
        let x = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.x" })
        let emoji = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.emoji" })
        let letter = CGPoint(x: x.body.midX, y: x.body.midY)
        let graze = CGPoint(x: emoji.body.midX, y: emoji.body.minY + 2)
        func tap(_ id: Int, _ point: CGPoint) { XCTAssertTrue(surface.beginPress(id: id, at: point)); surface.endPress(id: id, at: point) }

        // Its top edge right after a letter: a graze from the row above.
        tap(1, letter); clock += 0.12
        tap(2, graze)
        XCTAssertNotEqual(keyboard.panel, .symbols)
        // Tapping again at once means it: the panel opens.
        clock += 0.4
        tap(3, graze)
        XCTAssertEqual(keyboard.panel, .symbols)

        // A calm tap after typing opens it the first time.
        keyboard.panel = .keyboard
        keyboard.layoutIfNeeded()
        let calm = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.emoji" })
        let letterAgain = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.x" })
        clock += 5
        tap(4, CGPoint(x: letterAgain.body.midX, y: letterAgain.body.midY)); clock += 0.6
        tap(5, CGPoint(x: calm.body.midX, y: calm.body.midY))
        XCTAssertEqual(keyboard.panel, .symbols)
    }

    func testSendReturnKeyDropsAccentWhenFieldEmptyButStaysPressable() {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 390, height: 260),
                                    session: KeyboardSession(),
                                    preferences: KeyboardPreferences())
        var hostHasText = false
        keyboard.documentHasTextProvider = { hostHasText }
        keyboard.returnKeyType = .send
        keyboard.layoutIfNeeded()

        guard let returnKey = keyboard.returnKey else {
            return XCTFail("Expected returnKey to exist")
        }
        XCTAssertTrue(returnKey.isEnabled)
        XCTAssertTrue(returnKey.fillColor.resolvedColor(with: keyboard.traitCollection)
            .isEqual(KeyboardPalette.utility.resolvedColor(with: keyboard.traitCollection)))

        hostHasText = true
        keyboard.hostContextDidChange()
        XCTAssertTrue(returnKey.isEnabled)
        XCTAssertTrue(returnKey.fillColor.resolvedColor(with: keyboard.traitCollection)
            .isEqual(UIColor(cgColor: VimeLogo.blue).resolvedColor(with: keyboard.traitCollection)))
    }
}
