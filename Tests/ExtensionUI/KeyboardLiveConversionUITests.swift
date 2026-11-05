import XCTest

/// Live conversion (ライブ変換) in the installed extension, through the host's
/// own marked text: what the host shows is what Return commits.
@MainActor
final class KeyboardLiveConversionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() async throws {
        if let app {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Final host state"; image.lifetime = .keepAlways
            add(image)
        }
        try await super.tearDown()
    }

    private func launch(live: Bool) throws {
        app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-ranking", "engine"]
            + (live ? ["--keyboard-extension-test-live-conversion"] : [])
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        // Vime's keys carry the keyboard-key trait, so XCTest lists them as keys.
        if !app.keys["vime.key.t"].waitForExistence(timeout: 5) {
            let globe = app.buttons.matching(NSPredicate(format:
                "label IN %@", ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray))
            for _ in 0..<6 {
                guard !app.keys["vime.key.t"].exists, globe.firstMatch.exists else { break }
                globe.firstMatch.tap()
                _ = app.keys["vime.key.t"].waitForExistence(timeout: 1)
            }
        }
        guard app.keys["vime.key.t"].exists else {
            XCTFail("Vime extension is not selected/enabled. Actual UI: \(app.debugDescription)")
            throw XCTSkip("Vime extension is not enabled")
        }
    }

    private func type(_ text: String) {
        for char in text { app.keys["vime.key.\(char)"].tap() }
    }

    private var document: String { app.textViews["vime.extension.editor"].value as? String ?? "" }
    private var mark: String {
        app.staticTexts["vime.extension.marked"].label.replacingOccurrences(of: "待确认文本：", with: "")
    }

    /// Waits until the host reports this document and marked text.
    private func expect(_ text: String, mark expected: String, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
        let matched = waitFor { self.document == text && self.mark == expected }
        print("HOST \(document); mark=\(mark)")
        XCTAssertTrue(matched, "\(message) expected \(text) / \(expected), got \(document) / \(mark)", file: file, line: line)
    }

    @discardableResult
    private func waitFor(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func testTheHostShowsAndCommitsTheConversion() throws {
        try launch(live: true)
        type("toukyouto")
        expect("東京都", mark: "東京都", "The marked text shows the conversion")
        app.keys["vime.key.return"].tap()
        expect("東京都", mark: "无", "Return commits what was shown")

        // Return straight after the last key, while that key's result may
        // still be pending, commits a conversion, never a transition text.
        type("kyouhaiitenkidesu")
        app.keys["vime.key.return"].tap()
        XCTAssertTrue(waitFor { self.mark == "无" }, "Return finishes the composition")
        let sentence = String(document.dropFirst("東京都".count))
        print("SENTENCE \(sentence)")
        XCTAssertFalse(sentence.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) },
                       "No Roman letters are committed: \(sentence)")
        XCTAssertNotEqual(sentence, "きょうはいいてんきです", "The committed text is converted")
    }

    func testSpaceBackspaceAndDeletionKeepTheShownConversion() throws {
        try launch(live: true)
        type("toukyou")
        expect("東京", mark: "東京")
        app.keys["vime.key.space"].tap()
        XCTAssertTrue(waitFor { self.mark != "東京" && self.mark != "无" }, "Space moves past the shown conversion")
        print("SPACE \(mark)")
        app.keys["vime.key.delete"].tap()
        expect("東京", mark: "東京", "Backspace returns to the live conversion")

        type("to")
        expect("東京都", mark: "東京都")
        app.keys["vime.key.delete"].tap()
        expect("東京", mark: "東京", "Deleting back to a known reading shows its conversion")
        for _ in 0..<5 { app.keys["vime.key.delete"].tap() }
        expect("", mark: "无")
    }

    func testOffKeepsTheKanaComposition() throws {
        try launch(live: false)
        type("toukyou")
        expect("とうきょう", mark: "とうきょう")
        app.keys["vime.key.return"].tap()
        expect("とうきょう", mark: "无")
    }
}
