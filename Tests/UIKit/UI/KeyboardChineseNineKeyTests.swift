import XCTest
import UIKit

@MainActor
final class KeyboardChineseNineKeyTests: XCTestCase {
    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeyboardChineseNineKeyTests-\(UUID().uuidString)")
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func makeKeyboard() throws -> (KeyboardView, KeyboardTouchSurface, ChineseInputSession, KeyboardPreferences) {
        let suite = "VimeChineseNineKeyTests." + UUID().uuidString
        suites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.phraseSuggestions = false
        preferences.chineseLanguageModel = false
        preferences.chineseLayout = .nineKey
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user))
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session, preferences: preferences)
        keyboard.frame.size.height = keyboard.preferredHeight(for: 440)
        keyboard.layoutIfNeeded()
        let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        return (keyboard, surface, session, preferences)
    }

    private func key(_ id: String, in keyboard: KeyboardView) throws -> KeyboardKey {
        try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == id } as? KeyboardKey, id)
    }

    private func press(_ key: KeyboardKey, on surface: KeyboardTouchSurface) {
        let id = UUID()
        let point = CGPoint(x: key.frame.midX, y: key.frame.midY)
        XCTAssertTrue(surface.beginPress(id: id, at: point))
        surface.endPress(id: id, at: point)
    }

    private func waitUntilCurrent(_ session: ChineseInputSession, keyboard: KeyboardView) {
        let deadline = Date().addingTimeInterval(10)
        while !session.candidatesAreCurrent && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        keyboard.refresh()
        keyboard.layoutIfNeeded()
    }

    func testPadTypesDigitsAndTheRailPicksSyllables() throws {
        let (keyboard, surface, session, _) = try makeKeyboard()
        XCTAssertTrue(keyboard.chineseNineKeyActive)
        let rail = try XCTUnwrap(keyboard.syllableRail)
        XCTAssertFalse(rail.isHidden)
        XCTAssertEqual(rail.symbols, KeyboardView.nineKeyPunctuation, "punctuation while nothing is typed")
        for digit in "94664486" { press(try key("vime.nineKey.\(digit)", in: keyboard), on: surface) }
        waitUntilCurrent(session, keyboard: keyboard)
        XCTAssertEqual(session.raw, "94664486")
        XCTAssertTrue(rail.symbols.contains("xiong"), "\(rail.symbols)")
        XCTAssertEqual(rail.highlighted, rail.symbols.first)
        XCTAssertEqual(try key("vime.nineKey.1", in: keyboard).title(for: .normal), String(localized: "分词"))
        attach(keyboard, name: "nine-key-composing")
        rail.onSelect?("xiong")
        waitUntilCurrent(session, keyboard: keyboard)
        XCTAssertEqual(session.raw, "xiong'486")
        XCTAssertTrue(rail.symbols.contains("gu"))
        press(try key("vime.nineKey.retype", in: keyboard), on: surface)
        waitUntilCurrent(session, keyboard: keyboard)
        XCTAssertFalse(session.isComposing)
        XCTAssertEqual(rail.symbols, KeyboardView.nineKeyPunctuation)
    }

    func testEnglishAndFullPinyinKeepQWERTY() throws {
        let (keyboard, _, session, preferences) = try makeKeyboard()
        _ = session.toggleEnglish()
        keyboard.refresh()
        XCTAssertFalse(keyboard.chineseNineKeyActive, "English types on QWERTY")
        XCTAssertTrue(keyboard.syllableRail?.isHidden ?? true)
        _ = session.toggleEnglish()
        keyboard.refresh()
        XCTAssertTrue(keyboard.chineseNineKeyActive)
        preferences.chineseLayout = .fullPinyin
        keyboard.refresh()
        XCTAssertFalse(keyboard.chineseNineKeyActive)
    }

    private func attach(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["VIME_SNAPSHOT_DIR"] {
            try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}

@MainActor
final class KeyboardShuangpinTests: XCTestCase {
    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("KeyboardShuangpinTests-\(UUID().uuidString)")
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func key(_ id: String, in keyboard: KeyboardView) throws -> KeyboardKey {
        try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == id } as? KeyboardKey, id)
    }

    func testLanguageKeyKeepsItsSwitchClearOfTheQuickSwitchHint() throws {
        let suite = "VimeLanguageKey." + UUID().uuidString
        suites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.chineseLanguageModel = false
        preferences.chineseInputEnabled = true
        preferences.japaneseInputEnabled = true
        preferences.chineseLayout = .fullPinyin
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        for width in [320, 375, 440] as [CGFloat] {
            let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user))
            let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: width, height: 300), session: session, preferences: preferences)
            defer { keyboard.stopInteractions() }
            keyboard.followsInputLanguage = true
            keyboard.frame.size.height = keyboard.preferredHeight(for: width)
            keyboard.layoutIfNeeded()
            let language = try key("vime.key.language", in: keyboard)
            language.layoutIfNeeded()
            XCTAssertEqual(language.hint, "あ", "Quick switch to Japanese")
            let image = try XCTUnwrap(language.imageView)
            XCTAssertGreaterThanOrEqual(image.frame.minY, language.hintLabel.frame.maxY, "\(width): the switch stays below the hint")
            XCTAssertTrue(language.bounds.contains(image.frame), "\(width): the switch stays inside the key")
            XCTAssertGreaterThanOrEqual(image.frame.height, 13, "\(width): still readable")
            if let directory = ProcessInfo.processInfo.environment["VIME_SNAPSHOT_DIR"] {
                let shot = UIGraphicsImageRenderer(bounds: language.bounds).image { language.layer.render(in: $0.cgContext) }
                try? shot.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("language-\(Int(width)).png"))
            }
        }
    }

    func testFullNumberPageFollowsTheChineseLayout() throws {
        let suite = "VimeChineseNumbers." + UUID().uuidString
        suites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.chineseLanguageModel = false
        preferences.chineseLayout = .fullPinyin
        preferences.nineKeyNumbers = false
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user))
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session, preferences: preferences)
        defer { keyboard.stopInteractions() }
        keyboard.page = .numbers; keyboard.rebuildKeys(); keyboard.layoutIfNeeded()
        let rows = keyboard.rows.map { $0.compactMap { $0.0.title(for: .normal) } }
        XCTAssertEqual(rows[0], Array("1234567890").map(String.init))
        XCTAssertEqual(rows[1], ["-", "/", ":", "~", "(", ")", "…", "@", "“", "”"])
        XCTAssertEqual(rows[2].filter { $0.count == 1 }, ["。", "，", "、", "？", "！", ".", "'"], "#+= and delete around them")
        keyboard.frame.size.height = keyboard.preferredHeight(for: 440); keyboard.setNeedsLayout(); keyboard.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(keyboard.rows[2].last).0.frame.maxX, try XCTUnwrap(keyboard.rows[0].last).0.frame.maxX,
            accuracy: 1, "Delete ends the row like 0 does, with no gap")
        // The bottom row has no language key; 符号 takes its place, right of the space bar.
        let bottom = try XCTUnwrap(keyboard.rows.last).map(\.0)
        XCTAssertEqual(bottom.map { $0.accessibilityIdentifier ?? $0.title(for: .normal) ?? "" },
                       ["ABC", "vime.key.emoji", "vime.key.space", "vime.key.symbols", "vime.key.return"])
        XCTAssertNil(keyboard.languageKey)
        XCTAssertEqual(bottom[0].fillColor, KeyboardPalette.accent, "ABC stands out like the number pad's")
        XCTAssertEqual(bottom[4].frame.maxX, try XCTUnwrap(keyboard.rows[0].last).0.frame.maxX, accuracy: 1)
        for (left, right) in zip(bottom, bottom.dropFirst()) { XCTAssertLessThan(left.frame.maxX, right.frame.minX) }
        keyboard.page = .symbols; keyboard.rebuildKeys()
        let more = keyboard.rows.flatMap { $0.compactMap { $0.0.title(for: .normal) } }
        for moved in [";", "¥", "&", "\""] { XCTAssertTrue(more.contains(moved), "\(moved) moves to #+=") }
    }

    func testLetterKeysShowTheSchemeFinals() throws {
        let suite = "VimeShuangpinTests." + UUID().uuidString
        suites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.chineseLanguageModel = false
        preferences.chineseLayout = .shuangpin
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user))
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session, preferences: preferences)
        keyboard.frame.size.height = keyboard.preferredHeight(for: 440)
        keyboard.layoutIfNeeded()
        XCTAssertFalse(keyboard.chineseNineKeyActive, "QWERTY")
        XCTAssertEqual(try key("vime.key.c", in: keyboard).footnote, "ao")
        XCTAssertEqual(try key("vime.key.v", in: keyboard).footnote, "zh ui")
        XCTAssertNil(try key("vime.key.a", in: keyboard).footnote)
        let image = UIGraphicsImageRenderer(bounds: keyboard.bounds).image { keyboard.layer.render(in: $0.cgContext) }
        if let directory = ProcessInfo.processInfo.environment["VIME_SNAPSHOT_DIR"] {
            try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("shuangpin.png"))
        }
        preferences.shuangpinScheme = .ziranma
        keyboard.refresh()
        XCTAssertEqual(try key("vime.key.c", in: keyboard).footnote, "iao")
        _ = session.toggleEnglish()
        keyboard.refresh()
        XCTAssertNil(try key("vime.key.c", in: keyboard).footnote, "English shows no finals")
        _ = session.toggleEnglish()
        preferences.chineseLayout = .fullPinyin
        keyboard.refresh()
        XCTAssertNil(try key("vime.key.c", in: keyboard).footnote)
    }

    func testTheKeyboardSettingsSwitchTheLayout() throws {
        let suite = "VimeShuangpinTests." + UUID().uuidString
        suites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.chineseLanguageModel = false
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user))
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session, preferences: preferences)
        keyboard.frame.size.height = keyboard.preferredHeight(for: 440)
        keyboard.layoutIfNeeded()
        keyboard.toggleSettings()
        keyboard.layoutIfNeeded()
        let control = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.setting.chineseLayout" } as? UISegmentedControl)
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        control.selectedSegmentIndex = 2
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(preferences.chineseLayout, .shuangpin)
        keyboard.layoutIfNeeded()
        if let panel = control.superview(of: UIScrollView.self) {
            panel.scrollRectToVisible(control.convert(control.bounds, to: panel), animated: false)
        }
        if let directory = ProcessInfo.processInfo.environment["VIME_SNAPSHOT_DIR"] {
            let image = UIGraphicsImageRenderer(bounds: keyboard.bounds).image { keyboard.layer.render(in: $0.cgContext) }
            try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings-panel.png"))
        }
        keyboard.toggleSettings()
        keyboard.layoutIfNeeded()
        XCTAssertEqual(try key("vime.key.c", in: keyboard).footnote, "ao")
        keyboard.toggleSettings()
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        keyboard.toggleSettings()
        keyboard.layoutIfNeeded()
        XCTAssertTrue(keyboard.chineseNineKeyActive)
        let rail = try XCTUnwrap(keyboard.syllableRail)
        let right = try key("vime.nineKey.retype", in: keyboard)
        XCTAssertEqual(rail.frame.width, right.frame.width, accuracy: 0.5, "the rail is as wide as the right column")
    }
}

private extension UIView {
    func superview<T: UIView>(of type: T.Type) -> T? { superview.flatMap { $0 as? T ?? $0.superview(of: type) } }
}
