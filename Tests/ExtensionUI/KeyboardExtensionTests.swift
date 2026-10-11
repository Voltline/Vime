import XCTest

/// Runs the installed extension through iOS, never the app's KeyboardSandbox.
@MainActor
final class KeyboardExtensionTests: XCTestCase {
    func testExpandedPartialSelectionKeepsHostMarkedRange() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test"]
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        defer {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Actual extension and host state"
            attachment.lifetime = .keepAlways
            add(attachment)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.lifetime = .keepAlways
            add(image)
        }
        if !app.buttons["vime.key.t"].waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format:
                "label IN %@", ["Next keyboard", "下一键盘", "切换系统键盘", "次のキーボード"] as NSArray))
            for _ in 0..<6 {
                guard !app.buttons["vime.key.t"].exists, globe.firstMatch.exists else { break }
                globe.firstMatch.tap()
                _ = app.buttons["vime.key.t"].waitForExistence(timeout: 1)
            }
        }
        guard app.buttons["vime.key.t"].exists else {
            XCTFail("Vime extension is not selected/enabled. Actual UI: \(app.debugDescription)")
            return
        }
        for char in "tennanhantenn" { app.buttons["vime.key.\(char)"].tap() }
        app.buttons["vime.candidates.expand"].tap()
        func select(_ surface: String) throws {
            let label = "候选词：\(surface)"
            let candidate = app.buttons.matching(NSPredicate(format:
                "label == %@ OR label BEGINSWITH %@", label, label + "，")).firstMatch
            _ = candidate.waitForExistence(timeout: 3)
            // The real menu loads pages on scroll; app-hosted tests previously
            // scrolled these offscreen candidates through a UIKit fixture.
            let panel = app.scrollViews["vime.candidates.panel"]
            for _ in 0..<20 {
                if candidate.exists && candidate.isHittable {
                    var previousFrame: CGRect?
                    let stable = NSPredicate { _, _ in
                        guard candidate.exists && candidate.isHittable else { previousFrame = nil; return false }
                        let frame = candidate.frame
                        defer { previousFrame = frame }
                        return previousFrame == frame
                    }
                    // A touch during UIScrollView deceleration stops scrolling
                    // rather than selecting; wait for a stationary target.
                    if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: candidate)], timeout: 3) == .completed { break }
                }
                guard panel.exists else { break }
                let frame = candidate.exists ? candidate.frame : .zero
                print("MENU \(surface) target=\(frame) viewport=\(panel.frame)")
                if frame.isEmpty { panel.swipeUp() }
                else {
                    let height = panel.frame.height
                    let delta = max(-height * 0.45, min(height * 0.45, frame.midY - panel.frame.midY))
                    let startY = delta > 0 ? 0.75 : 0.25
                    // Drag in the empty edge gutter and hold before release,
                    // avoiding both button tracking and an inertial page jump.
                    let start = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: startY))
                    let end = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: startY - delta / height))
                    start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
                }
            }
            guard candidate.exists && candidate.isHittable else {
                XCTFail("Missing \(surface): \(app.debugDescription)")
                throw NSError(domain: "VimeExtensionUITests.MissingCandidate", code: 1)
            }
            candidate.tap()
        }
        func expect(_ text: String, mark: String) {
            let value = NSPredicate(format: "value == %@", text)
            let matched = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: value, object: editor)], timeout: 5)
            XCTAssertEqual(matched, .completed, "Actual document: \(editor.value ?? "nil")")
            XCTAssertEqual(app.staticTexts["vime.extension.marked"].label, "待确认文本：\(mark)")
            print("HOST \(editor.value ?? "nil"); \(app.staticTexts["vime.extension.marked"].label)")
            print(app.staticTexts["vime.extension.events"].label)
        }
        try select("天")
        expect("天あんはんてん", mark: "あんはんてん")
        try select("安")
        expect("天安はんてん", mark: "はんてん")
        try select("飯店")
        expect("天安飯店", mark: "无")
        // Check ordinary preedit editing and final commit on the same actual
        // extension after segmented conversion, without changing input rules.
        for char in "desu" { app.buttons["vime.key.\(char)"].tap() }
        app.buttons["vime.key.delete"].tap()
        expect("天安飯店で", mark: "で")
        app.buttons["vime.key.s"].tap()
        app.buttons["vime.key.u"].tap()
        app.buttons["vime.key.return"].tap()
        expect("天安飯店です", mark: "无")
    }
}
