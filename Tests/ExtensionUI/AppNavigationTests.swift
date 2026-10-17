import XCTest

/// Exercises the installed SwiftUI App, not the HTML design prototype.
@MainActor
final class AppNavigationTests: XCTestCase {
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
        app.buttons["vime.settings.setup"].tap()
        XCTAssertTrue(app.navigationBars["启用键盘"].waitForExistence(timeout: 3))
        capture(app, "Setup guide")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["vime.settings.feedback"].tap()
        let slider = app.sliders["vime.setting.haptics"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        slider.adjust(toNormalizedSliderPosition: 0.62)
        let value = try XCTUnwrap(slider.value as? String)
        XCTAssertEqual(value, "中 · 60%")
        capture(app, "Feedback")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["vime.settings.privacy"].tap()
        capture(app, "Data and privacy overview")
        app.buttons["vime.privacy.clipboard"].tap()
        XCTAssertTrue(app.navigationBars["剪贴板"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.staticTexts["一、信息处理的基本原则"].exists)
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
