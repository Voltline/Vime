import UIKit
import XCTest

@MainActor
final class KoreanLanguageSwitchTests: XCTestCase {
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "KoreanLanguageSwitchTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makePreferences() throws -> KeyboardPreferences {
        KeyboardPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    private func makeKeyboard(_ preferences: KeyboardPreferences) -> KeyboardView {
        let keyboard = KeyboardView(
            frame: CGRect(x: 0, y: 0, width: 440, height: 350),
            session: KeyboardView.session(for: preferences.inputLanguage),
            preferences: preferences,
            followsInputLanguage: true
        )
        keyboard.layoutIfNeeded()
        return keyboard
    }

    func testKoreanIsOffByDefaultAndSupportsKoreanOnly() throws {
        let prefs = try makePreferences()
        XCTAssertFalse(prefs.koreanInputEnabled)
        XCTAssertTrue(prefs.japaneseInputEnabled)

        // Enable only Korean + English.
        prefs.koreanInputEnabled = true
        prefs.chineseInputEnabled = false
        prefs.japaneseInputEnabled = false
        XCTAssertTrue(prefs.koreanInputEnabled)
        XCTAssertFalse(prefs.chineseInputEnabled)
        XCTAssertFalse(prefs.japaneseInputEnabled)
        XCTAssertEqual(prefs.inputLanguage, .korean)

        // Turning Korean off when nothing else is enabled falls back to Japanese.
        prefs.koreanInputEnabled = false
        XCTAssertTrue(prefs.japaneseInputEnabled)
        XCTAssertEqual(prefs.inputLanguage, .japanese)
    }

    func testTwoBeolsikLayoutShiftAndVoiceOverLabels() throws {
        let prefs = try makePreferences()
        prefs.koreanInputEnabled = true
        prefs.inputLanguage = .korean
        let keyboard = makeKeyboard(prefs)
        XCTAssertTrue(keyboard.session is KoreanInputSession)
        XCTAssertTrue(keyboard.koreanLayoutActive)

        let qKey = try XCTUnwrap(key(in: keyboard, id: "vime.key.q"))
        let rKey = try XCTUnwrap(key(in: keyboard, id: "vime.key.r"))
        let pKey = try XCTUnwrap(key(in: keyboard, id: "vime.key.p"))
        XCTAssertEqual(qKey.title(for: .normal), "ㅂ")
        XCTAssertEqual(qKey.accessibilityLabel, "비읍")
        XCTAssertEqual(rKey.title(for: .normal), "ㄱ")
        XCTAssertEqual(rKey.accessibilityLabel, "기역")
        XCTAssertEqual(pKey.title(for: .normal), "ㅔ")
        XCTAssertEqual(pKey.accessibilityLabel, "에")

        // Single Shift produces ㅃ, ㄲ, ㅖ and auto-unshifts after typing one letter.
        keyboard.shift(at: 1.0)
        XCTAssertTrue(keyboard.shifted)
        XCTAssertFalse(keyboard.capsLocked)
        XCTAssertEqual(qKey.title(for: .normal), "ㅃ")
        XCTAssertEqual(qKey.accessibilityLabel, "쌍비읍")
        XCTAssertEqual(rKey.title(for: .normal), "ㄲ")
        XCTAssertEqual(pKey.title(for: .normal), "ㅖ")

        qKey.action?()
        XCTAssertFalse(keyboard.shifted, "Shift should auto-reset after one jamo")
        XCTAssertEqual(qKey.title(for: .normal), "ㅂ")
        XCTAssertEqual(keyboard.session.markedText?.text, "ㅃ")

        // Double-tap Shift locks Caps Lock.
        keyboard.shift(at: 2.0)
        keyboard.shift(at: 2.2)
        XCTAssertTrue(keyboard.capsLocked)
        XCTAssertTrue(keyboard.shifted)
        rKey.action?()
        XCTAssertTrue(keyboard.shifted, "Caps Lock stays active after typing")
    }

