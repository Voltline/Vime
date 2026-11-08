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

    // MARK: Chinese input turned off

    func testChineseInputIsOnByDefaultWithPinyinLookup() throws {
        let preferences = KeyboardPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(preferences.chineseInputEnabled)
        XCTAssertTrue(preferences.pinyinLookupInJapanese)
    }

    func testTurningChineseOffWhileSelectedFallsBackToJapanese() throws {
        let (keyboard, preferences) = try keyboard()
        preferences.inputLanguage = .chinese
        keyboard.reloadPreferences()
        XCTAssertTrue(keyboard.session is ChineseInputSession)
        var edits: [KeyboardEdit] = []
        keyboard.onEdit = { edits += $0 }
        let chinese = try XCTUnwrap(keyboard.session as? ChineseInputSession)
        keyboard.apply(chinese.type("nihao"))
        waitUntilCurrent(chinese)

        preferences.chineseInputEnabled = false
        XCTAssertEqual(preferences.inputLanguage, .japanese)
        keyboard.reloadPreferences()
        XCTAssertFalse(keyboard.session is ChineseInputSession)
        XCTAssertEqual(keyboard.session.inputTraits.language, .japanese)
        XCTAssertTrue(edits.contains(.insert("你好")), "the Chinese composition reaches the host first")
        XCTAssertEqual(preferences.store.string(forKey: "vime.inputLanguage"), "chinese", "the stored choice is kept")

        preferences.chineseInputEnabled = true
        keyboard.reloadPreferences()
        XCTAssertTrue(keyboard.session is ChineseInputSession, "turning Chinese back on restores the choice")
    }

    /// The extension's own keyboard reads the App Group store.
    func testAKeyboardOpenedWithChineseOffNeverBuildsAChineseSession() throws {
        try XCTSkipIf(RimeEngine.bundledData == nil, "RimeData.bundle is not bundled")
        let shared = KeyboardPreferences()
        defer { shared.chineseInputEnabled = true; shared.inputLanguage = .japanese }
        shared.inputLanguage = .chinese
        shared.chineseInputEnabled = false
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350))
        keyboard.layoutIfNeeded()
        XCTAssertFalse(keyboard.session is ChineseInputSession, "Rime only starts inside a Chinese session")
        let key = try languageKey(in: keyboard)
        XCTAssertNil(key.hint)
        XCTAssertNil(key.alternateAction)
    }

    func testTheLanguageKeyOffersChineseOnlyWhileChineseInputIsOn() throws {
        let (keyboard, preferences) = try keyboard()
        var key = try languageKey(in: keyboard)
        XCTAssertEqual(key.hint, "中")
        XCTAssertNotNil(key.alternateAction)

        preferences.chineseInputEnabled = false
        keyboard.reloadPreferences()
        key = try languageKey(in: keyboard)
        XCTAssertNil(key.hint, "back to the Japanese/English key")
        XCTAssertNil(key.alternateAction)
        XCTAssertNil(key.alternateTitle)
        XCTAssertNil(key.accessibilityCustomActions)
        XCTAssertNil(keyboard.quickSwitchLanguage)
        keyboard.switchInputLanguage(to: .chinese)
        XCTAssertFalse(keyboard.session is ChineseInputSession, "nothing else can switch to Chinese")
        key.action?()
        XCTAssertEqual(keyboard.session.inputTraits.language, .english, "a tap still toggles English")
        key = try languageKey(in: keyboard)
        key.action?()
        XCTAssertEqual(keyboard.session.inputTraits.language, .japanese)

        preferences.chineseInputEnabled = true
        keyboard.reloadPreferences()
        key = try languageKey(in: keyboard)
        XCTAssertEqual(key.hint, "中")
        XCTAssertNotNil(key.alternateAction)
    }

    func testTheKanaPadDropsTheSwitchWhileChineseInputIsOff() throws {
        let (keyboard, preferences) = try keyboard()
        preferences.kanaLayout = true
        preferences.chineseInputEnabled = false
        keyboard.reloadPreferences()
        keyboard.layoutIfNeeded()
        XCTAssertTrue(keyboard.kanaLayoutActive)
        let key = try languageKey(in: keyboard)
        XCTAssertNil(key.hint)
        XCTAssertNil(key.alternateAction)
    }

    func testTheSettingsPanelHidesTheLanguageWhileChineseInputIsOff() throws {
        let (keyboard, preferences) = try keyboard()
        keyboard.createSettingsPanel()
        let panel = try XCTUnwrap(keyboard.settingsPanel)
        XCTAssertTrue(panel.showsInputLanguage)
        preferences.chineseInputEnabled = false
        keyboard.reloadPreferences()
        XCTAssertFalse(panel.showsInputLanguage)
        preferences.chineseInputEnabled = true
        keyboard.reloadPreferences()
        XCTAssertTrue(panel.showsInputLanguage)
    }

    func testPinyinLookupDependsOnChineseInput() throws {
        let preferences = KeyboardPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        preferences.chineseInputEnabled = false
        XCTAssertFalse(preferences.pinyinLookupInJapanese, "part of Chinese input")
        preferences.chineseInputEnabled = true
        XCTAssertTrue(preferences.pinyinLookupInJapanese)
        preferences.pinyinLookupInJapanese = false
        XCTAssertFalse(preferences.pinyinLookupInJapanese)
        preferences.chineseInputEnabled = false
        preferences.chineseInputEnabled = true
        XCTAssertFalse(preferences.pinyinLookupInJapanese, "its own choice survives Chinese input turning off")
        let before = preferences.snapshot
        preferences.pinyinLookupInJapanese = true
        XCTAssertNotEqual(preferences.snapshot, before, "the keyboard reloads when it changes")
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

    func testChineseShowsTheScriptToggleWhereJapaneseHasTheKanaToggle() throws {
        let (keyboard, preferences) = try keyboard()
        keyboard.canUndoLineDeletion = true
        keyboard.layoutIfNeeded()
        let metrics = KeyboardMetrics(width: 440, compact: keyboard.compact, showsFooter: keyboard.showsFooter, pad: keyboard.pad)
        XCTAssertFalse(keyboard.modeButton.isHidden)
        XCTAssertEqual(keyboard.undoButton.frame, metrics.trailingToolbarFrame(index: 2))
        preferences.inputLanguage = .chinese
        keyboard.reloadPreferences()
        keyboard.layoutIfNeeded()
        XCTAssertFalse(keyboard.modeButton.isHidden)
        XCTAssertEqual(keyboard.modeButton.title(for: .normal), "简")
        XCTAssertEqual(keyboard.modeButton.frame, metrics.trailingToolbarFrame(index: 1))
        XCTAssertEqual(keyboard.undoButton.frame, metrics.trailingToolbarFrame(index: 2))

        // English inside Chinese has no script to switch.
        let chinese = try XCTUnwrap(keyboard.session as? ChineseInputSession)
        keyboard.apply(chinese.activateEnglish())
        keyboard.layoutIfNeeded()
        XCTAssertTrue(keyboard.modeButton.isHidden)
        XCTAssertEqual(keyboard.undoButton.frame, metrics.trailingToolbarFrame(index: 1), "no empty slot before the close button")
    }

    func testTheScriptToggleSwitchesBetweenSimplifiedAndTraditional() throws {
        let (keyboard, preferences) = try keyboard()
        preferences.traditionalChinese = false
        preferences.inputLanguage = .chinese
        keyboard.reloadPreferences()
        let chinese = try XCTUnwrap(keyboard.session as? ChineseInputSession)
        XCTAssertEqual(keyboard.modeButton.accessibilityLabel, String(localized: "切换简体和繁体"))

        keyboard.modeButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(preferences.traditionalChinese)
        XCTAssertEqual(keyboard.modeButton.title(for: .normal), "繁")
        keyboard.apply(chinese.type("zhongguo"))
        waitUntilCurrent(chinese)
        XCTAssertEqual(chinese.candidatePresentations.first?.text, "中國")
        chinese.reset()

        keyboard.modeButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(preferences.traditionalChinese)
        XCTAssertEqual(keyboard.modeButton.title(for: .normal), "简")
        keyboard.apply(chinese.type("zhongguo"))
        waitUntilCurrent(chinese)
        XCTAssertEqual(chinese.candidatePresentations.first?.text, "中国")
        chinese.reset()

        // The choice is kept for the next keyboard.
        preferences.traditionalChinese = true
        let next = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350),
                                session: KeyboardView.session(for: .chinese), preferences: preferences)
        next.layoutIfNeeded()
        XCTAssertEqual(next.modeButton.title(for: .normal), "繁")
    }

    private func languageKey(in keyboard: KeyboardView) throws -> KeyboardKey {
        try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardKey }
            .first { $0.accessibilityIdentifier == "vime.key.language" })
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
