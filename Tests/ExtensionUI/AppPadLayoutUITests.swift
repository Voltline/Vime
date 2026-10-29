import XCTest

/// Walks the app's pages on iPad in both orientations so every page can be
/// checked for full-width stretching and clipped content.
@MainActor
final class AppPadLayoutUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = true
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    func testPagesStayReadableInPortraitAndLandscape() throws {
        let app = XCUIApplication(); app.launch()
        for (orientation, label) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(tab(app, "试打").waitForExistence(timeout: 10))
            tab(app, "试打").tap()
            capture(app, "Home \(label)")
            assertReadable(app, "Home \(label)")

            tab(app, "定制").tap()
            XCTAssertTrue(app.navigationBars["定制"].waitForExistence(timeout: 3))
            capture(app, "Customization \(label)")
            let create = app.buttons["创建皮肤"]
            for _ in 0..<10 { if create.isHittable { break }; app.swipeUp() }
            if create.isHittable {
                create.tap()
                XCTAssertTrue(app.navigationBars["编辑皮肤"].waitForExistence(timeout: 3))
                capture(app, "Skin editor \(label)")
                app.buttons["取消"].tap()
            }

            tab(app, "设置").tap()
            XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
            capture(app, "Settings \(label)")
            assertReadable(app, "Settings \(label)")
            for (id, name) in [("vime.settings.setup", "Setup"), ("vime.settings.feedback", "Feedback"),
                               ("vime.settings.symbols", "Symbols"), ("vime.settings.about", "About")] {
                open(app, id)
                capture(app, "\(name) \(label)")
                back(app)
            }
            let height = app.buttons["vime.settings.height"]
            open(app, "vime.settings.feedback")
            for _ in 0..<6 { if height.isHittable { break }; app.swipeUp() }
            if height.isHittable {
                height.tap()
                XCTAssertTrue(app.navigationBars["键盘高度"].waitForExistence(timeout: 3))
                capture(app, "Keyboard height \(label)")
                app.navigationBars["键盘高度"].buttons.firstMatch.tap()
            }
            back(app)
            open(app, "vime.settings.privacy")
            capture(app, "Privacy overview \(label)")
            for (id, name) in [("vime.privacy.clipboard", "Clipboard"), ("vime.privacy.dictionary", "Dictionary"),
                               ("vime.privacy.policy", "Privacy policy")] {
                open(app, id)
                capture(app, "\(name) \(label)")
                back(app)
            }
            back(app)
        }
    }

    private func tab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.exists ? bar : app.buttons.matching(identifier: name).firstMatch
    }

    private func open(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons[identifier]
        for _ in 0..<6 { if button.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(button.isHittable, identifier); button.tap()
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.element(boundBy: 0).buttons.element(boundBy: 0).tap()
    }

    /// Text runs never span the whole screen on iPad.
    private func assertReadable(_ app: XCUIApplication, _ page: String) {
        let width = app.windows.firstMatch.frame.width
        for text in app.staticTexts.allElementsBoundByIndex.prefix(40) where text.isHittable {
            XCTAssertLessThanOrEqual(text.frame.width, 720, "\(page): \(text.label)")
        }
        XCTAssertGreaterThan(width, 700)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        // The screen shot, unlike the app's, keeps landscape pages whole.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
