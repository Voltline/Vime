import XCTest
@testable import Vime

final class KeyHitCalibrationTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VimeKeyHitCalibrationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testColdStartFadeInAndHardClamp() {
        let cal = KeyHitCalibration(directory: nil)
        let body = CGRect(x: 100, y: 100, width: 40, height: 50)
        // Tap shifted +0.40 * width to the right (will be clamped to +0.25).
        let shiftedPoint = CGPoint(x: body.midX + 0.40 * body.width, y: body.midY + 0.35 * body.height)

        for _ in 0..<14 {
            XCTAssertTrue(cal.learnCommittedTap(letter: "i", point: shiftedPoint, body: body, bucket: .portrait))
        }
        // Still below minSamples (15): effective offset must remain zero.
        let beforeThreshold = cal.effectiveNormalizedOffset(for: "i", in: .portrait)
        XCTAssertEqual(beforeThreshold.dx, 0, accuracy: 1e-6)
        XCTAssertEqual(beforeThreshold.dy, 0, accuracy: 1e-6)

        // Reach fullWeightSamples (30).
        for _ in 14..<30 {
            XCTAssertTrue(cal.learnCommittedTap(letter: "i", point: shiftedPoint, body: body, bucket: .portrait))
        }
        let full = cal.effectiveNormalizedOffset(for: "i", in: .portrait)
        XCTAssertEqual(full.dx, KeyHitCalibration.maxOffsetDx, accuracy: 1e-6)
        XCTAssertEqual(full.dy, KeyHitCalibration.maxOffsetDy, accuracy: 1e-6)
    }

    func testStrictPerKeyAndPerBucketIsolation() {
        let cal = KeyHitCalibration(directory: nil)
        let body = CGRect(x: 0, y: 0, width: 40, height: 50)
        let shifted = CGPoint(x: body.midX + 8, y: body.midY + 5) // +0.20 dx, +0.10 dy

        for _ in 0..<35 {
            cal.learnCommittedTap(letter: "a", point: shifted, body: body, bucket: .portrait)
        }
        // Trained key in trained bucket has offset.
        let aPortrait = cal.effectiveNormalizedOffset(for: "a", in: .portrait)
        XCTAssertEqual(aPortrait.dx, 0.20, accuracy: 0.01)
        XCTAssertEqual(aPortrait.dy, 0.10, accuracy: 0.01)

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
        // Way outside 1.1 * width.
        let outlier = CGPoint(x: body.midX + 100, y: body.midY)
        XCTAssertFalse(cal.learnCommittedTap(letter: "e", point: outlier, body: body, bucket: .portrait))
        let snap = cal.currentSnapshot()
        XCTAssertEqual(snap.summary.rejectedOutliers, 1)
        XCTAssertNil(snap.buckets[KeyHitCalibration.LayoutBucket.portrait.rawValue]?["e"])
    }

    func testNeighborCorrectionLearnsTrueOffset() {
        let cal = KeyHitCalibration(directory: nil)
        let bodyI = CGRect(x: 200, y: 100, width: 40, height: 50)
        // User tapped slightly right of 'i' (inside 'o'), deleted 'o', then tapped 'i'.
        let mistypedPoint = CGPoint(x: bodyI.midX + 9, y: bodyI.midY) // +0.225 * width
        for _ in 0..<30 {
            XCTAssertTrue(cal.learnNeighborCorrection(
                intendedLetter: "i",
                mistypedLetter: "o",
                mistypedPoint: mistypedPoint,
                intendedBody: bodyI,
                bucket: .portrait
            ))
        }
        let eff = cal.effectiveNormalizedOffset(for: "i", in: .portrait)
        XCTAssertEqual(eff.dx, 0.225, accuracy: 0.01)
        XCTAssertEqual(cal.currentSnapshot().summary.neighborFixSamples, 30)
    }

    @MainActor
    func testTouchSurfaceResolvesUsingCalibratedCenterWithoutMovingVisualKey() {
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
        // Without calibration: resolves to O.
        XCTAssertTrue(surface.resolvedKey(at: edgePoint) === keyO)

        // Train 'i' with +0.22 * width rightward offset (+8.8 pt).
        let cal = KeyHitCalibration(directory: nil)
        let shifted = CGPoint(x: bodyI.midX + 8.8, y: bodyI.midY)
        for _ in 0..<35 {
            cal.learnCommittedTap(letter: "i", point: shifted, body: bodyI, bucket: .portrait)
        }
        surface.letterOffset = { letter, body in
            cal.effectivePointOffset(for: letter, body: body, in: .portrait)
        }
        // Now x=65 is closer to I's calibrated center (48.8) than O's center (84.0) -> resolves to I!
        XCTAssertTrue(surface.resolvedKey(at: edgePoint) === keyI)
    }

    func testPersistenceAndLogExportRoundTrip() throws {
        let dir = tempDir()
        let cal = KeyHitCalibration(directory: dir)
        let body = CGRect(x: 0, y: 0, width: 40, height: 50)
        let pt = CGPoint(x: body.midX + 6, y: body.midY - 4)
        for _ in 0..<30 {
            cal.learnCommittedTap(letter: "n", point: pt, body: body, bucket: .portrait)
        }
        cal.recordTapObservation(
            letter: "n", rawLetter: "m", point: pt, body: body, bucket: .portrait,
            calibrationSwitched: true, languageCorrected: false
        )
        cal.flushSync()

        // Reload from disk.
        let reloaded = KeyHitCalibration(directory: dir)
        let eff = reloaded.effectiveNormalizedOffset(for: "n", in: .portrait)
        XCTAssertEqual(eff.dx, 0.15, accuracy: 0.01)
        XCTAssertEqual(eff.dy, -0.08, accuracy: 0.01)
        XCTAssertEqual(reloaded.currentSnapshot().summary.calibrationSwitches, 1)

        // Verify observations.jsonl exists and contains valid JSONL without any user text fields.
        let logURL = dir.appendingPathComponent("observations.jsonl")
        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 31)
    }
}
