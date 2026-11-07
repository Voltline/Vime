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

    func testSwipingUpOnTheLanguageKeySwitchesAndStoresTheLanguage() throws {
        let (keyboard, preferences) = try keyboard()
        var key = try languageKey(in: keyboard)
        XCTAssertEqual(key.hint, "中")
        XCTAssertEqual(key.accessibilityCustomActions?.map(\.name), [String(localized: "切换到简体中文")])
        keyboard.apply(keyboard.session.type("ka"))
        var edits: [KeyboardEdit] = []
        keyboard.onEdit = { edits += $0 }

        try XCTUnwrap(key.alternateAction)()
        XCTAssertTrue(keyboard.session is ChineseInputSession)
        XCTAssertEqual(preferences.inputLanguage, .chinese)
        XCTAssertFalse(edits.isEmpty, "the Japanese composition reaches the host first")
        key = try languageKey(in: keyboard)
        XCTAssertEqual(key.hint, "あ")

        try XCTUnwrap(key.alternateAction)()
        XCTAssertFalse(keyboard.session is ChineseInputSession)
        XCTAssertEqual(preferences.inputLanguage, .japanese)
    }

    func testTappingTheLanguageKeyStillTogglesEnglish() throws {
        let (keyboard, preferences) = try keyboard()
        let key = try languageKey(in: keyboard)
        key.action?()
        XCTAssertEqual(keyboard.session.inputTraits.language, .english)
        XCTAssertEqual(preferences.inputLanguage, .japanese)
    }

    func testTheKanaPadOffersTheSameSwitch() throws {
        let (keyboard, preferences) = try keyboard()
        preferences.kanaLayout = true
        keyboard.reloadPreferences()
        keyboard.layoutIfNeeded()
        let key = try languageKey(in: keyboard)
        XCTAssertEqual(key.hint, "中")
        try XCTUnwrap(key.alternateAction)()
        XCTAssertTrue(keyboard.session is ChineseInputSession)
        XCTAssertFalse(keyboard.prefersKanaLayout)
    }

    func testAFixedSessionOffersNoSwitch() throws {
        let (keyboard, _) = try keyboard()
        keyboard.followsInputLanguage = false
        keyboard.rebuildKeys()
        let key = try languageKey(in: keyboard)
        XCTAssertNil(key.alternateAction)
        XCTAssertNil(key.hint)
    }

    /// The extension's keyboard comes from the plain initializer, and UIKit
    /// usually builds a new controller each time the keyboard is shown again.
    /// Each one must offer the switch from its first layout, not only after
    /// something happens to rebuild its keys.
    func testTheSwitchSurvivesDismissingAndShowingTheKeyboardAgain() throws {
        try XCTSkipIf(RimeEngine.bundledData == nil, "RimeData.bundle is not bundled")
        XCTAssertEqual(KeyboardPreferences().inputLanguage, .japanese)
        func assertOffersChinese(_ keyboard: KeyboardView, _ moment: String) throws {
            keyboard.layoutIfNeeded()
            let key = try languageKey(in: keyboard)
            XCTAssertEqual(key.hint, "中", moment)
            XCTAssertNotNil(key.alternateAction, "\(moment): a swipe up has somewhere to go")
            XCTAssertEqual(key.accessibilityCustomActions?.map(\.name), [String(localized: "切换到简体中文")], moment)
        }
        for showing in 1...3 {
            let controller = KeyboardViewController()
            controller.loadViewIfNeeded()
            let keyboard = try XCTUnwrap((controller.view as? KeyboardInputView)?.keyboard)
            controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
            try assertOffersChinese(keyboard, "showing \(showing), new controller")
            controller.beginAppearanceTransition(false, animated: false); controller.endAppearanceTransition()
            // A retained controller can be shown again, too.
            controller.beginAppearanceTransition(true, animated: false); controller.endAppearanceTransition()
            try assertOffersChinese(keyboard, "showing \(showing), same controller")
            controller.beginAppearanceTransition(false, animated: false); controller.endAppearanceTransition()
        }
    }

    func testTheSettingsPanelSwitchesTheLanguage() throws {
        let (keyboard, preferences) = try keyboard()
        keyboard.createSettingsPanel()
        let panel = try XCTUnwrap(keyboard.settingsPanel)
        let control = try XCTUnwrap(descendants(panel).compactMap { $0 as? UISegmentedControl }
            .first { $0.accessibilityIdentifier == "vime.setting.inputLanguage" })
        XCTAssertFalse(sequence(first: control as UIView, next: \.superview).contains { $0.isHidden })
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        XCTAssertTrue(keyboard.session is ChineseInputSession)
        XCTAssertEqual(preferences.inputLanguage, .chinese)
        XCTAssertEqual(control.selectedSegmentIndex, 1)
    }

    func testUndoMovesBesideCloseWhenChineseHidesTheKanaToggle() throws {
        let (keyboard, preferences) = try keyboard()
        keyboard.canUndoLineDeletion = true
        keyboard.layoutIfNeeded()
        let metrics = KeyboardMetrics(width: 440, compact: keyboard.compact, showsFooter: keyboard.showsFooter, pad: keyboard.pad)
        XCTAssertFalse(keyboard.modeButton.isHidden)
        XCTAssertFalse(keyboard.undoButton.isHidden)
        XCTAssertEqual(keyboard.undoButton.frame, metrics.trailingToolbarFrame(index: 2))
        preferences.inputLanguage = .chinese
        keyboard.reloadPreferences()
        keyboard.layoutIfNeeded()
        XCTAssertTrue(keyboard.modeButton.isHidden)
        XCTAssertFalse(keyboard.undoButton.isHidden)
        XCTAssertEqual(keyboard.undoButton.frame, metrics.trailingToolbarFrame(index: 1), "no empty slot before the close button")
    }

    private func languageKey(in keyboard: KeyboardView) throws -> KeyboardKey {
        try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardKey }
            .first { $0.accessibilityIdentifier == "vime.key.language" })
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
