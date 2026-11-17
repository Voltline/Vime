import XCTest
import UIKit

@MainActor
final class KeyHitCorrectionTests: XCTestCase {
    private func letters(_ prior: KeyHitCorrection.Prior?, _ set: String) -> String {
        guard let prior else { return "nil" }
        return String(set.filter { prior($0) >= KeyHitCorrection.plausible })
    }

    func testRomajiContinuations() {
        let all = "abcdefghijklmnopqrstuvwxyz"
        XCTAssertEqual(letters(KeyHitCorrection.romajiPrior(after: ""), all), all, "any letter starts a kana")
        XCTAssertEqual(letters(KeyHitCorrection.romajiPrior(after: "ky"), all), "aeiou")
        XCTAssertEqual(letters(KeyHitCorrection.romajiPrior(after: "sh"), "aeioupy"), "aeiou")
        XCTAssertEqual(KeyHitCorrection.romajiPrior(after: "k")?("k"), 1, "doubled consonant is っ")
        XCTAssertEqual(KeyHitCorrection.romajiPrior(after: "k")?("y"), 1)
        XCTAssertEqual(KeyHitCorrection.romajiPrior(after: "k")?("p"), 0)
        XCTAssertEqual(KeyHitCorrection.romajiPrior(after: "kan")?("k"), 1, "n before a consonant is ん")
        XCTAssertEqual(KeyHitCorrection.romajiPrior(after: "kyou")?("p"), 1, "a new kana starts after a whole one")
        XCTAssertEqual(KeyHitCorrection.romajiPrior(after: "tsu-")?("k"), 1)
        XCTAssertNil(KeyHitCorrection.romajiPrior(after: "Word"), "capitals are not romaji")
    }

    func testPinyinContinuations() {
        XCTAssertEqual(KeyHitCorrection.pinyinPrior(after: "zh")?("a"), 1)
        XCTAssertEqual(KeyHitCorrection.pinyinPrior(after: "q")?("i"), 1)
        let abbreviated = KeyHitCorrection.pinyinPrior(after: "q")?("o") ?? 1
        XCTAssertLessThan(abbreviated, KeyHitCorrection.implausible, "q then o needs q as an abbreviation")
        XCTAssertGreaterThan(abbreviated, 0)
        XCTAssertEqual(KeyHitCorrection.pinyinPrior(after: "xian")?("g"), 1)
        XCTAssertEqual(KeyHitCorrection.pinyinPrior(after: "xian")?("f"), 1, "a new syllable after a whole one")
        XCTAssertGreaterThan(KeyHitCorrection.pinyinPrior(after: "wm")?("x") ?? 0, 0, "initials-only input stays possible")
        XCTAssertEqual(KeyHitCorrection.pinyinPrior(after: "ni'h")?("a"), 1)
        XCTAssertNil(KeyHitCorrection.pinyinPrior(after: "iphone"), "English words are left alone")
    }

    func testOnlyEdgeTapsOnImplausibleLettersMove() {
        let o = KeyHitCorrection.Key(letter: "o", body: CGRect(x: 300, y: 10, width: 32, height: 42))
        let p = KeyHitCorrection.Key(letter: "p", body: CGRect(x: 338, y: 10, width: 32, height: 42))
        let afterKy = { KeyHitCorrection.romajiPrior(after: "ky") }
        XCTAssertEqual(KeyHitCorrection.replacement(at: CGPoint(x: 340, y: 30), touched: p, neighbours: [o], prior: afterKy), "o")
        XCTAssertNil(KeyHitCorrection.replacement(at: CGPoint(x: 354, y: 30), touched: p, neighbours: [o], prior: afterKy),
                     "a tap in the middle of the key is never moved")
        XCTAssertNil(KeyHitCorrection.replacement(at: CGPoint(x: 302, y: 30), touched: o, neighbours: [p], prior: afterKy),
                     "a plausible letter is never moved")
        var asked = false
        _ = KeyHitCorrection.replacement(at: CGPoint(x: 354, y: 30), touched: p, neighbours: [o]) { asked = true; return nil }
        XCTAssertFalse(asked, "the language is not consulted for taps out of a neighbour's reach")
    }

    private func region(_ surface: KeyboardTouchSurface, _ letter: Character) throws -> KeyboardTouchSurface.Region {
        try XCTUnwrap(surface.regions.first { $0.key.accessibilityIdentifier == "vime.key." + String(letter) })
    }

    func testEdgeTapTypesTheLetterThatContinuesRomaji() throws {
        let session = KeyboardSession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        defer { keyboard.stopInteractions() }
        keyboard.layoutIfNeeded()
        let surface = try XCTUnwrap(keyboard.subviews.compactMap { $0 as? KeyboardTouchSurface }.first)
        func tap(_ point: CGPoint, id: Int) { surface.beginPress(id: id, at: point); surface.endPress(id: id, at: point) }
        for (index, letter) in "ky".enumerated() {
            let body = try region(surface, letter).body
            tap(CGPoint(x: body.midX, y: body.midY), id: index)
        }
        let p = try region(surface, "p").body
        tap(CGPoint(x: p.minX + 1, y: p.midY), id: 10)
        XCTAssertEqual(session.raw, "kyo", "an edge tap on p after ky types o")
        tap(CGPoint(x: p.midX, y: p.midY), id: 11)
        XCTAssertEqual(session.raw, "kyop", "a centered tap types what it hits")
    }

    func testHeldKeysCountAsTyped() throws {
        let session = KeyboardSession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        defer { keyboard.stopInteractions() }
        keyboard.layoutIfNeeded()
        let surface = try XCTUnwrap(keyboard.subviews.compactMap { $0 as? KeyboardTouchSurface }.first)
        let k = try region(surface, "k").body, y = try region(surface, "y").body, p = try region(surface, "p").body
        let kCenter = CGPoint(x: k.midX, y: k.midY), yCenter = CGPoint(x: y.midX, y: y.midY)
        let pEdge = CGPoint(x: p.minX + 1, y: p.midY)
        // Rolling: k and y are still down when p lands.
        surface.beginPress(id: 1, at: kCenter); surface.beginPress(id: 2, at: yCenter); surface.beginPress(id: 3, at: pEdge)
        surface.endPress(id: 1, at: kCenter); surface.endPress(id: 2, at: yCenter); surface.endPress(id: 3, at: pEdge)
        XCTAssertEqual(session.raw, "kyo")
    }
}