    func testThreeLanguageSquareSwipeOrderAndSwitching() throws {
        try XCTSkipIf(RimeEngine.bundledData == nil, "RimeData.bundle is not bundled")
        let prefs = try makePreferences()
        prefs.japaneseInputEnabled = true
        prefs.chineseInputEnabled = true
        prefs.koreanInputEnabled = true
        prefs.inputLanguage = .chinese
        let keyboard = makeKeyboard(prefs)

        // Active Chinese -> Left = Japanese (あ), Right = Korean (한)
        var langKey = try XCTUnwrap(key(in: keyboard, id: "vime.key.language"))
        XCTAssertEqual(langKey.hint, "あ·한")
        XCTAssertEqual(langKey.swipeOptions?.map(\.title), ["あ", "한"])
        XCTAssertEqual(langKey.accessibilityCustomActions?.map(\.name), [
            String(localized: "切换到日语"),
            String(localized: "切换到韩语")
        ])

        // Swipe up-right -> Korean
        langKey.swipeOptions?[1].action()
        XCTAssertTrue(keyboard.session is KoreanInputSession)
        XCTAssertEqual(prefs.inputLanguage, .korean)

        // Active Korean -> Left = Japanese (あ), Right = Chinese (中)
        langKey = try XCTUnwrap(key(in: keyboard, id: "vime.key.language"))
        XCTAssertEqual(langKey.hint, "あ·中")
        XCTAssertEqual(langKey.swipeOptions?.map(\.title), ["あ", "中"])

        // Swipe up-left -> Japanese
        langKey.swipeOptions?[0].action()
        XCTAssertEqual(prefs.inputLanguage, .japanese)

        // Active Japanese -> Left = Chinese (中), Right = Korean (한)
        langKey = try XCTUnwrap(key(in: keyboard, id: "vime.key.language"))
        XCTAssertEqual(langKey.hint, "中·한")
        XCTAssertEqual(langKey.swipeOptions?.map(\.title), ["中", "한"])
    }

    func testLatinFieldAutoSwitchesKoreanToEnglishAndBack() throws {
        let prefs = try makePreferences()
        prefs.koreanInputEnabled = true
        prefs.inputLanguage = .korean
        let keyboard = makeKeyboard(prefs)
        XCTAssertEqual(keyboard.session.inputTraits.language, .korean)

        keyboard.keyboardType = .emailAddress
        XCTAssertEqual(keyboard.session.inputTraits.language, .english)
        XCTAssertFalse(keyboard.koreanLayoutActive)

        keyboard.keyboardType = .default
        XCTAssertEqual(keyboard.session.inputTraits.language, .korean)
        XCTAssertTrue(keyboard.koreanLayoutActive)
    }

    func testHitCalibrationKoreanBucketIsolation() {
        let calibration = KeyHitCalibration(directory: nil)
        let body = CGRect(x: 0, y: 0, width: 40, height: 48)
        for _ in 0..<8 {
            calibration.learnCommittedTap(letter: "ㅂ", point: CGPoint(x: 26, y: 24), body: body, bucket: .portrait, korean: true)
        }
        let koModel = calibration.effectiveModel(for: "ㅂ", in: .portrait, korean: true)
        let qwertyModel = calibration.effectiveModel(for: "ㅂ", in: .portrait, korean: false)
        XCTAssertGreaterThan(koModel.dx, 0.05)
        XCTAssertEqual(qwertyModel.count, 0)
        XCTAssertEqual(qwertyModel.dx, 0)
    }

    func testSettingsPanelShowsThreeLanguagesAndSwitchesToKorean() throws {
        try XCTSkipIf(RimeEngine.bundledData == nil, "RimeData.bundle is not bundled")
        let prefs = try makePreferences()
        prefs.japaneseInputEnabled = true
        prefs.chineseInputEnabled = true
        prefs.koreanInputEnabled = true
        prefs.inputLanguage = .japanese
        let keyboard = makeKeyboard(prefs)
        keyboard.createSettingsPanel()
        let panel = try XCTUnwrap(keyboard.settingsPanel)
        let control = try XCTUnwrap(
            descendants(panel).compactMap { $0 as? UISegmentedControl }
                .first { $0.accessibilityIdentifier == "vime.setting.inputLanguage" }
        )
        XCTAssertEqual(control.numberOfSegments, 3)
        control.selectedSegmentIndex = 2
        control.sendActions(for: .valueChanged)
        XCTAssertTrue(keyboard.session is KoreanInputSession)
        XCTAssertEqual(prefs.inputLanguage, .korean)
    }

    private func key(in keyboard: KeyboardView, id: String) -> KeyboardKey? {
        descendants(keyboard).compactMap { $0 as? KeyboardKey }.first { $0.accessibilityIdentifier == id }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
