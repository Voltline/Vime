import XCTest

/// The shortcut slider must be verified in the actual system keyboard process.
@MainActor
final class KeyboardFeedbackUITests: XCTestCase {
    func testThreeSnapPointsInInstalledKeyboardQuickSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test"]
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
        if !app.buttons["vime.brand.settings"].waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Next keyboard", "下一键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
            for _ in 0..<6 {
                if app.buttons["vime.brand.settings"].exists { break }
                guard globe.exists else { break }
                globe.tap(); _ = app.buttons["vime.brand.settings"].waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(app.buttons["vime.brand.settings"].exists, "Vime extension must be enabled for this test")
        app.buttons["vime.brand.settings"].tap()
        let slider = app.sliders["vime.setting.haptics"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        // Drag actual screen coordinates: the accessibility helper can assign
        // the native slider value after the touch has ended on recent iOS.
        func drag(to position: CGFloat) {
            let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = slider.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        for (position, expected) in [(0.02, "关闭"), (0.58, "中 · 60%"), (0.6, "中 · 60%"), (0.98, "强 · 100%")] {
            drag(to: position)
            print("HAPTIC expected=\(expected) ax=\(String(describing: slider.value)) label=\(app.staticTexts["vime.setting.hapticValue"].label)")
            XCTAssertEqual(slider.value as? String, expected)
        }
        drag(to: 0.427)
        let intermediate = try XCTUnwrap(slider.value as? String)
        XCTAssertFalse(["关闭", "中 · 60%", "强 · 100%"].contains(intermediate))
        drag(to: 0.6)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Actual keyboard feedback settings"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
