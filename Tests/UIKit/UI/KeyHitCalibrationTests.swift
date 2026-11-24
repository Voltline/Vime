import XCTest
@testable import Vime

final class KeyHitCalibrationTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VimeKeyHitCalibrationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testSmoothShrinkageAndHardClamp() {
        let cal = KeyHitCalibration(directory: nil)
        let body = CGRect(x: 100, y: 100, width: 40, height: 50)
        // Tap shifted +0.45 * width to the right (stored offset clamps to +0.28, dy to +0.22).
        let shiftedPoint = CGPoint(x: body.midX + 0.45 * body.width, y: body.midY + 0.35 * body.height)

        // Below minSamples (3): effective offset stays zero.
        for _ in 0..<2 {
            XCTAssertTrue(cal.learnCommittedTap(letter: "i", point: shiftedPoint, body: body, bucket: .portrait))
        }
        let early = cal.effectiveNormalizedOffset(for: "i", in: .portrait)
        XCTAssertEqual(early.dx, 0, accuracy: 1e-6)
        XCTAssertEqual(early.dy, 0, accuracy: 1e-6)

        // At 8 samples: smooth shrinkage reaches 50% weight (8 / (8 + 8)).
        for _ in 2..<8 {
            XCTAssertTrue(cal.learnCommittedTap(letter: "i", point: shiftedPoint, body: body, bucket: .portrait))
        }
        let mid = cal.effectiveModel(for: "i", in: .portrait)
        XCTAssertEqual(mid.weight, 0.5, accuracy: 1e-6)
        XCTAssertGreaterThan(mid.dx, 0.08)

