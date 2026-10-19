import XCTest

/// Exercises the installed SwiftUI App, not the HTML design prototype.
@MainActor
final class AppNavigationTests: XCTestCase {
    func testFeedbackSliderRightwardDragsDoNotNavigateBack() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["设置"].tap()
        app.buttons["vime.settings.feedback"].tap()
        let page = app.navigationBars["手感与布局"]
        let slider = app.sliders["vime.setting.haptics"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        // Exercise immediate pans from the thumb.
        // A long press before dragging can mask the content-back gesture race.
        for velocity in [XCUIGestureVelocity.slow, .fast] {
            slider.adjust(toNormalizedSliderPosition: 0)
            // Start on the thumb and cross the end, ensuring a clamped maximum
            // independently of UIKit's thumb padding and drag pickup offset.
            slider.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5))
                .press(forDuration: 0.01, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 1.1, dy: 0.5)),
                       withVelocity: velocity, thenHoldForDuration: 0)
            XCTAssertTrue(page.exists, "Dragging the slider right must keep the settings page open")
            XCTAssertEqual(slider.value as? String, "强 · 100%")
        }
        capture(app, "Feedback slider after rightward pans")
        // Navigation outside the slider must retain its normal edge-back action.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(app.navigationBars["键盘设置"].waitForExistence(timeout: 3))
        app.buttons["vime.settings.feedback"].tap()
        XCTAssertEqual(slider.value as? String, "强 · 100%", "The drag must persist after returning to the page")
    }

    func testNumberSymbolAdditionPersistsAndCanBeDeletedInApp() throws {
        let app = XCUIApplication(); app.launch()
        func openSymbols() {
            app.tabBars.buttons["设置"].tap()
            app.buttons["vime.settings.input"].tap()
            let entry = app.buttons["vime.settings.numberSymbols"]
            if !entry.isHittable { app.swipeUp() }
            entry.tap()
            XCTAssertTrue(app.navigationBars["常用符号"].waitForExistence(timeout: 3))
        }
        openSymbols()
        let symbol = "§" + String(Int.random(in: 100...999))
        let add = app.buttons["vime.numberSymbols.add"]
        for _ in 0..<6 { if add.isHittable { break }; app.swipeUp() }
        add.tap()
        let alert = app.alerts["添加符号"]
        alert.textFields.firstMatch.tap(); alert.textFields.firstMatch.typeText(symbol)
        alert.buttons["添加"].tap()
        app.terminate(); app.launch()
        openSymbols()
        let item = app.staticTexts["vime.numberSymbols.item." + symbol]
        for _ in 0..<6 { if item.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(item.exists)
        capture(app, "App 常用符号编辑")
        item.swipeLeft()
        app.buttons["删除"].tap()
        XCTAssertFalse(item.exists)
    }
    func testTabsFeedbackPrivacyAndOfflineLicenseNavigation() throws {
        let app = XCUIApplication(); app.launch()
        defer {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "App navigation result"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertTrue(app.navigationBars["键盘试打"].waitForExistence(timeout: 10))
        capture(app, "Home")
        app.tabBars.buttons["定制"].tap()
        XCTAssertTrue(app.navigationBars["定制"].waitForExistence(timeout: 3))
        capture(app, "Customization")
        for _ in 0..<10 {
            if app.buttons["创建皮肤"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["创建皮肤"].isHittable)
        app.buttons["创建皮肤"].tap()
        XCTAssertTrue(app.navigationBars["编辑皮肤"].waitForExistence(timeout: 3))
        app.buttons["取消"].tap()
        app.tabBars.buttons["设置"].tap()
        capture(app, "Settings")
        app.buttons["vime.settings.setup"].tap()
        XCTAssertTrue(app.navigationBars["启用键盘"].waitForExistence(timeout: 3))
        capture(app, "Setup guide")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["vime.settings.feedback"].tap()
        let slider = app.sliders["vime.setting.haptics"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        // Initialise the thumb, then use an actual drag to verify release snapping.
        slider.adjust(toNormalizedSliderPosition: 0)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.5)))
        let value = try XCTUnwrap(slider.value as? String)
        XCTAssertEqual(value, "中 · 60%")
        capture(app, "Feedback")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["vime.settings.privacy"].tap()
        capture(app, "Data and privacy overview")
        app.buttons["vime.privacy.clipboard"].tap()
        XCTAssertTrue(app.navigationBars["剪贴板"].waitForExistence(timeout: 3))
        capture(app, "Clipboard")
        app.buttons["vime.clipboard.instructions"].tap()
        XCTAssertTrue(app.staticTexts["使用方式"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["vime.privacy.dictionary"].tap()
        XCTAssertTrue(app.navigationBars["用户词典"].waitForExistence(timeout: 3))
        capture(app, "User dictionary")
        app.buttons["添加词条"].tap()
        XCTAssertTrue(app.navigationBars["词条"].waitForExistence(timeout: 3))
        capture(app, "Dictionary entry editor")
        app.buttons["取消"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["vime.privacy.policy"].tap()
        XCTAssertTrue(app.navigationBars["隐私政策"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.scrollViews["vime.privacy.document"].exists)
        XCTAssertTrue(app.staticTexts["一、我们如何处理您的信息"].exists)
        capture(app, "Privacy")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["vime.settings.about"].tap()
        capture(app, "About Vime")
        app.buttons["vime.about.licenses"].tap()
        XCTAssertTrue(app.navigationBars["开源组件与许可"].waitForExistence(timeout: 3))
        capture(app, "Licenses")
        app.buttons["vime.license.azookey"].tap()
        XCTAssertTrue(app.staticTexts["vime.license.notice"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["vime.license.notice"].label.contains("MIT License"))
    }
    func testSkinSelectionUpdatesPreviewAndSurvivesReturningToTab() throws {
        let app = XCUIApplication(); app.launch()
        app.tabBars.buttons["定制"].tap()
        let ocean = app.buttons["vime.skin.builtin.ocean"]
        ocean.tap()
        XCTAssertEqual(ocean.value as? String, "当前使用")
        XCTAssertEqual(app.staticTexts["vime.skin.currentName"].label, "海蓝")
        app.buttons["vime.skin.builtin.sakura"].tap()
        XCTAssertEqual(app.buttons["vime.skin.builtin.sakura"].value as? String, "当前使用")
        XCTAssertEqual(ocean.value as? String, "")
        capture(app, "Plain skin selection rows")

        let create = app.buttons["创建皮肤"]
        for _ in 0..<10 { if create.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(create.isHittable); create.tap()
        let field = app.textFields["vime.skin.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let suffix = "-\(Int(Date().timeIntervalSince1970))"
        field.tap(); field.typeText(suffix)
        let name = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(name.hasSuffix(suffix))
        app.buttons["保存"].tap()
        let custom = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                      "vime.skin.custom.", name)).firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 3))
        custom.tap()
        XCTAssertEqual(custom.value as? String, "当前使用")
        for _ in 0..<10 {
            if app.staticTexts["vime.skin.currentName"].isHittable { break }
            app.swipeDown()
        }
        XCTAssertEqual(app.staticTexts["vime.skin.currentName"].label, name)
        capture(app, "Selected custom skin preview")
        app.tabBars.buttons["设置"].tap(); app.tabBars.buttons["定制"].tap()
        XCTAssertEqual(app.staticTexts["vime.skin.currentName"].label, name)

        // Remove only the skin created through the real editor in this test
        let actions = app.buttons[name + "的操作"]
        for _ in 0..<10 { if actions.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(actions.isHittable); actions.tap()
        app.buttons["删除"].tap()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 3))
        app.buttons["删除"].tap()
        XCTAssertFalse(custom.exists)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
