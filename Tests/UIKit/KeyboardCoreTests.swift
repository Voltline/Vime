import XCTest

@MainActor
final class KeyboardCoreTests: XCTestCase {
    func testSharedPreferencesMigrateWithoutOverwritingExistingChoices() throws {
        let legacyName = "vime.preferences.legacy.\(UUID().uuidString)"
        let sharedName = "vime.preferences.shared.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacyName))
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedName))
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            shared.removePersistentDomain(forName: sharedName)
        }
        legacy.set(false, forKey: "vime.sound")
        legacy.set("midnight", forKey: "vime.theme")
        shared.set("system", forKey: "vime.theme")
        let app = KeyboardPreferences(defaults: legacy, sharedDefaults: shared)
        XCTAssertFalse(app.sound)
        XCTAssertEqual(app.theme, .system)
        app.candidateRanking = .engine
        app.phraseSuggestions = false
        app.heightFactor = 1.2
        let keyboard = KeyboardPreferences(defaults: legacy, sharedDefaults: shared)
        XCTAssertEqual(keyboard.snapshot, app.snapshot)
        XCTAssertEqual(keyboard.candidateRanking, .engine)
        XCTAssertFalse(keyboard.phraseSuggestions)
        XCTAssertEqual(keyboard.heightFactor, 1.2)
        keyboard.sound = true
        XCTAssertTrue(app.sound)
        XCTAssertTrue(KeyboardPreferences(defaults: legacy, sharedDefaults: shared).sound)
    }

    func testRomajiAndVisibleKanaDeletion() {
        let session = KeyboardSession()
        for (raw, kana) in [("nihongo", "にほんご"), ("shi", "し"), ("si", "し"), ("chi", "ち"),
                            ("tsu", "つ"), ("kya", "きゃ"), ("gakkou", "がっこう"),
                            ("sonnna", "そんな"), ("ko-hi-", "こーひー")] {
            session.reset()
            for c in raw { XCTAssertTrue(session.type(String(c)).isEmpty) }
            XCTAssertEqual(session.composition, kana, raw)
        }
        session.reset()
        _ = session.type("sonnna")
        _ = session.backspace(); XCTAssertEqual(session.composition, "そん")
        _ = session.backspace(); XCTAssertEqual(session.composition, "そ")
        _ = session.backspace(); XCTAssertFalse(session.isComposing)
        XCTAssertEqual(session.backspace(), [.deleteBackward])
        _ = session.type("nn")
        XCTAssertEqual(session.composition, "ん")
        _ = session.backspace(); XCTAssertFalse(session.isComposing, "nn must disappear as one displayed kana")
        _ = session.type("shi")
        _ = session.backspace(); XCTAssertFalse(session.isComposing)
        _ = session.type("kya")
        _ = session.backspace(); XCTAssertEqual(session.composition, "き")
        _ = session.backspace(); XCTAssertFalse(session.isComposing)
        _ = session.type("sh")
        _ = session.backspace(); XCTAssertEqual(session.composition, "s")
        _ = session.type("hi"); XCTAssertEqual(session.composition, "し")
    }

    func testEngineRankingAndSentenceConversion() {
        let session = KeyboardSession()
        for (raw, first) in [("nihongo", "日本語"), ("naniwo", "何を"), ("kyou", "今日")] {
            session.reset(); _ = session.type(raw)
            print("\(raw): \(session.candidates)")
            XCTAssertEqual(session.candidates.first, first)
            XCTAssertEqual(Set(session.candidates).count, session.candidates.count)
            if raw == "naniwo", let partial = session.candidateSnapshots.first(where: { $0.text == "何" }) {
                XCTAssertEqual(partial.remainingComposition.convertTarget, "を", "Partial conversion keeps its remainder")
            }
        }
        session.reset(); _ = session.type("watashihanihongowobenkyoushiteimasu")
        print("Sentence: \(session.candidates)")
        XCTAssertTrue(session.candidates.contains("私は日本語を勉強しています"))
    }

    func testConfirmationModeAndLongVowel() {
        let session = KeyboardSession()
        _ = session.type("nihongo"); _ = session.space()
        XCTAssertEqual(session.selectedText, "日本語")
        XCTAssertEqual(session.enter(), [.insert("日本語")])
        XCTAssertEqual(session.enter(), [.returnKey])
        _ = session.type("kan")
        XCTAssertEqual(session.insertLiteral("。"), [.insert("かん"), .insert("。")])
        _ = session.toggleEnglish()
        XCTAssertEqual(session.type("Hello"), [.insert("Hello")])
        _ = session.toggleEnglish(); _ = session.toggleKana()
        _ = session.type("koーhiー")
        XCTAssertEqual(session.composition, "コーヒー")
        XCTAssertEqual(session.enter(), [.insert("コーヒー")])
        _ = session.type("nihongo"); _ = session.space()
        _ = session.backspace(); XCTAssertNil(session.selectedIndex)
        XCTAssertEqual(session.composition, "ニホンゴ")
    }

    func testSwipeThresholdReversalAndPreferences() {
        var swipe = KeySwipeSelection()
        swipe.move(x: 0, y: -10); XCTAssertFalse(swipe.alternate)
        swipe.move(x: 2, y: -32); XCTAssertTrue(swipe.alternate)
        swipe.move(x: 50, y: -32); XCTAssertFalse(swipe.alternate)
        swipe.move(x: 0, y: -32); swipe.reset(); XCTAssertFalse(swipe.alternate)
        let name = "vime.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = KeyboardPreferences(defaults: defaults)
        XCTAssertTrue(prefs.sound && prefs.nineKeyNumbers && prefs.prolongedKey)
        prefs.hapticLevel = 99; XCTAssertEqual(prefs.hapticLevel, 5)
        prefs.hapticLevel = -1; XCTAssertEqual(prefs.hapticLevel, 0)
        prefs.nineKeyNumbers = false; prefs.prolongedKey = false
        let reloaded = KeyboardPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.nineKeyNumbers || reloaded.prolongedKey)
    }
}