        // After many samples: converges smoothly toward hard clamp.
        for _ in 8..<100 {
            XCTAssertTrue(cal.learnCommittedTap(letter: "i", point: shiftedPoint, body: body, bucket: .portrait))
        }
        let full = cal.effectiveNormalizedOffset(for: "i", in: .portrait)
        XCTAssertLessThanOrEqual(full.dx, KeyHitCalibration.maxOffsetDx + 1e-6)
        XCTAssertGreaterThan(full.dx, KeyHitCalibration.maxOffsetDx * 0.85)
        XCTAssertLessThanOrEqual(full.dy, KeyHitCalibration.maxOffsetDy + 1e-6)
    }

    func testStrictPerKeyAndPerBucketIsolation() {
        let cal = KeyHitCalibration(directory: nil)
        let body = CGRect(x: 0, y: 0, width: 40, height: 50)
        let shifted = CGPoint(x: body.midX + 8, y: body.midY + 5) // +0.20 dx, +0.10 dy

        for _ in 0..<80 {
            cal.learnCommittedTap(letter: "a", point: shifted, body: body, bucket: .portrait)
        }
        let aPortrait = cal.effectiveNormalizedOffset(for: "a", in: .portrait)
        XCTAssertEqual(aPortrait.dx, 0.20 * (80.0 / 88.0), accuracy: 0.02)
        XCTAssertEqual(aPortrait.dy, 0.10 * (80.0 / 88.0), accuracy: 0.02)

        // Untrained key in same bucket stays zero (no hierarchical backoff).
        let sPortrait = cal.effectiveNormalizedOffset(for: "s", in: .portrait)
        XCTAssertEqual(sPortrait.dx, 0, accuracy: 1e-6)
        XCTAssertEqual(sPortrait.dy, 0, accuracy: 1e-6)

        // Same key in different layout bucket stays zero.
        let aOneHanded = cal.effectiveNormalizedOffset(for: "a", in: .oneHandedRight)
        XCTAssertEqual(aOneHanded.dx, 0, accuracy: 1e-6)
        XCTAssertEqual(aOneHanded.dy, 0, accuracy: 1e-6)
    }

    func testOutlierRejectionDoesNotPolluteStats() {
        let cal = KeyHitCalibration(directory: nil)
        let body = CGRect(x: 100, y: 100, width: 40, height: 50)
        let outlier = CGPoint(x: body.midX + 100, y: body.midY)
        XCTAssertFalse(cal.learnCommittedTap(letter: "e", point: outlier, body: body, bucket: .portrait))
        let snap = cal.currentSnapshot()
        XCTAssertEqual(snap.summary.rejectedOutliers, 1)
        XCTAssertNil(snap.buckets[KeyHitCalibration.LayoutBucket.portrait.rawValue]?["e"])
    }

    func testNeighborCorrectionLearnsTrueOffset() {
        let cal = KeyHitCalibration(directory: nil)
        let bodyI = CGRect(x: 200, y: 100, width: 40, height: 50)
        let mistypedPoint = CGPoint(x: bodyI.midX + 9, y: bodyI.midY) // +0.225 * width
        for _ in 0..<40 {
            XCTAssertTrue(cal.learnNeighborCorrection(
                intendedLetter: "i",
                mistypedLetter: "o",
                mistypedPoint: mistypedPoint,
                intendedBody: bodyI,
                bucket: .portrait
            ))
        }
        let eff = cal.effectiveNormalizedOffset(for: "i", in: .portrait)
        XCTAssertEqual(eff.dx, 0.225 * (40.0 / 48.0), accuracy: 0.02)
        XCTAssertEqual(cal.currentSnapshot().summary.neighborFixSamples, 40)
    }

    @MainActor
    func testTouchSurfaceResolvesUsingCalibratedGaussianWithoutMovingVisualKey() {
        let surface = KeyboardTouchSurface(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let keyI = KeyboardKey(title: "i")
        keyI.correctionLetter = "i"
        let keyO = KeyboardKey(title: "o")
        keyO.correctionLetter = "o"
        let bodyI = CGRect(x: 20, y: 5, width: 40, height: 50)
        let bodyO = CGRect(x: 64, y: 5, width: 40, height: 50)
        surface.regions = [
            .init(key: keyI, body: bodyI, cell: CGRect(x: 0, y: 0, width: 62, height: 60)),
            .init(key: keyO, body: bodyO, cell: CGRect(x: 62, y: 0, width: 62, height: 60)),
        ]

        // Point at x=63 is in the gap (60..64), in O's cell.
        let edgePoint = CGPoint(x: 63, y: 30)
        XCTAssertTrue(surface.resolvedKey(at: edgePoint) === keyO)

        // Train 'i' with +0.22 * width rightward offset (+8.8 pt).
        let cal = KeyHitCalibration(directory: nil)
        let shifted = CGPoint(x: bodyI.midX + 8.8, y: bodyI.midY)
        for _ in 0..<60 {
            cal.learnCommittedTap(letter: "i", point: shifted, body: bodyI, bucket: .portrait)
        }
        surface.letterModel = { letter in
            cal.effectiveModel(for: letter, in: .portrait)
        }
        XCTAssertTrue(surface.resolvedKey(at: edgePoint) === keyI)
    }

    @MainActor
    func testRawKeyInnerAnchorZonePreventsSpatialOverride() {
        let surface = KeyboardTouchSurface(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let keyI = KeyboardKey(title: "i")
        keyI.correctionLetter = "i"
        let keyO = KeyboardKey(title: "o")
        keyO.correctionLetter = "o"
        let bodyI = CGRect(x: 20, y: 5, width: 40, height: 50)
        let bodyO = CGRect(x: 64, y: 5, width: 40, height: 50)
        surface.regions = [
            .init(key: keyI, body: bodyI, cell: CGRect(x: 0, y: 0, width: 62, height: 60)),
            .init(key: keyO, body: bodyO, cell: CGRect(x: 62, y: 0, width: 62, height: 60)),
        ]

        let cal = KeyHitCalibration(directory: nil)
        let shifted = CGPoint(x: bodyI.midX + 12, y: bodyI.midY)
        for _ in 0..<80 {
            cal.learnCommittedTap(letter: "i", point: shifted, body: bodyI, bucket: .portrait)
        }
        surface.letterModel = { cal.effectiveModel(for: $0, in: .portrait) }

        // Inside O's inner anchor zone (|nx| <= 0.35, midX=84 -> 70..98): must stay O.
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: 72, y: 30)) === keyO)
        // Outer edge of O's painted body (x=65): I is likelier, but not by the
        // margin a painted keycap needs, so it stays O.
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: 65, y: 30)) === keyO)
        // In the gap (x=63) the likelier calibrated I takes it.
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: 63, y: 30)) === keyI)
    }

    @MainActor
    func testWiderShiftedNeighbourDoesNotTakeTheKeycapEdge() {
        let surface = KeyboardTouchSurface(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let keyI = KeyboardKey(title: "i")
        keyI.correctionLetter = "i"
        let keyO = KeyboardKey(title: "o")
        keyO.correctionLetter = "o"
        let bodyI = CGRect(x: 20, y: 5, width: 40, height: 50)
        let bodyO = CGRect(x: 66, y: 5, width: 40, height: 50)
        surface.regions = [
            .init(key: keyI, body: bodyI, cell: CGRect(x: 0, y: 0, width: 63, height: 60)),
            .init(key: keyO, body: bodyO, cell: CGRect(x: 63, y: 0, width: 63, height: 60)),
        ]
        // A keyboard's stored statistics: o is tapped toward i and spreads
        // wider, i sits a little left of its center.
        let models: [Character: KeyHitCalibration.EffectiveModel] = [
            "i": .init(dx: -0.067, dy: -0.007, varX: 0.035, varY: 0.028, weight: 0.99, count: 843),
            "o": .init(dx: -0.123, dy: -0.042, varX: 0.047, varY: 0.027, weight: 0.98, count: 370),
        ]
        surface.letterModel = { models[$0]! }

        // Without the margin the boundary sat at nx ≈ 0.45, inside i's keycap.
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: bodyI.midX + 0.46 * bodyI.width, y: bodyI.midY)) === keyI)
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: bodyI.midX + 0.40 * bodyI.width, y: bodyI.midY)) === keyI)
    }

    @MainActor
    func testReassignedTapDoesNotLearnOnNormalCommit() {
        let view = KeyboardView(frame: CGRect(x: 0, y: 0, width: 390, height: 260))
        let cal = KeyHitCalibration(directory: nil)
        view.hitCalibration = cal
        let body = CGRect(x: 100, y: 100, width: 40, height: 50)

        // Simulate a tap reassigned by language prior (raw 'p' -> corrected 'o').
        view.recordCalibratedLetterTap(.init(
            letter: "o",
            rawLetter: "p",
            point: CGPoint(x: body.midX + 10, y: body.midY),
            body: body,
            calibrationSwitched: false,
            languageCorrected: true
        ))
        // Simulate a clean, unreassigned tap on 'n'.
        view.recordCalibratedLetterTap(.init(
            letter: "n",
            rawLetter: "n",
            point: CGPoint(x: body.midX + 4, y: body.midY),
            body: body,
            calibrationSwitched: false,
            languageCorrected: false
        ))

        // Commit a phrase: only unreassigned 'n' should learn; reassigned 'o' must NOT update stats.
        view.recordCalibrationEdits([.insert("你好")])

        let snap = cal.currentSnapshot()
        XCTAssertEqual(snap.summary.committedSamples, 1)
        XCTAssertNil(snap.buckets[view.hitCalibrationBucket.rawValue]?["o"])
        XCTAssertEqual(snap.buckets[view.hitCalibrationBucket.rawValue]?["n"]?.count, 1)
    }

    func testPersistenceRoundTrip() throws {
        let dir = tempDir()
        let cal = KeyHitCalibration(directory: dir)
        let body = CGRect(x: 0, y: 0, width: 40, height: 50)
        let pt = CGPoint(x: body.midX + 6, y: body.midY - 4)
        for _ in 0..<80 {
            cal.learnCommittedTap(letter: "n", point: pt, body: body, bucket: .portrait)
        }
        cal.recordTapOutcome(calibrationSwitched: true, languageCorrected: false)
        cal.flushSync()

        let reloaded = KeyHitCalibration(directory: dir)
        let eff = reloaded.effectiveNormalizedOffset(for: "n", in: .portrait)
        XCTAssertEqual(eff.dx, 0.15 * (80.0 / 88.0), accuracy: 0.02)
        XCTAssertEqual(eff.dy, -0.08 * (80.0 / 88.0), accuracy: 0.02)
        XCTAssertEqual(reloaded.currentSnapshot().summary.calibrationSwitches, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("observations.jsonl").path),
                       "No per-tap log is written")
    }

    @MainActor
    func testInterKeyIntervalScalesCorrectionReachAndResetsOnNonLetterOrLongPause() {
        let surface = KeyboardTouchSurface(frame: CGRect(x: 0, y: 0, width: 400, height: 60))
        let keyO = KeyboardKey(title: "o")
        keyO.correctionLetter = "o"
        let keyP = KeyboardKey(title: "p")
        keyP.correctionLetter = "p"
        let keySpace = KeyboardKey(title: " ")
        keySpace.accessibilityIdentifier = "vime.key.space"

        let bodyO = CGRect(x: 200, y: 10, width: 32, height: 42)
        let bodyP = CGRect(x: 238, y: 10, width: 32, height: 42)
        let bodySpace = CGRect(x: 100, y: 10, width: 60, height: 42)
        surface.regions = [
            .init(key: keySpace, body: bodySpace, cell: bodySpace),
            .init(key: keyO, body: bodyO, cell: CGRect(x: 195, y: 0, width: 40, height: 60)),
            .init(key: keyP, body: bodyP, cell: CGRect(x: 235, y: 0, width: 40, height: 60)),
        ]
        surface.letterPrior = { _ in KeyHitCorrection.romajiPrior(after: "ky") }

        var typed: [Character] = []
        keyO.action = { typed.append("o") }
        keyP.action = { typed.append("p") }

        var clock: TimeInterval = 50.0
        surface.pressNow = { clock }

        // Borderline tap on P: x = 249.5 is 17.5pt outside O.maxX (232).
        // Normalized distance dx = 17.5 / 32 / 0.45 = 1.215 (> 1.0 default, <= 1.12 fast reach: 1.215 / 1.12 = 1.08;
        // let's pick x = 247.5 -> 15.5pt outside O.maxX: 15.5 / 32 / 0.45 = 1.076:
        // - Under fast IKI (100ms, scale = 1.12): 1.076 / 1.12 = 0.96 <= 1.0 -> rescues to 'o'!
        // - Under slow IKI (450ms, scale = 0.78): 1.076 / 0.78 = 1.38 > 1.0 -> keeps 'p'!
        // - After Space or > 1s pause (nil IKI, scale = 1.0): 1.076 > 1.0 -> keeps 'p'!)
        let borderlinePoint = CGPoint(x: 247.5, y: 30)

        // Prime first letter tap at t = 50.0
        XCTAssertTrue(surface.beginPress(id: 1, at: CGPoint(x: bodyO.midX, y: bodyO.midY)))
        surface.endPress(id: 1, at: CGPoint(x: bodyO.midX, y: bodyO.midY))
        typed.removeAll()

        // 1. Fast follow-up letter (dt = 0.10s <= 0.14s): expanded reach rescues 'p' -> 'o'.
        clock += 0.10
        XCTAssertTrue(surface.beginPress(id: 2, at: borderlinePoint))
        surface.endPress(id: 2, at: borderlinePoint)
        XCTAssertEqual(typed, ["o"])
        typed.removeAll()

        // 2. Slow follow-up letter (dt = 0.45s >= 0.38s): contracted reach respects 'p'.
        clock += 0.45
        XCTAssertTrue(surface.beginPress(id: 3, at: borderlinePoint))
        surface.endPress(id: 3, at: borderlinePoint)
        XCTAssertEqual(typed, ["p"])
        typed.removeAll()

        // 3. Non-letter key (Space) resets IKI to nil even if next letter arrives 0.08s later.
        clock += 0.05
        XCTAssertTrue(surface.beginPress(id: 4, at: CGPoint(x: bodySpace.midX, y: bodySpace.midY)))
        surface.endPress(id: 4, at: CGPoint(x: bodySpace.midX, y: bodySpace.midY))
        clock += 0.08
        XCTAssertTrue(surface.beginPress(id: 5, at: borderlinePoint))
        surface.endPress(id: 5, at: borderlinePoint)
        XCTAssertEqual(typed, ["p"])
    }
}
