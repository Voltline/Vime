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

        // Point at x=65 is inside O's painted body (64..104) by 1pt.
        let edgePoint = CGPoint(x: 65, y: 30)
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
        // Outer edge of O (x=65 -> |nx| = 0.475 > 0.35): allowed to resolve to calibrated I.
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: 65, y: 30)) === keyI)
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

    func testPersistenceAndLogExportRoundTrip() throws {
        let dir = tempDir()
        let cal = KeyHitCalibration(directory: dir)
        let body = CGRect(x: 0, y: 0, width: 40, height: 50)
        let pt = CGPoint(x: body.midX + 6, y: body.midY - 4)
        for _ in 0..<80 {
            cal.learnCommittedTap(letter: "n", point: pt, body: body, bucket: .portrait)
        }
        cal.recordTapObservation(
            letter: "n", rawLetter: "m", point: pt, body: body, bucket: .portrait,
            calibrationSwitched: true, languageCorrected: false
        )
        cal.flushSync()

        let reloaded = KeyHitCalibration(directory: dir)
        let eff = reloaded.effectiveNormalizedOffset(for: "n", in: .portrait)
        XCTAssertEqual(eff.dx, 0.15 * (80.0 / 88.0), accuracy: 0.02)
        XCTAssertEqual(eff.dy, -0.08 * (80.0 / 88.0), accuracy: 0.02)
        XCTAssertEqual(reloaded.currentSnapshot().summary.calibrationSwitches, 1)

        let logURL = dir.appendingPathComponent("observations.jsonl")
        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 81)
    }
}
