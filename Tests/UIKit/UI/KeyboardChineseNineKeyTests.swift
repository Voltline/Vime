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
