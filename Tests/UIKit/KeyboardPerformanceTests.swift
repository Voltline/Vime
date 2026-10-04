import XCTest
import UIKit

@MainActor
final class KeyboardPerformanceTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    func testProfileNativeTouchPipelineAndLatestPrediction() async throws {
        let session = KeyboardSession(asynchronousCandidates: true)
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        keyboard.hasFullAccess = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        let input = UIInputView(frame: keyboard.frame, inputViewStyle: .keyboard)
        input.addSubview(keyboard)
        window.rootViewController?.view.addSubview(input)
        window.isHidden = false
        keyboard.layoutIfNeeded()
        let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        let hostView = UITextView(frame: CGRect(x: 0, y: 0, width: 440, height: 200))
        hostView.font = .systemFont(ofSize: 23)
        hostView.text = "前後"; hostView.selectedRange = NSRange(location: 1, length: 0)
        window.rootViewController?.view.addSubview(hostView)
        hostView.inputView = input
        hostView.becomeFirstResponder()
        let host = KeyboardHostConnection(setMarkedText: { hostView.setMarkedText($0, selectedRange: $1) },
            unmarkText: { hostView.unmarkText() }, insertText: { hostView.insertText($0) }, deleteBackward: { hostView.deleteBackward() })
        keyboard.onEdit = { host.apply($0) }
        keyboard.onMarkedTextChange = { host.updateMarkedText($0) }
        let published = expectation(description: "Latest burst prediction")
        let update = session.onCandidatesChange
        session.onCandidatesChange = { update?(); published.fulfill() }
        defer {
            session.onCandidatesChange = nil
            KeyboardPerformance.configure(enabled: false)
            keyboard.stopInteractions()
            window.isHidden = true
        }
        KeyboardPerformance.configure(enabled: true, reset: true)
        let raw = "watashihanihongowobenkyoushiteimasu"
        for (id, c) in raw.enumerated() {
            let region = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key." + String(c) })
            // Alternate center/gap presses with a small drift at release, using
            // the SAME state transitions called by native UIKit touch events.
            let x = id.isMultiple(of: 2) ? region.body.midX : region.cell.minX + 0.5
            let point = CGPoint(x: x, y: region.body.midY)
            XCTAssertTrue(surface.beginPress(id: id, at: point))
            XCTAssertTrue(region.key.isHighlighted, "Feedback changes immediately on touch down")
            surface.endPress(id: id, at: CGPoint(x: point.x + 3, y: point.y + 2))
            XCTAssertEqual(host.markedText, session.preedit)
            XCTAssertEqual(session.candidateRequestCount, id + 1)
        }
        XCTAssertEqual(session.raw, raw)
        XCTAssertEqual(hostView.text, "前わたしはにほんごをべんきょうしています後")
        await fulfillment(of: [published], timeout: 10)
        XCTAssertEqual(session.candidates.first, "私は日本語を勉強しています")
        // Also allow candidate publications BETWEEN fast keys, rather than
        // verifying only a burst which finishes before any background result.
        keyboard.resetComposition()
        hostView.text = "前後"; hostView.selectedRange = NSRange(location: 1, length: 0)
        let paced = expectation(description: "Latest prediction after interleaved keys/results")
        session.onCandidatesChange = {
            update?()
            if session.raw == raw { paced.fulfill() }
        }
        for (id, c) in raw.enumerated() {
            let region = try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key." + String(c) })
            let point = CGPoint(x: region.body.midX, y: region.body.midY)
            XCTAssertTrue(surface.beginPress(id: id, at: point))
            surface.endPress(id: id, at: point)
            XCTAssertEqual(host.markedText, session.preedit)
            XCTAssertEqual(session.candidateRequestCount, raw.count + id + 1)
            try await Task.sleep(for: .milliseconds(20))
        }
        await fulfillment(of: [paced], timeout: 10)
        XCTAssertEqual(session.raw, raw)
        XCTAssertEqual(hostView.text, "前わたしはにほんごをべんきょうしています後")
        XCTAssertEqual(session.candidates.first, "私は日本語を勉強しています")
        let report = KeyboardPerformance.report()
        for stage in KeyboardPerformance.Stage.allCases { XCTAssertNotNil(report[stage.rawValue], stage.rawValue) }
        XCTAssertEqual(report["typeToMarked"]?["count"], Double(raw.count * 2))
        XCTAssertGreaterThan(report["candidatePublication"]?["count"] ?? 0, 2)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("INPUT_PIPELINE_PROFILE " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "input-pipeline-profile"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testWarmContinuousCandidateUpdates() async throws {
        let session = KeyboardSession(asynchronousCandidates: true)
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        keyboard.hasFullAccess = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(keyboard)
        window.isHidden = false
        keyboard.layoutIfNeeded()
        let view = UITextView(frame: CGRect(x: 0, y: 0, width: 440, height: 180)); view.font = .systemFont(ofSize: 23)
        window.rootViewController?.view.addSubview(view)
        let host = KeyboardHostConnection(setMarkedText: { view.setMarkedText($0, selectedRange: $1) },
            unmarkText: { view.unmarkText() }, insertText: { view.insertText($0) }, deleteBackward: { view.deleteBackward() })
        keyboard.onEdit = { host.apply($0) }; keyboard.onMarkedTextChange = { host.updateMarkedText($0) }
        let update = session.onCandidatesChange
        defer { session.onCandidatesChange = nil; KeyboardPerformance.configure(enabled: false); window.isHidden = true }
        let words = ["nihongo", "nani", "nanim", "nanimo", "arigat"]
        // First pass warms dictionary, glyphs, text rendering, and candidate views.
        // The next three identical passes are measured, in an attached window.
        for pass in 0..<4 {
          if pass == 1 { KeyboardPerformance.configure(enabled: true, reset: true) }
          for word in words {
            keyboard.resetComposition()
            for c in word {
                let ready = expectation(description: "\(word) \(c)")
                session.onCandidatesChange = { update?(); ready.fulfill() }
                let key = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.key." + String(c) } as? UIButton)
                key.sendActions(for: .touchUpInside)
                XCTAssertEqual(host.markedText, session.preedit)
                await fulfillment(of: [ready], timeout: 10)
            }
          }
        }
        let report = KeyboardPerformance.report()
        XCTAssertEqual(report["candidatePublication"]?["count"], 84)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("WARM_CANDIDATE_PROFILE " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "warm-candidate-profile"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
