import XCTest
import UIKit

@MainActor
final class KeyboardAccessibilityTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func makeKeyboard(kana: Bool) -> (KeyboardView, KeyboardSession) {
        let suite = "VimeAccessibilityTests." + UUID().uuidString
        suites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.phraseSuggestions = false
        preferences.kanaLayout = kana
        let session = KeyboardSession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session, preferences: preferences)
        keyboard.frame.size.height = keyboard.preferredHeight(for: 440)
        keyboard.layoutIfNeeded()
        return (keyboard, session)
    }

    private func key(_ id: String, in keyboard: KeyboardView) throws -> KeyboardKey {
        try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == id } as? KeyboardKey)
    }

    func testKeysUseTheKeyboardKeyTrait() throws {
        let (kana, _) = makeKeyboard(kana: true)
        for id in ["vime.kana.ka", "vime.kana.next", "vime.key.space"] {
            XCTAssertTrue(try key(id, in: kana).accessibilityTraits.contains(.keyboardKey), id)
        }
        let (letters, _) = makeKeyboard(kana: false)
        for id in ["vime.key.q", "vime.key.shift", "vime.key.delete", "vime.key.return"] {
            XCTAssertTrue(try key(id, in: letters).accessibilityTraits.contains(.keyboardKey), id)
        }
        XCTAssertEqual(try key("vime.key.delete", in: letters).accessibilityLabel, String(localized: "删除"))
    }

    func testFlickDirectionsAreVoiceOverActions() throws {
        let (keyboard, session) = makeKeyboard(kana: true)
        let ka = try key("vime.kana.ka", in: keyboard)
        let actions = try XCTUnwrap(ka.accessibilityCustomActions)
        XCTAssertEqual(actions.map(\.name), ["き", "く", "け", "こ"])
        XCTAssertTrue(try XCTUnwrap(actions[2].actionHandler)(actions[2]))
        XCTAssertEqual(session.composition, "け")
        XCTAssertTrue(ka.accessibilityActivate())
        XCTAssertEqual(session.composition, "けか", "Activation still enters the center kana")
        let punctuation = try key("vime.kana.punctuation", in: keyboard)
        XCTAssertEqual(punctuation.accessibilityCustomActions?.map(\.name), ["。", "？", "！", "…"])
    }

    func testSwipeUpSymbolsAreVoiceOverActions() throws {
        let (keyboard, _) = makeKeyboard(kana: false)
        XCTAssertEqual(try key("vime.key.q", in: keyboard).accessibilityCustomActions?.map(\.name), ["1"])
        XCTAssertEqual(try key("vime.key.m", in: keyboard).accessibilityCustomActions?.map(\.name), ["…"])
        XCTAssertNil(try key("vime.key.space", in: keyboard).accessibilityCustomActions)
    }

    func testShiftReportsItsState() throws {
        let (keyboard, _) = makeKeyboard(kana: false)
        let shift = try key("vime.key.shift", in: keyboard)
        XCTAssertNil(shift.accessibilityValue)
        XCTAssertFalse(shift.accessibilityTraits.contains(.selected))
        keyboard.shift(at: 100)
        XCTAssertEqual(shift.accessibilityValue, String(localized: "已开启"))
        XCTAssertTrue(shift.accessibilityTraits.contains(.selected))
        keyboard.shift(at: 200)
        XCTAssertNil(shift.accessibilityValue)
        XCTAssertFalse(shift.accessibilityTraits.contains(.selected))
    }

    func testIncreaseContrastOutlinesKeys() throws {
        let (keyboard, _) = makeKeyboard(kana: false)
        let q = try key("vime.key.q", in: keyboard)
        XCTAssertEqual(q.layer.borderWidth, 0)
        q.traitOverrides.accessibilityContrast = .high
        q.updateTraitsIfNeeded(); q.setNeedsLayout(); q.layoutIfNeeded()
        XCTAssertEqual(q.layer.borderWidth, 1)
        q.traitOverrides.accessibilityContrast = .normal
        q.updateTraitsIfNeeded(); q.setNeedsLayout(); q.layoutIfNeeded()
        XCTAssertEqual(q.layer.borderWidth, 0)
    }

    func testEmojiAreReadAsTheEmojiNotTheirEnglishNames() async throws {
        let panel = KeyboardSymbolPanel(frame: CGRect(x: 0, y: 0, width: 440, height: 350))
        panel.layoutIfNeeded()
        let grid = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        try await Task.sleep(for: .milliseconds(250))
        grid.layoutIfNeeded()
        let cells = grid.visibleCells
        XCTAssertFalse(cells.isEmpty)
        for cell in cells {
            let label = try XCTUnwrap(cell.accessibilityLabel)
            XCTAssertFalse(label.contains { $0.isASCII && $0.isLetter }, label)
        }
    }
}
