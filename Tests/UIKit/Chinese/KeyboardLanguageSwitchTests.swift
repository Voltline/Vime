import UIKit
import XCTest

@MainActor
final class KeyboardLanguageSwitchTests: XCTestCase {
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "KeyboardLanguageSwitchTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func keyboard() throws -> (KeyboardView, KeyboardPreferences) {
        try XCTSkipIf(RimeEngine.bundledData == nil, "RimeData.bundle is not bundled")
        let preferences = KeyboardPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350),
                                    session: KeyboardView.session(for: preferences.inputLanguage), preferences: preferences)
        keyboard.followsInputLanguage = true
        keyboard.layoutIfNeeded()
        return (keyboard, preferences)
    }

    private func waitUntilCurrent(_ session: ChineseInputSession) {
        let deadline = Date().addingTimeInterval(10)
        while !session.candidatesAreCurrent && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    func testChangingTheStoredLanguageSwapsTheSession() throws {
        let (keyboard, preferences) = try keyboard()
        XCTAssertEqual(preferences.inputLanguage, .japanese)
        XCTAssertEqual(keyboard.session.inputTraits.language, .japanese)
        var edits: [KeyboardEdit] = []
        keyboard.onEdit = { edits += $0 }
        keyboard.apply(keyboard.session.type("ka"))
        XCTAssertTrue(keyboard.session.isComposing)

        preferences.inputLanguage = .chinese
        keyboard.reloadPreferences()
        let chinese = try XCTUnwrap(keyboard.session as? ChineseInputSession)
        XCTAssertFalse(edits.isEmpty, "the Japanese composition reaches the host before the swap")
        keyboard.apply(chinese.type("nihao"))
        waitUntilCurrent(chinese)
        XCTAssertEqual(chinese.candidatePresentations.first?.text, "你好")

        preferences.inputLanguage = .japanese
        keyboard.reloadPreferences()
        XCTAssertFalse(keyboard.session is ChineseInputSession)
        XCTAssertFalse(keyboard.session.isComposing, "the Chinese composition was confirmed")
        XCTAssertTrue(edits.contains(.insert("你好")))
    }

    func testContextProvidersMoveToTheNewSession() throws {
        let (keyboard, preferences) = try keyboard()
        keyboard.leftContextProvider = { "前文" }
        preferences.inputLanguage = .chinese
        keyboard.reloadPreferences()
        XCTAssertTrue(keyboard.session is ChineseInputSession)
        XCTAssertEqual(keyboard.leftContextProvider?(), "前文")
    }

    func testChineseNeverUsesTheKanaPad() throws {
        let (keyboard, preferences) = try keyboard()
        preferences.kanaLayout = true
        keyboard.reloadPreferences()
        XCTAssertTrue(keyboard.prefersKanaLayout)
        preferences.inputLanguage = .chinese
        keyboard.reloadPreferences()
        XCTAssertFalse(keyboard.prefersKanaLayout)
    }

    func testAKeyboardGivenASessionKeepsIt() throws {
        let (keyboard, preferences) = try keyboard()
        keyboard.followsInputLanguage = false
        preferences.inputLanguage = .chinese
        keyboard.reloadPreferences()
        XCTAssertFalse(keyboard.session is ChineseInputSession)
    }
}
