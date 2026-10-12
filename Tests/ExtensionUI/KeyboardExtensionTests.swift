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
                "label IN %@", ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray))
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
            var settled = false
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
                    if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: stable, object: candidate)], timeout: 3) == .completed {
                        settled = true
                        break
                    }
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
            guard settled && candidate.exists && candidate.isHittable else {
                XCTFail("Missing or moving \(surface): \(app.debugDescription)")
                throw NSError(domain: "VimeExtensionUITests.MissingCandidate", code: 1)
            }
            candidate.tap()
        }
        func expect(_ text: String, mark: String) throws {
            // Refresh both accessibility queries on each poll. The old KVC
            // predicate could time out while the next editor snapshot already
            // showed the expected text; keep the same five-second limit.
            let value = NSPredicate { _, _ in
                app.textViews["vime.extension.editor"].value as? String == text &&
                app.staticTexts["vime.extension.marked"].label == "待确认文本：\(mark)"
            }
            let matched = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: value, object: editor)], timeout: 5)
            guard matched == .completed else {
                XCTFail("Host acknowledgement timed out: document=\(String(reflecting: editor.value)); mark=\(String(reflecting: app.staticTexts["vime.extension.marked"].label))")
                throw NSError(domain: "VimeExtensionUITests.HostAcknowledgement", code: 1)
            }
            XCTAssertEqual(editor.value as? String, text)
            XCTAssertEqual(app.staticTexts["vime.extension.marked"].label, "待确认文本：\(mark)")
            print("HOST \(editor.value ?? "nil"); \(app.staticTexts["vime.extension.marked"].label)")
            print(app.staticTexts["vime.extension.events"].label)
        }
        try select("天")
        try expect("天あんはんてん", mark: "あんはんてん")
        try select("安")
        try expect("天安はんてん", mark: "はんてん")
        try select("飯店")
        try expect("天安飯店", mark: "无")
        // Check ordinary preedit editing and final commit on the same actual
        // extension after segmented conversion, without changing input rules.
        for char in "desu" { app.buttons["vime.key.\(char)"].tap() }
        app.buttons["vime.key.delete"].tap()
        try expect("天安飯店で", mark: "で")
        app.buttons["vime.key.s"].tap()
        app.buttons["vime.key.u"].tap()
        app.buttons["vime.key.return"].tap()
        try expect("天安飯店です", mark: "无")
        // Exercise conversion cancellation through the installed extension too.
        // XCTest taps do not guarantee the pending-request timing; the real
        // worker unit tests separately cover multiple spaces before delivery.
        for char in "kan" { app.buttons["vime.key.\(char)"].tap() }
        app.buttons["vime.key.space"].tap()
        app.buttons["vime.key.delete"].tap()
        try expect("天安飯店ですかn", mark: "かn")
        app.buttons["vime.key.a"].tap()
        app.buttons["vime.key.return"].tap()
        try expect("天安飯店ですかな", mark: "无")
        // Select native width variants through the real extension's menu.
        // Opening it must preserve the host's current marked range.
        for char in "gakkou" { app.buttons["vime.key.\(char)"].tap() }
        app.buttons["vime.candidates.expand"].tap()
        try expect("天安飯店ですかながっこう", mark: "がっこう")
        try select("ｶﾞｯｺｳ")
        try expect("天安飯店ですかなｶﾞｯｺｳ", mark: "无")
        for char in "abc" { app.buttons["vime.key.\(char)"].tap() }
        app.buttons["vime.candidates.expand"].tap()
        try expect("天安飯店ですかなｶﾞｯｺｳあbc", mark: "あbc")
        try select("ａｂｃ")
        try expect("天安飯店ですかなｶﾞｯｺｳａｂｃ", mark: "无")
    }
}
