import XCTest

@MainActor
final class KeyboardQuickInputUITests: XCTestCase {
    func testClipboardSettingRequiresExplicitConsentAndSupportsCancellation() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout: 10))
        app.tabBars.buttons["设置"].tap()
        app.buttons["vime.settings.clipboard"].tap()
        let toggle = app.switches["vime.settings.clipboard.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        let originallyEnabled = toggle.value as? String == "1"
        defer {
            if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons["取消"].tap() }
            if toggle.exists, (toggle.value as? String == "1") != originallyEnabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                if originallyEnabled { app.alerts.firstMatch.buttons["了解并开启"].tap() }
            }
        }
        if originallyEnabled { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let alert = app.alerts["开启自动读取剪贴板？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["取消"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["了解并开启"].tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "剪贴板开关授权完成"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testBracketPairPlacesCaretInsideAndSettingDisablesCompletion() throws {
        let app = XCUIApplication()
        func setPairing(_ enabled: Bool) -> Bool {
            app.terminate(); app.launchArguments = []; app.launch()
            app.tabBars.buttons["设置"].tap()
            app.buttons["vime.settings.input"].tap()
            let toggle = app.switches["vime.settings.autoPairBrackets"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            let previous = toggle.value as? String == "1"
            if previous != enabled { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
            return previous
        }
        let original = setPairing(true)
        defer { _ = setPairing(original) }
        for enabled in [true, false] {
            if !enabled { _ = setPairing(false) }
            app.terminate(); app.launchArguments = ["--keyboard-extension-test"]; app.launch()
            let editor = app.textViews["vime.extension.editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
            XCTAssertTrue(app.buttons["vime.brand.settings"].waitForExistence(timeout: 5))
            if !app.buttons["ABC"].exists { app.buttons["123"].tap() }
            app.buttons["vime.quickSymbol.("].tap()
            if enabled {
                XCTAssertEqual(editor.value as? String, "()")
                app.buttons["vime.quickSymbol.("].tap()
                app.buttons["vime.number.1"].tap()
                XCTAssertEqual(editor.value as? String, "((1))", "Input must stay inside nested pairs")
                XCTAssertEqual(app.staticTexts["vime.extension.marked"].label, "待确认文本：1")
            } else {
                XCTAssertEqual(editor.value as? String, "(")
                app.buttons["vime.number.1"].tap()
                XCTAssertEqual(editor.value as? String, "(1")
            }
        }
    }

    func testBothCalculationChoicesReplaceExpressionInInstalledExtension() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test"]
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
        defer {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "实际扩展计算结果"; screenshot.lifetime = .keepAlways; add(screenshot)
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "实际扩展状态"; state.lifetime = .keepAlways; add(state)
        }
        if !app.buttons["vime.brand.settings"].waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
            for _ in 0..<12 {
                if app.buttons["vime.brand.settings"].exists { break }
                guard globe.exists else { break }
                globe.tap(); _ = app.buttons["vime.brand.settings"].waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(app.buttons["vime.brand.settings"].exists, "Vime must be selected")
        if !app.buttons["ABC"].exists { app.buttons["123"].tap() }
        func one() -> XCUIElement {
            let nineKey = app.buttons["vime.number.1"]
            return nineKey.exists ? nineKey : app.buttons["1"].firstMatch
        }
        for (index, expression, expected) in [(0, "1+1", "2"), (1, "1+1", "1+1=2"), (0, "12+34", "46")] {
            app.buttons["vime.extension.send"].tap()
            one().tap()
            if expression == "12+34" { app.buttons["vime.number.2"].tap() }
            let plus = app.buttons["vime.number.+"]
            if plus.exists { plus.tap() }
            else {
                app.buttons["#+="].tap()
                app.buttons["+"].firstMatch.tap()
                app.buttons["123"].tap()
            }
            if expression == "12+34" {
                app.buttons["vime.number.3"].tap(); app.buttons["vime.number.4"].tap()
            } else { one().tap() }
            let result = app.buttons["vime.calculation.\(index)"]
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            XCTAssertEqual(editor.value as? String, expression)
            result.tap()
            let matched = NSPredicate { _, _ in editor.value as? String == expected }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matched, object: editor)], timeout: 5), .completed)
            XCTAssertEqual(app.staticTexts["vime.extension.marked"].label, "待确认文本：无")

        }
    }
}
