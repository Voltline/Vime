import XCTest

/// Uses the installed extension in a separate process. Every round resigns
/// first responder, verifies disappearance, then focuses and types again.
@MainActor
final class KeyboardExtensionLifecycleTests: XCTestCase {
    func testLandscapeMinimumHeightShowsAndTypesCompleteBottomRow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-height", "0.85"]
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
            app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-height", "1"]
            app.launch()
        }
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.buttons["vime.key.h"].waitForExistence(timeout: 5))
        for round in 1...3 {
            XCUIDevice.shared.orientation = round == 2 ? .landscapeRight : .landscapeLeft
            let space = app.buttons["vime.key.space"]
            let enter = app.buttons["vime.key.return"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: enter)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            XCTAssertTrue(space.isHittable)
            for key in [space, enter] {
                XCTAssertTrue(app.frame.contains(key.frame))
                XCTAssertGreaterThanOrEqual(key.frame.height, 33)
                XCTAssertLessThanOrEqual(key.frame.maxY, app.frame.maxY - 36,
                    "The full key must remain above the system footer")
            }
            let previous = editor.value as? String ?? ""
            app.buttons["vime.key.a"].tap()
            space.tap()
            enter.tap()
            XCTAssertEqual(editor.value as? String, previous + "あ")
            XCTAssertEqual(app.staticTexts["vime.extension.marked"].label, "待确认文本：无")
            // The first return confirms the conversion; the second inserts a newline.
            enter.tap()
            XCTAssertEqual(editor.value as? String, previous + "あ\n")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "landscape-minimum-height-round-\(round)"
            attachment.lifetime = .keepAlways; add(attachment)
            XCUIDevice.shared.orientation = .portrait
            app.buttons["vime.extension.dismiss"].tap()
            XCTAssertTrue(app.buttons["vime.key.h"].waitForNonExistence(timeout: 5))
            app.buttons["vime.extension.clear"].tap()
            XCTAssertEqual(editor.value as? String, "")
            app.buttons["vime.extension.focus"].tap()
            XCTAssertTrue(app.buttons["vime.key.h"].waitForExistence(timeout: 5))
        }
    }

    func testThreeHundredConstantContextOpenCloseCycles() throws {
        try exercise(ranking: "languageModel", cycles: 300, clearDocument: true)
    }

    func testSixtyConstantContextOpenCloseCycles() throws {
        try exercise(ranking: "languageModel", cycles: 60, clearDocument: true)
    }

    func testThirtyLanguageModelOpenCloseCycles() throws {
        try exercise(ranking: "languageModel", cycles: 30)
    }

    func testTenDictionaryOpenCloseCycles() throws {
        try exercise(ranking: "engine", cycles: 10)
    }

    func testTwentyFourMixedFeatureOpenCloseCycles() throws {
        try exercise(ranking: "languageModel", cycles: 24, mixedFeatures: true)
    }

    private func exercise(ranking: String, cycles: Int, clearDocument: Bool = false, mixedFeatures: Bool = false) throws {
        continueAfterFailure = false
        executionTimeAllowance = 3_600
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-ranking", ranking,
            "--v21-extension-audit-on", "--v21-extension-audit-duration-seconds", "3600",
            "--v21-extension-audit-sample-ms", "1000", "--v21-extension-audit-write-ms", "5000",
            "--v21-extension-audit-run-id", "lifecycle-\(cycles)-" + ranking]
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        if !app.buttons["vime.key.h"].waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
            for _ in 0..<6 {
                guard !app.buttons["vime.key.h"].exists, globe.exists else { break }
                globe.tap()
                _ = app.buttons["vime.key.h"].waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(app.buttons["vime.key.h"].exists, "The actual extension must be enabled in this simulator")
        let began = ProcessInfo.processInfo.systemUptime
        for cycle in 1...cycles {
            XCTAssertTrue(app.buttons["vime.key.h"].exists, "Vime was replaced before cycle \(cycle)")
            let previous = editor.value as? String ?? ""
            let readings = [("hashi", "はし"), ("nihongo", "にほんご"),
                ("ashitanokaiginisankashimasu", "あしたのかいぎにさんかします"), ("tennanhantenn", "てんあんはんてん")]
            // The long run measures creation/teardown. Warm the neural model
            // with an ambiguous reading first, then keep each round short and
            // identical; the mixed run separately stresses richer input.
            let (roman, kana) = mixedFeatures ? readings[(cycle - 1) % readings.count]
                : (cycles >= 300 && cycle > 1 ? ("a", "あ") : readings[0])
            print("VIME_EXTENSION_PHASE cycle=\(cycle) phase=typing seconds=\(Int(ProcessInfo.processInfo.systemUptime - began))")
            for character in roman { app.buttons["vime.key.\(character)"].tap() }
            XCTAssertEqual(editor.value as? String, previous + kana)
            if mixedFeatures {
                print("VIME_EXTENSION_PHASE cycle=\(cycle) phase=candidate_panel seconds=\(Int(ProcessInfo.processInfo.systemUptime - began))")
                app.buttons["vime.candidates.expand"].tap()
                let panel = app.scrollViews["vime.candidates.panel"]
                XCTAssertTrue(panel.waitForExistence(timeout: 3))
                panel.swipeUp()
                app.buttons["vime.panel.close"].tap()
            }
            if roman != "a" { app.buttons["vime.key.space"].tap() }
            app.buttons["vime.key.return"].tap()
            XCTAssertNotEqual(editor.value as? String, previous)
            XCTAssertEqual(app.staticTexts["vime.extension.marked"].label, "待确认文本：无")
            if mixedFeatures && cycle.isMultiple(of: 4) {
                print("VIME_EXTENSION_PHASE cycle=\(cycle) phase=symbol_panel seconds=\(Int(ProcessInfo.processInfo.systemUptime - began))")
                app.buttons["表情"].tap()
                let modes = app.segmentedControls["vime.symbols.mode"]
                XCTAssertTrue(modes.waitForExistence(timeout: 3))
                modes.buttons["颜文字"].tap()
                modes.buttons["符号"].tap()
                app.buttons["vime.symbols.close"].tap()
            }
            let committed = editor.value as? String
            app.buttons["vime.extension.dismiss"].tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                object: app.buttons["vime.key.h"])
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed,
                "Cycle \(cycle) must really close the extension")
            XCTAssertEqual(editor.value as? String, committed)
            if clearDocument {
                // Hold the prompt length constant to distinguish lifecycle
                // growth from Core ML workspaces for progressively longer text.
                app.buttons["vime.extension.clear"].tap()
                XCTAssertEqual(editor.value as? String, "")
            }
            if mixedFeatures && cycle.isMultiple(of: 6) {
                XCUIDevice.shared.orientation = cycle.isMultiple(of: 12) ? .portrait : .landscapeLeft
            }
            app.buttons["vime.extension.focus"].tap()
            // Do not switch back using the globe after initial setup: fallback
            // to the native keyboard is a failure, not a recoverable test step.
            XCTAssertTrue(app.buttons["vime.key.h"].waitForExistence(timeout: 5),
                "Vime did not reopen at cycle \(cycle)")
            XCTAssertEqual(editor.value as? String, clearDocument ? "" : committed, "Reopening must preserve the host document")
            print("VIME_EXTENSION_LIFECYCLE ranking=\(ranking) constant_context=\(clearDocument) cycle=\(cycle) seconds=\(Int(ProcessInfo.processInfo.systemUptime - began))")
        }
        app.buttons["vime.extension.dismiss"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "lifecycle-" + ranking + "-completed"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
