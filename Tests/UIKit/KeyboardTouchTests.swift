import XCTest
import UIKit

@MainActor
final class KeyboardTouchTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func makeKeyboard(width: CGFloat = 440, compact: Bool = false) -> (KeyboardView, KeyboardTouchSurface) {
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: width, height: 350))
        keyboard.compact = compact
        keyboard.frame.size.height = keyboard.preferredHeight(for: width)
        keyboard.layoutIfNeeded()
        return (keyboard, descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first!)
    }

    func testBodiesGapsToolbarAndEdgesAcrossLayouts() throws {
        for (width, compact) in [(CGFloat(440), false), (CGFloat(375), false), (CGFloat(680), true)] {
            let (keyboard, surface) = makeKeyboard(width: width, compact: compact)
            let metrics = KeyboardMetrics(width: width, compact: compact, showsFooter: true)
            for region in surface.regions {
                let center = CGPoint(x: region.body.midX, y: region.body.midY)
                XCTAssertTrue(surface.resolvedKey(at: center) === region.key)
                XCTAssertTrue(keyboard.hitTest(center, with: nil) === surface)
                // The painted corners, not just the center, remain anchored.
                for point in [CGPoint(x: region.body.minX + 0.1, y: region.body.minY + 0.1),
                              CGPoint(x: region.body.maxX - 0.1, y: region.body.maxY - 0.1)] {
                    XCTAssertTrue(surface.resolvedKey(at: point) === region.key)
                }
            }
            let first = try XCTUnwrap(surface.regions.first)
            XCTAssertNil(surface.resolvedKey(at: CGPoint(x: 20, y: first.cell.minY - 0.1)))
            XCTAssertNotNil(surface.resolvedKey(at: CGPoint(x: 20, y: first.cell.minY + 0.1)))
            XCTAssertNil(surface.resolvedKey(at: CGPoint(x: 20, y: keyboard.bounds.height + 1)))
            let settings = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "键盘设置" && !$0.isHidden })
            XCTAssertTrue(keyboard.hitTest(settings.convert(CGPoint(x: settings.bounds.midX, y: settings.bounds.midY), to: keyboard), with: nil) === settings)
            // Exhaustively sample the key plane: every gap/edge pixel has exactly
            // one cell owner, including staggered rows and wide bottom keys.
            var y = first.cell.minY + 0.25
            while y < keyboard.bounds.height {
                var x: CGFloat = 0.25
                while x < width {
                    let point = CGPoint(x: x, y: y)
                    XCTAssertEqual(surface.regions.filter { $0.cell.contains(point) }.count, 1)
                    XCTAssertNotNil(surface.resolvedKey(at: point))
                    let hit = keyboard.hitTest(point, with: nil)
                    XCTAssertTrue(hit === surface || hit is UIControl,
                                  "Every point must reach a key surface or a real toolbar/globe control")
                    x += 3
                }
                y += 3
            }
            XCTAssertTrue(keyboard.hitTest(CGPoint(x: width / 2, y: 3), with: nil) === surface)
            XCTAssertTrue(keyboard.hitTest(CGPoint(x: width / 2, y: metrics.headerHeight - 3), with: nil) === surface)
            XCTAssertTrue(keyboard.hitTest(CGPoint(x: width / 2, y: keyboard.bounds.height - 3), with: nil) === surface)
        }
    }

    func testLetterPlaneHasZeroUnresolvedPointsOnTwoPointGrid() {
        var total = 0
        var unresolved = 0
        var nonunique = 0
        var misrouted = 0
        var wrongBodyOwner = 0
        for (width, compact) in [(CGFloat(375), false), (CGFloat(440), false), (CGFloat(680), true)] {
            let (keyboard, surface) = makeKeyboard(width: width, compact: compact)
            keyboard.showsFooter = false
            keyboard.frame.size.height = keyboard.preferredHeight(for: width)
            keyboard.layoutIfNeeded()
            let metrics = KeyboardMetrics(width: width, compact: compact, showsFooter: false)
            let top = metrics.headerHeight
            let bottom = (top + 2 * metrics.rowStep + metrics.keyHeight + top + 3 * metrics.rowStep) / 2
            var count = 0
            // Include both indented rows' side margins and every horizontal /
            // vertical key gap. Third-row shift/delete are valid owners too.
            for y in stride(from: top, to: bottom, by: 2) {
                for x in stride(from: CGFloat.zero, to: width, by: 2) {
                    let point = CGPoint(x: x, y: y)
                    let owner = surface.resolvedKey(at: point)
                    if owner == nil { unresolved += 1 }
                    if surface.regions.filter({ $0.cell.contains(point) }).count != 1 { nonunique += 1 }
                    if keyboard.hitTest(point, with: nil) !== surface { misrouted += 1 }
                    if let body = surface.regions.first(where: { $0.body.contains(point) }), owner !== body.key { wrongBodyOwner += 1 }
                    count += 1
                }
            }
            total += count
            print("LETTER_TOUCH_COVERAGE width=\(width) compact=\(compact) step=2 samples=\(count)")
        }
        print("LETTER_TOUCH_COVERAGE total=\(total) unresolved=\(unresolved) nonunique=\(nonunique) misrouted=\(misrouted) wrongBodyOwner=\(wrongBodyOwner)")
        XCTAssertEqual(unresolved, 0)
        XCTAssertEqual(nonunique, 0)
        XCTAssertEqual(misrouted, 0)
        XCTAssertEqual(wrongBodyOwner, 0)
    }

    func testRollingTapsDoNotBecomeSymbolsButDeliberateFlickStillWorks() throws {
        for width: CGFloat in [375, 440, 680] {
            let (_, surface) = makeKeyboard(width: width)
            let q = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.q" })
            let w = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.w" })
            let center = CGPoint(x: q.body.midX, y: q.body.midY)
            let up = CGPoint(x: center.x, y: center.y - 32 * surface.scale)
            var output = ""
            q.key.action = { output += "q" }; q.key.alternateAction = { output += "!" }; q.key.feedback = {}
            w.key.action = { output += "w" }; w.key.feedback = {}
            // The last lift-off coordinate cannot introduce an unpreviewed symbol.
            surface.beginPress(id: 1, at: center); surface.endPress(id: 1, at: up)
            XCTAssertEqual(output, "q")
            let diagonal = CGPoint(x: center.x + 24 * surface.scale, y: center.y - 29 * surface.scale)
            surface.beginPress(id: 2, at: center); surface.movePress(id: 2, to: diagonal)
            surface.endPress(id: 2, at: diagonal); XCTAssertEqual(output, "qq")
            // A bottom-to-top roll that remains in the painted key is still a tap.
            let bottom = CGPoint(x: center.x, y: q.body.maxY - 1)
            let rolled = CGPoint(x: bottom.x, y: bottom.y - 29 * surface.scale)
            surface.beginPress(id: 3, at: bottom); surface.movePress(id: 3, to: rolled)
            surface.endPress(id: 3, at: rolled); XCTAssertEqual(output, "qqq")
            // Explicit upward movement shows the alternate, retains a little reversal,
            // and commits only on release. Distance scales with the keyboard.
            surface.beginPress(id: 4, at: center); surface.movePress(id: 4, to: up)
            XCTAssertEqual(output, "qqq")
            let reversed = CGPoint(x: center.x, y: center.y - 24 * surface.scale)
            surface.endPress(id: 4, at: reversed); XCTAssertEqual(output, "qqq!")
            let next = CGPoint(x: w.body.midX, y: w.body.midY)
            surface.beginPress(id: 5, at: center); surface.beginPress(id: 6, at: next)
            surface.movePress(id: 5, to: diagonal); surface.endPress(id: 5, at: diagonal)
            surface.endPress(id: 6, at: next); XCTAssertEqual(output, "qqq!qw")
        }
        // Exercise the real composition action, rather than just substituted callbacks.
        let session = KeyboardSession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        keyboard.layoutIfNeeded()
        let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        var edits: [KeyboardEdit] = []; keyboard.onEdit = { edits += $0 }
        for (index, character) in "nihongo".enumerated() {
            let region = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key." + String(character) })
            let center = CGPoint(x: region.body.midX, y: region.body.midY)
            surface.beginPress(id: index, at: center)
            surface.endPress(id: index, at: CGPoint(x: center.x, y: center.y - 32))
        }
        XCTAssertEqual(session.composition, "にほんご")
        XCTAssertTrue(edits.isEmpty, "A rolling tap must not confirm composition and insert punctuation")
    }

    func testStickyReleaseNeighborCorrectionSwipeAndCancellation() throws {
        let (_, surface) = makeKeyboard()
        let q = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.q" })
        let w = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.w" })
        var committed: [String] = []
        var feedback = 0
        q.key.action = { committed.append("q") }; w.key.action = { committed.append("w") }
        q.key.alternateAction = { committed.append("1") }
        q.key.feedback = { feedback += 1 }; w.key.feedback = { feedback += 1 }
        let boundaryStart = CGPoint(x: q.cell.maxX - 1, y: q.body.midY)
        let justOutside = CGPoint(x: q.cell.maxX + 3, y: q.body.midY)
        XCTAssertFalse(q.key.point(inside: q.key.convert(justOutside, from: surface), with: nil),
                       "This release would have taken the old touchUpOutside path")
        XCTAssertTrue(surface.beginPress(id: 1, at: boundaryStart))
        XCTAssertTrue(q.key.isHighlighted)
        XCTAssertEqual(feedback, 1)
        surface.movePress(id: 1, to: justOutside)
        XCTAssertTrue(q.key.isHighlighted)
        surface.endPress(id: 1, at: justOutside)
        XCTAssertEqual(committed, ["q"])
        XCTAssertFalse(q.key.isHighlighted)

        let qCenter = CGPoint(x: q.body.midX, y: q.body.midY)
        let wCenter = CGPoint(x: w.body.midX, y: w.body.midY)
        surface.beginPress(id: 2, at: qCenter)
        surface.movePress(id: 2, to: wCenter)
        XCTAssertFalse(q.key.isHighlighted)
        XCTAssertTrue(w.key.isHighlighted)
        surface.endPress(id: 2, at: wCenter)
        XCTAssertEqual(committed, ["q", "w"])

        surface.beginPress(id: 3, at: qCenter)
        surface.movePress(id: 3, to: CGPoint(x: qCenter.x, y: qCenter.y - 30))
        surface.movePress(id: 3, to: CGPoint(x: qCenter.x + 12, y: qCenter.y - 30))
        XCTAssertEqual(committed.count, 2, "Swipe does not commit before release")
        surface.endPress(id: 3, at: CGPoint(x: qCenter.x + 12, y: qCenter.y - 30))
        XCTAssertEqual(committed, ["q", "w", "1"])
        // After an alternate swipe, returning down into a neighbor cancels the
        // alternate selection, but cannot transfer ownership to that neighbor.
        surface.beginPress(id: 4, at: qCenter)
        surface.movePress(id: 4, to: CGPoint(x: qCenter.x, y: qCenter.y - 30))
        surface.endPress(id: 4, at: wCenter)
        XCTAssertEqual(committed.last, "q")

        surface.beginPress(id: 5, at: qCenter)
        surface.endPress(id: 5, at: qCenter, cancelled: true)
        XCTAssertEqual(committed.count, 4)
        surface.beginPress(id: 6, at: qCenter)
        surface.cancelAllPresses()
        surface.endPress(id: 6, at: qCenter)
        XCTAssertEqual(committed.count, 4)
        XCTAssertFalse(q.key.isHighlighted)
        surface.beginPress(id: 7, at: qCenter)
        surface.endPress(id: 7, at: CGPoint(x: -80, y: qCenter.y))
        XCTAssertEqual(committed.count, 4, "Dragging far outside the keyboard cancels instead of expanding hitboxes indefinitely")
        let edgePoint = CGPoint(x: 1, y: qCenter.y)
        surface.beginPress(id: 8, at: edgePoint)
        surface.endPress(id: 8, at: CGPoint(x: -3, y: edgePoint.y))
        XCTAssertEqual(committed.last, "q", "Small edge drift retains its owner")
    }

    func testRapidOverlappingTouchesDoNotDropOrDuplicateKeys() throws {
        let (_, surface) = makeKeyboard()
        let q = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.q" })
        let w = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.w" })
        let qPoint = CGPoint(x: q.body.midX, y: q.body.midY)
        let wPoint = CGPoint(x: w.body.midX, y: w.body.midY)
        var output = ""
        q.key.action = { output += "q" }; w.key.action = { output += "w" }
        q.key.feedback = {}; w.key.feedback = {}
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<100 {
            surface.beginPress(id: i * 2, at: qPoint)
            surface.beginPress(id: i * 2 + 1, at: wPoint)
            surface.endPress(id: i * 2, at: CGPoint(x: qPoint.x + 4, y: qPoint.y + 4))
            surface.endPress(id: i * 2 + 1, at: wPoint)
        }
        XCTAssertEqual(output, String(repeating: "qw", count: 100))
        print("Touch resolver: 200 overlapping key presses in \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms (excludes converter/host)")
    }

    func testOverlappingTouchesOnSameKeyKeepIndependentSwipeAndFeedback() throws {
        let (_, surface) = makeKeyboard()
        let q = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.q" })
        let center = CGPoint(x: q.body.midX, y: q.body.midY)
        let up = CGPoint(x: center.x, y: center.y - 30)
        var output = ""
        q.key.action = { output += "q" }
        q.key.alternateAction = { output += "1" }
        q.key.feedback = {}
        surface.beginPress(id: 1, at: center)
        surface.movePress(id: 1, to: up)
        surface.beginPress(id: 2, at: center)
        surface.endPress(id: 2, at: center)
        XCTAssertEqual(output, "q", "A stationary finger must not inherit another finger's swipe")
        XCTAssertTrue(q.key.isHighlighted, "The first finger still holds this key")
        surface.endPress(id: 1, at: up)
        XCTAssertEqual(output, "q1")
        XCTAssertFalse(q.key.isHighlighted)

        surface.beginPress(id: 3, at: center)
        surface.beginPress(id: 4, at: center)
        surface.movePress(id: 3, to: up)
        surface.endPress(id: 4, at: center, cancelled: true)
        XCTAssertTrue(q.key.isHighlighted, "Cancelling one finger must not clear the other finger's feedback")
        surface.endPress(id: 3, at: up)
        XCTAssertEqual(output, "q11")
    }

    func testGapDriftDoesNotRetargetOnRelease() throws {
        for width: CGFloat in [375, 440] {
            let (_, surface) = makeKeyboard(width: width)
            let q = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.q" })
            let w = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.w" })
            var output = ""
            q.key.action = { output += "q" }; w.key.action = { output += "w" }
            q.key.feedback = {}; w.key.feedback = {}
            // A release is not a deliberate drag correction. Starting in the
            // gap and rolling 12 pt into the adjacent key must retain its owner.
            let start = CGPoint(x: q.cell.maxX - 0.5, y: q.body.midY)
            let end = CGPoint(x: start.x + 12 * surface.scale, y: start.y)
            surface.beginPress(id: 1, at: start)
            surface.endPress(id: 1, at: end)
            XCTAssertEqual(output, "q")
            surface.beginPress(id: 2, at: start)
            surface.movePress(id: 2, to: end)
            XCTAssertTrue(q.key.isHighlighted, "A small drift during tracking must also retain its gap owner")
            surface.endPress(id: 2, at: end)
            XCTAssertEqual(output, "qq")
        }
    }

    func testOverlappingDeleteTouchesCannotLeaveAnOrphanedRepeatTimer() async throws {
        let (keyboard, surface) = makeKeyboard()
        let delete = try XCTUnwrap(surface.regions.first { $0.key.repeats })
        let center = CGPoint(x: delete.body.midX, y: delete.body.midY)
        var deletions = 0
        delete.key.action = { deletions += 1 }; delete.key.feedback = {}
        defer { keyboard.stopInteractions(); delete.key.stopTracking() }
        surface.beginPress(id: 1, at: center)
        surface.beginPress(id: 2, at: center)
        XCTAssertEqual(deletions, 0, "A short press waits for release so upward deletion can take ownership")
        surface.endPress(id: 1, at: center)
        XCTAssertTrue(delete.key.isHighlighted)
        surface.endPress(id: 2, at: center)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(deletions, 2, "No timer may restart deletion after both fingers have released")
        delete.key.action = { [weak surface] in deletions += 1; surface?.cancelAllPresses() }
        surface.beginPress(id: 3, at: center)
        XCTAssertTrue(delete.key.isHighlighted)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(delete.key.isHighlighted)
        XCTAssertEqual(deletions, 3, "A host callback cancelling touch down must not schedule a new repeat")
    }

    func testEveryExactBoundaryAndIntersectionReachesSurfaceAcrossPages() throws {
        for (width, compact, footer) in [(CGFloat(375), false, false), (CGFloat(440), false, true), (CGFloat(680), true, false)] {
            let (keyboard, surface) = makeKeyboard(width: width, compact: compact)
            keyboard.showsFooter = footer
            keyboard.frame.size.height = keyboard.preferredHeight(for: width)
            let oldNumbers = keyboard.preferences.nineKeyNumbers
            defer { keyboard.preferences.nineKeyNumbers = oldNumbers }
            for page in 0..<4 {
                if page == 1 || page == 3 {
                    if page == 3 {
                        let abc = try XCTUnwrap(surface.regions.first { $0.key.title(for: .normal) == "ABC" }?.key)
                        abc.sendActions(for: .touchUpInside)
                    }
                    keyboard.preferences.nineKeyNumbers = page == 1
                    let numbers = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardKey }.first { $0.title(for: .normal) == "123" })
                    numbers.sendActions(for: .touchUpInside)
                } else if page == 2 {
                    let symbols = try XCTUnwrap(surface.regions.first { $0.key.title(for: .normal) == "#+=" }?.key)
                    symbols.sendActions(for: .touchUpInside)
                }
                keyboard.layoutIfNeeded()
                let keyTop = KeyboardMetrics(width: width, compact: compact, showsFooter: footer).headerHeight
                for region in surface.regions {
                    for boundaryX in [region.cell.minX, region.cell.maxX] {
                        for boundaryY in [region.cell.minY, region.cell.maxY, region.body.midY] {
                            for x in [boundaryX.nextDown, boundaryX, boundaryX.nextUp] {
                                for y in [boundaryY.nextDown, boundaryY, boundaryY.nextUp] {
                                    let point = CGPoint(x: x, y: y)
                                    guard keyboard.bounds.contains(point), y >= keyTop else { continue }
                                    XCTAssertNotNil(surface.resolvedKey(at: point), "Unowned point \(point), width \(width), page \(page)")
                                    let hit = keyboard.hitTest(point, with: nil)
                                    XCTAssertTrue(hit === surface || hit is UIControl, "Dead hit at \(point), width \(width), page \(page)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testCandidateDividerDoesNotSwallowAnOtherwiseOwnedTouch() throws {
        let (keyboard, surface) = makeKeyboard()
        let q = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.q" })
        let center = CGPoint(x: q.body.midX, y: q.body.midY)
        surface.beginPress(id: 1, at: center)
        surface.endPress(id: 1, at: center)
        keyboard.layoutIfNeeded()
        let divider = try XCTUnwrap(keyboard.subviews.first { !$0.isHidden && $0.frame.width == 0.5 })
        let point = CGPoint(x: divider.frame.midX, y: divider.frame.midY)
        XCTAssertNotNil(surface.resolvedKey(at: point))
        XCTAssertTrue(keyboard.hitTest(point, with: nil) === surface,
                      "A decorative divider has no action and must not consume a key-owned point")
    }

    func testRenderedKeyGapsHaveBackingForSystemExtensionTouchDelivery() throws {
        for (width, compact) in [(CGFloat(375), false), (CGFloat(440), false), (CGFloat(680), true)] {
            let (keyboard, surface) = makeKeyboard(width: width, compact: compact)
            // Ordinary hitTest/Press tests bypass the extension host's rendered
            // transparency gate. Render our layers WITHOUT UIInputView's system
            // material, which is outside the extension's own rendered surface.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3; format.opaque = false; format.preferredRange = .standard
            let image = UIGraphicsImageRenderer(bounds: keyboard.bounds, format: format).image {
                keyboard.layer.render(in: $0.cgContext)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            func alpha(at point: CGPoint, from rendered: CGImage) throws -> UInt8 {
                let pixel = try XCTUnwrap(rendered.cropping(to: CGRect(x: floor(point.x * 3), y: floor(point.y * 3), width: 1, height: 1)))
                var rgba = [UInt8](repeating: 0, count: 4)
                try rgba.withUnsafeMutableBytes { data in
                    let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                return rgba[3]
            }
            let regions = surface.regions
            var gapPoints: [CGPoint] = []
            for region in regions {
                if let right = regions.first(where: { $0.body.minY == region.body.minY && $0.body.minX > region.body.minX }) {
                    gapPoints.append(CGPoint(x: (region.body.maxX + right.body.minX) / 2, y: region.body.midY))
                }
                if let below = regions.first(where: { $0.body.minY > region.body.minY }) {
                    gapPoints.append(CGPoint(x: region.body.midX, y: (region.body.maxY + below.body.minY) / 2))
                }
            }
            for point in gapPoints {
                XCTAssertNotNil(surface.resolvedKey(at: point))
                XCTAssertTrue(keyboard.hitTest(point, with: nil) === surface)
                XCTAssertGreaterThan(try alpha(at: point, from: cgImage), 0, "Transparent rendered gap at \(point), width \(width) can be rejected BEFORE UIKit hitTest")
            }
            XCTAssertEqual(surface.alpha, 1, "Backing must not fade keys or their labels")
            // Reproduce the original rendering while keeping the identical
            // resolver: the horizontal gap still resolves, but its pixel is 0.
            let gap = try XCTUnwrap(gapPoints.first)
            let backing = surface.backgroundColor
            surface.backgroundColor = .clear
            let before = UIGraphicsImageRenderer(bounds: keyboard.bounds, format: format).image {
                keyboard.layer.render(in: $0.cgContext)
            }
            surface.backgroundColor = backing
            XCTAssertNotNil(surface.resolvedKey(at: gap))
            XCTAssertEqual(try alpha(at: gap, from: XCTUnwrap(before.cgImage)), 0)
            print("RENDERED_TOUCH_GAPS width=\(width) checked=\(gapPoints.count) baselineAlpha=0 fixedAlpha=\(try alpha(at: gap, from: cgImage))")
        }
    }

#if DEBUG
    func testTouchDiagnosticsDistinguishResolverAndUIButtonLifecycles() throws {
        let (keyboard, surface) = makeKeyboard()
        let q = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.q" })
        q.key.action = {}; q.key.feedback = {}
        let oldEnabled = KeyboardTouchDiagnostics.enabled
        let oldSink = KeyboardTouchDiagnostics.sink
        var log: [String] = []
        KeyboardTouchDiagnostics.setEnabled(true)
        KeyboardTouchDiagnostics.sink = { log.append($0) }
        defer {
            KeyboardTouchDiagnostics.setEnabled(oldEnabled)
            KeyboardTouchDiagnostics.sink = oldSink
        }
        let gap = CGPoint(x: q.cell.maxX - 0.5, y: q.body.midY)
        XCTAssertTrue(keyboard.hitTest(gap, with: nil) === surface)
        surface.beginPress(id: 1, at: gap)
        surface.endPress(id: 1, at: CGPoint(x: gap.x + 3, y: gap.y))
        _ = q.key.point(inside: .zero, with: nil)
        q.key.sendActions(for: .touchUpInside)
        q.key.sendActions(for: .touchUpOutside)
        for stage in ["KeyboardView.hitTest", "container.hitTest", "KeyboardKey.pointInside",
                      "surface.touchDown", "KeyboardKey.touchDown", "surface.touchUp", "KeyboardKey.resolvedRelease",
                      "KeyboardKey.touchUpInside", "KeyboardKey.touchUpOutside"] {
            XCTAssertTrue(log.contains { $0.contains(stage) }, "Missing diagnostic stage \(stage)")
        }
        XCTAssertFalse(log.contains { $0.contains("vime.key.q") }, "Logs must not record typed characters or labels")
    }
#endif

    func testNumberLayoutSwitchPanelAndRepeatCancellation() async throws {
        let (keyboard, surface) = makeKeyboard()
        keyboard.preferences.nineKeyNumbers = true
        let numbers = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardKey }.first { $0.title(for: .normal) == "123" })
        numbers.sendActions(for: .touchUpInside)
        // Hit testing itself flushes pending layout before resolving a fast tap.
        let center = CGPoint(x: 120, y: 80)
        XCTAssertTrue(keyboard.hitTest(center, with: nil) === surface)
        let one = try XCTUnwrap(surface.resolvedKey(at: center))
        XCTAssertEqual(one.accessibilityIdentifier, "vime.number.1")
        let delete = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key.delete" })
        let deletePoint = CGPoint(x: delete.body.midX, y: delete.body.midY)
        var deletions = 0
        delete.key.action = { deletions += 1 }; delete.key.feedback = {}
        surface.beginPress(id: 1, at: deletePoint)
        XCTAssertEqual(deletions, 0, "A short delete commits on release so a line swipe can take ownership")
        surface.endPress(id: 1, at: deletePoint)
        try await Task.sleep(for: .milliseconds(510))
        XCTAssertEqual(deletions, 1, "Release stops delayed repeat")
        surface.beginPress(id: 2, at: deletePoint)
        let settings = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "键盘设置" && !$0.isHidden } as? UIButton)
        settings.sendActions(for: .touchUpInside)
        XCTAssertFalse(delete.key.isHighlighted)
        XCTAssertFalse(keyboard.hitTest(center, with: nil) === surface, "A settings panel owns its own touches")
        try await Task.sleep(for: .milliseconds(510))
        XCTAssertEqual(deletions, 1, "Opening a panel cancels a held delete before it commits")
    }
}
