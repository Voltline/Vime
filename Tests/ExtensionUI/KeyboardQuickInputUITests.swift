import XCTest

@MainActor
final class KeyboardQuickInputUITests: XCTestCase {
    func testScrollableSymbolRailLinksToContainingAppSettings() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        for _ in 0..<6 {
            let back = settings.navigationBars.buttons["BackButton"]
            guard back.exists else { break }; back.tap()
        }
        settings.staticTexts["通用"].firstMatch.tap()
        settings.staticTexts["键盘"].firstMatch.tap()
        settings.buttons["KEYBOARDS"].tap()
        let vime = settings.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Vime'")).firstMatch
        if !vime.exists {
            settings.buttons.matching(NSPredicate(format: "label CONTAINS '添加新键盘'")).firstMatch.tap()
            XCTAssertTrue(vime.waitForExistence(timeout: 5)); vime.tap()
        }
        vime.tap()
        let access = settings.switches.firstMatch
        XCTAssertTrue(access.waitForExistence(timeout: 3))
        let originalAccess = access.value as? String == "1"
        if !originalAccess {
            access.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            if settings.alerts.firstMatch.waitForExistence(timeout: 2) { settings.alerts.firstMatch.buttons["允许"].tap() }
        }
        defer {
            if !originalAccess { settings.activate(); access.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        }
        let app = XCUIApplication(); app.launch()
        app.buttons["vime.home.focus"].tap()
        let brand = app.buttons["vime.brand.settings"]
        if !brand.waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
            for _ in 0..<12 {
                if brand.exists { break }; guard globe.exists else { break }
                globe.tap(); _ = brand.waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(brand.exists)
        brand.tap()
        app.segmentedControls["vime.setting.numbers"].buttons["九宫格"].tap()
        brand.tap()
        app.buttons["123"].tap()
        let rail = app.scrollViews["vime.numberSymbols"]
        XCTAssertTrue(rail.waitForExistence(timeout: 3))
        let before = app.textViews["vime.extension.editor"].value as? String
        let link = app.descendants(matching: .any)["vime.numberSymbols.edit"].firstMatch
        for _ in 0..<8 { if link.isHittable { break }; rail.swipeUp() }
        XCTAssertTrue(link.isHittable)
        XCTAssertEqual(app.textViews["vime.extension.editor"].value as? String, before,
            "Scrolling symbols must not insert text")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "实际扩展-符号栏与 App 入口"; screenshot.lifetime = .keepAlways; add(screenshot)
        link.tap()
        XCTAssertTrue(app.navigationBars["符号与括号"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vime.numberSymbols.add"].exists)
    }
    func testClipboardHistorySurvivesDismissalAndPastesInInstalledExtension() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        for _ in 0..<6 {
            let back = settings.navigationBars.buttons["BackButton"]
            guard back.exists else { break }
            back.tap()
        }
        settings.staticTexts["通用"].firstMatch.tap()
        settings.staticTexts["键盘"].firstMatch.tap()
        settings.buttons["KEYBOARDS"].tap()
        let vimeKeyboard = settings.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Vime'")).firstMatch
        // Reinstalling the containing app for unit tests can remove its enabled
        // keyboard entry. Register the actual installed extension through Settings.
        if !vimeKeyboard.exists {
            settings.buttons.matching(NSPredicate(format: "label CONTAINS '添加新键盘'")).firstMatch.tap()
            guard vimeKeyboard.waitForExistence(timeout: 5) else { XCTFail("Installed Vime keyboard is unavailable"); return }
            vimeKeyboard.tap()
        }
        vimeKeyboard.tap()
        let access = settings.switches.firstMatch
        XCTAssertTrue(access.waitForExistence(timeout: 3))
        let hadAccess = access.value as? String == "1"
        if !hadAccess {
            access.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            if settings.alerts.firstMatch.waitForExistence(timeout: 2) { settings.alerts.firstMatch.buttons["允许"].tap() }
        }
        XCTAssertEqual(access.value as? String, "1")
        defer {
            if !hadAccess { settings.activate(); access.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        }
        let app = XCUIApplication()
        func clipboardSetting(_ enabled: Bool) -> Bool {
            app.terminate(); app.launchArguments = []; app.launch()
            app.tabBars.buttons["设置"].tap()
            app.buttons["vime.settings.clipboard"].tap()
            let toggle = app.switches["vime.settings.clipboard.enabled"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            let previous = toggle.value as? String == "1"
            if previous != enabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                if enabled { app.alerts.firstMatch.buttons["了解并开启"].tap() }
            }
            return previous
        }
        let original = clipboardSetting(true)
        defer { _ = clipboardSetting(original) }
        app.terminate(); app.launchArguments = ["--keyboard-extension-test"]; app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
        let brand = app.buttons["vime.brand.settings"]
        if !brand.waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
            for _ in 0..<12 {
                if brand.exists { break }
                guard globe.exists else { break }
                globe.tap(); _ = brand.waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(brand.exists)
        if !app.buttons["ABC"].exists { app.buttons["123"].tap() }
        // Each run copies different real host events; persistent adjacent-text
        // suppression correctly hides an identical fixture on a second run.
        for digit in String(Int64(Date().timeIntervalSince1970 * 1000)) {
            app.buttons["vime.number.\(digit)"].tap()
        }
        app.buttons["vime.key.return"].tap()
        app.buttons["vime.extension.send"].tap()
        XCTAssertFalse(app.staticTexts["vime.extension.events"].label.isEmpty)
        // Copy through a real containing-app control; no test-only clipboard
        // injection or in-process KeyboardView stands in for the extension.
        app.buttons["ABC"].tap()
        let copiedAt = ProcessInfo.processInfo.systemUptime
        app.buttons["复制测试记录"].tap()
        let preview = app.buttons["vime.clipboard.paste"]
        guard preview.waitForExistence(timeout: 1.5) else {
            XCTFail("Clipboard changes should appear promptly through notification or short metadata fallback")
            return
        }
        print("Clipboard copy-to-preview UI observation: \(ProcessInfo.processInfo.systemUptime - copiedAt)s (includes XCTest tap/query overhead)")
        let expectedPreview = preview.label
        let suggestion = XCTAttachment(screenshot: app.screenshot())
        suggestion.name = "实际扩展-自动剪贴板预览"; suggestion.lifetime = .keepAlways; add(suggestion)
        app.buttons["vime.clipboard.dismiss"].tap()
        XCTAssertFalse(preview.exists, "Dismissal only hides the suggestion")
        app.buttons["vime.extension.dismiss"].tap()
        app.buttons["vime.extension.focus"].tap()
        XCTAssertTrue(brand.waitForExistence(timeout: 5))
        XCTAssertFalse(preview.exists, "The unchanged clipboard must not be offered after reopening")
        brand.tap()
        let quickSettings = XCTAttachment(screenshot: app.screenshot())
        quickSettings.name = "实际扩展-分组快捷设置"; quickSettings.lifetime = .keepAlways; add(quickSettings)
        let history = app.buttons["vime.setting.clipboardHistory"]
        if !history.isHittable { app.scrollViews["vime.settings"].swipeUp() }
        XCTAssertTrue(history.waitForExistence(timeout: 3)); history.tap()
        let table = app.tables["vime.clipboard.history.list"]
        XCTAssertTrue(table.cells.firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "实际扩展-剪贴板历史"; screenshot.lifetime = .keepAlways; add(screenshot)
        table.cells.firstMatch.tap()
        let inserted = NSPredicate { _, _ in
            guard let value = editor.value as? String else { return false }
            let rendered = String(String.UnicodeScalarView(value.unicodeScalars.prefix(160)))
                .replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\t", with: " ")
            return rendered == expectedPreview
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: inserted, object: editor)], timeout: 5), .completed)
        // A new real copy includes the insertion above in the host event log.
        // Observe the production 30-second lifetime; no test-only timeout in the extension.
        app.buttons["复制测试记录"].tap()
        guard preview.waitForExistence(timeout: 1.5) else { XCTFail("New copy should appear"); return }
        let expired = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !preview.exists }, object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 32), .completed,
            "An untouched clipboard suggestion must disappear after 30 seconds")
        brand.tap(); history.tap()
        XCTAssertTrue(table.cells.firstMatch.waitForExistence(timeout: 5), "Expiring the preview must preserve history")
    }

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
            app.buttons["vime.settings.symbols"].tap()
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
