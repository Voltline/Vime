import XCTest
import UIKit

@MainActor
final class KeyboardKanaLayoutTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func makeKeyboard(kana: Bool = true) -> (KeyboardView, KeyboardTouchSurface, KeyboardSession) {
        let suite = "VimeKanaLayoutTests." + UUID().uuidString
        suites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.phraseSuggestions = false
        preferences.kanaLayout = kana
        let session = KeyboardSession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session, preferences: preferences)
        keyboard.frame.size.height = keyboard.preferredHeight(for: 440)
        keyboard.layoutIfNeeded()
        let surface = descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first!
        return (keyboard, surface, session)
    }

    private func key(_ id: String, in keyboard: KeyboardView) throws -> KeyboardKey {
        try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == id } as? KeyboardKey)
    }

    /// Presses the key's center and releases it after moving by the offset.
    private func press(_ key: KeyboardKey, on surface: KeyboardTouchSurface, dx: CGFloat = 0, dy: CGFloat = 0) {
        let id = UUID()
        let start = CGPoint(x: key.frame.midX, y: key.frame.midY)
        let end = CGPoint(x: start.x + dx, y: start.y + dy)
        XCTAssertTrue(surface.beginPress(id: id, at: start))
        surface.movePress(id: id, to: end)
        surface.endPress(id: id, at: end)
    }

    func testFlickDirectionNeedsADeliberateDrag() {
        XCTAssertEqual(KeyFlick.resolve(x: 6, y: -8), .center)
        XCTAssertEqual(KeyFlick.resolve(x: -30, y: 4), .left)
        XCTAssertEqual(KeyFlick.resolve(x: 3, y: -30), .up)
        XCTAssertEqual(KeyFlick.resolve(x: 30, y: 10), .right)
        XCTAssertEqual(KeyFlick.resolve(x: -5, y: 30), .down)
        // Distances are in scaled points: a larger keyboard needs a longer drag.
        XCTAssertEqual(KeyFlick.resolve(x: 22, y: 0, scale: 1.3), .center)
    }

    func testToggleReverseAndModifierCycles() {
        XCTAssertEqual(KeyboardKanaLayout.next(after: "あ", key: 0), "い")
        XCTAssertEqual(KeyboardKanaLayout.next(after: "ぉ", key: 0), "あ")
        XCTAssertNil(KeyboardKanaLayout.next(after: "か", key: 0))
        XCTAssertEqual(KeyboardKanaLayout.previous("い"), "あ")
        XCTAssertEqual(KeyboardKanaLayout.previous("あ"), "ぉ")
        XCTAssertEqual(KeyboardKanaLayout.modified("か"), "が")
        XCTAssertEqual(KeyboardKanaLayout.modified("が"), "か")
        XCTAssertEqual(KeyboardKanaLayout.modified("つ"), "っ")
        XCTAssertEqual(KeyboardKanaLayout.modified("っ"), "づ")
        XCTAssertEqual(KeyboardKanaLayout.modified("ぱ"), "は")
        XCTAssertNil(KeyboardKanaLayout.modified("ん"))
        XCTAssertEqual(KeyboardKanaLayout.keys.count, KeyboardKanaLayout.identifiers.count)
        XCTAssertEqual(KeyboardKanaLayout.keys.count, KeyboardKanaLayout.cycles.count)
        for (outputs, cycle) in zip(KeyboardKanaLayout.keys, KeyboardKanaLayout.cycles) {
            XCTAssertEqual(outputs.count, 5)
            XCTAssertEqual(Character(outputs[0]), cycle[0], "A tap and the first toggle step enter the same kana")
        }
    }

    func testPadTypesTapsTogglesFlicksAndModifiers() throws {
        let (keyboard, surface, session) = makeKeyboard()
        let ka = try key("vime.kana.ka", in: keyboard)
        press(ka, on: surface)
        XCTAssertEqual(session.composition, "か")
        press(ka, on: surface)
        XCTAssertEqual(session.composition, "き", "A second tap continues the toggle cycle")
        press(try key("vime.kana.next", in: keyboard), on: surface)
        press(ka, on: surface)
        XCTAssertEqual(session.composition, "きか", "→ ends the toggle so the same key starts a new kana")
        press(try key("vime.kana.ta", in: keyboard), on: surface, dx: -30)
        XCTAssertEqual(session.composition, "きかち")
        press(try key("vime.kana.modifier", in: keyboard), on: surface)
        XCTAssertEqual(session.composition, "きかぢ")
        press(try key("vime.kana.a", in: keyboard), on: surface, dy: -30)
        press(try key("vime.kana.reverse", in: keyboard), on: surface)
        XCTAssertEqual(session.composition, "きかぢい", "↶ steps back from う")
        press(try key("vime.kana.wa", in: keyboard), on: surface, dx: 30)
        XCTAssertEqual(session.composition, "きかぢいー")
    }

    func testFlickOffTheTopRowStillEntersItsKana() throws {
        let (keyboard, surface, session) = makeKeyboard()
        let a = try key("vime.kana.a", in: keyboard)
        // A long upward flick leaves the key plane; it is a selection, not a cancel.
        press(a, on: surface, dy: -(a.frame.midY + 10))
        XCTAssertEqual(session.composition, "う")
    }

    func testPunctuationTitleListsItsOutputsWithoutHints() throws {
        let (keyboard, _, _) = makeKeyboard()
        func hints(_ key: KeyboardKey) -> [String] {
            key.subviews.compactMap { ($0 as? UILabel)?.text }.filter { $0 != key.title(for: .normal) && !$0.isEmpty }
        }
        let ka = try key("vime.kana.ka", in: keyboard)
        XCTAssertTrue(Set(["き", "く", "け", "こ"]).isSubset(of: hints(ka)))
        let punctuation = try key("vime.kana.punctuation", in: keyboard)
        XCTAssertTrue(Set(hints(punctuation)).isDisjoint(with: KeyboardKanaLayout.punctuation))
    }

    func testConfirmSpansTwoRowsAndOwnsItsColumn() throws {
        let (keyboard, surface, _) = makeKeyboard()
        let confirm = try key("vime.key.return", in: keyboard)
        let space = try key("vime.key.space", in: keyboard)
        let punctuation = try key("vime.kana.punctuation", in: keyboard)
        XCTAssertGreaterThan(confirm.frame.height, space.frame.height * 1.8)
        XCTAssertEqual(confirm.frame.minX, space.frame.minX, accuracy: 0.001)
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: confirm.frame.midX, y: punctuation.frame.midY)) === confirm)
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: confirm.frame.midX, y: keyboard.bounds.height - 1)) === confirm)
        let gap = (punctuation.frame.maxX + confirm.frame.minX) / 2
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: gap - 0.5, y: punctuation.frame.midY)) === punctuation)
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: gap + 0.5, y: punctuation.frame.midY)) === confirm)
    }

    func testEnglishUsesQWERTYAndJapaneseReturnsToThePad() throws {
        let (keyboard, _, _) = makeKeyboard()
        try key("vime.key.language", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertNotNil(try key("vime.key.q", in: keyboard))
        XCTAssertFalse(descendants(keyboard).contains { $0.accessibilityIdentifier == "vime.kana.a" })
        try key("vime.key.language", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertNotNil(try key("vime.kana.a", in: keyboard))
        let (romaji, _, _) = makeKeyboard(kana: false)
        XCTAssertNotNil(try key("vime.key.q", in: romaji))
    }

    func testEditingTheLastKanaWaitsForASelectedCandidate() {
        let session = KeyboardSession()
        XCTAssertNil(session.replaceLastKana { _ in "が" }, "Nothing composed")
        _ = session.type("か")
        XCTAssertNotNil(session.replaceLastKana(KeyboardKanaLayout.modified))
        XCTAssertEqual(session.composition, "が")
        _ = session.space()
        if session.selectedIndex != nil {
            XCTAssertNil(session.replaceLastKana(KeyboardKanaLayout.modified))
        }
    }

    func testNextWordSuggestionsTakeTheWholeRowAndYieldToComposition() {
        func chrome(composing: Bool, quick: Bool = false, page: KeyboardView.Page = .letters) -> KeyboardView.ChromeState {
            KeyboardView.ChromeState(panel: .keyboard, page: page, composing: composing, sessionStrip: true,
                                     quickAvailable: quick, clipboardOffered: false, neuralPaused: false, canUndo: false,
                                     supportsPrimaryVariant: false, hasConversionRange: false)
        }
        let idle = chrome(composing: false)
        XCTAssertTrue(idle.showsNextWords)
        XCTAssertTrue(idle.hidesBrand, "Suggestions use the whole row")
        let composing = chrome(composing: true)
        XCTAssertFalse(composing.showsNextWords)
        XCTAssertTrue(composing.hidesBrand)
        XCTAssertFalse(chrome(composing: false, quick: true).showsNextWords)
    }
}
