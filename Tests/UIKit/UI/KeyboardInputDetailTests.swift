import XCTest
import UIKit

@MainActor
final class KeyboardInputDetailTests: XCTestCase {
    private func preferences() throws -> KeyboardPreferences {
        let suite = "VimeInputDetail." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return KeyboardPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    func testDeleteWithNothingToDeleteAnswersEveryPressButNeverRepeats() {
        let key = KeyboardKey()
        var feedback = 0, actions = 0
        key.repeats = true
        key.canRepeat = { false }
        key.feedback = { feedback += 1 }
        key.action = { actions += 1 }
        for press in 1...3 {
            key.beginResolvedPress(deferRepeatingAction: true)
            XCTAssertTrue(key.isHighlighted)
            XCTAssertEqual(feedback, press, "Each press answers once")
            key.finishResolvedPress(cancelled: false, alternate: false, stillPressed: false, deferredRepeat: true)
            XCTAssertFalse(key.isHighlighted)
        }
        XCTAssertEqual(actions, 0)

        // A hold with nothing to delete answers once and starts no repeat.
        key.beginResolvedPress(deferRepeatingAction: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(feedback, 4)
        XCTAssertEqual(actions, 0)
        key.finishResolvedPress(cancelled: false, alternate: false, stillPressed: false, deferredRepeat: true)
    }

    func testSwipeSymbolsFollowTheJapaneseFullWidthSetting() throws {
        let preferences = try preferences()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: KeyboardSession(),
                                    preferences: preferences)
        defer { keyboard.stopInteractions() }
        XCTAssertEqual(["b", "n", "g", "h", "z"].map { keyboard.swipeSymbol(for: $0) }, ["？", "！", "（", "）", "＠"])
        preferences.japaneseFullWidthSymbols = false
        XCTAssertEqual(["b", "n", "g", "h", "z"].map { keyboard.swipeSymbol(for: $0) }, ["?", "!", "(", ")", "@"])
        // Chinese punctuation is a setting of its own.
        preferences.japaneseFullWidthSymbols = true
        preferences.chinesePunctuation = false
        XCTAssertEqual(keyboard.swipeSymbol(for: "b"), "？")
    }

}
