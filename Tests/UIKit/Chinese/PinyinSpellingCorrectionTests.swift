import XCTest

final class PinyinSpellingCorrectionTests: XCTestCase {
    private func sentence(_ text: String) -> RimeCandidate { RimeCandidate(text: text, comment: nil, coversInput: true, sentence: true) }
    private func phrase(_ text: String) -> RimeCandidate { RimeCandidate(text: text, comment: nil, coversInput: true, quality: 1) }

    func testSyllableCounts() {
        XCTAssertEqual(PinyinSpellingCorrection.syllableCount("maoai"), 2)
        XCTAssertEqual(PinyinSpellingCorrection.syllableCount("xian"), 1, "the fewest syllables, not xi an")
        XCTAssertEqual(PinyinSpellingCorrection.syllableCount("woxiangshuo"), 3)
        XCTAssertNil(PinyinSpellingCorrection.syllableCount("shenem"))
    }

    func testNeighbouringKeys() {
        XCTAssertEqual(PinyinSpellingCorrection.neighbours(of: "s"), ["a", "d", "z", "e", "w"])
        XCTAssertEqual(PinyinSpellingCorrection.neighbours(of: "a"), ["s", "q", "w"])
        XCTAssertTrue(PinyinSpellingCorrection.spellings(for: "maoai").contains("maosi"))
        XCTAssertTrue(PinyinSpellingCorrection.spellings(for: "wixiang").contains("woxiang"))
        XCTAssertTrue(PinyinSpellingCorrection.spellings(for: "maoai").allSatisfy(PinyinSpellingCorrection.isFullSyllables))
    }

    func testFullSyllablesOfAWordWithoutOneAreLookedUp() {
        XCTAssertTrue(PinyinSpellingCorrection.wantsCorrection("maoai", top: sentence("毛爱")))
        XCTAssertFalse(PinyinSpellingCorrection.wantsCorrection("maosi", top: phrase("貌似")), "Rime has the word")
        XCTAssertFalse(PinyinSpellingCorrection.wantsCorrection("wojuedehenhao", top: sentence("我觉得很好")),
                       "a sentence of more than four syllables")
        XCTAssertTrue(PinyinSpellingCorrection.wantsCorrection("shenem", top: sentence("什么")))
        XCTAssertFalse(PinyinSpellingCorrection.wantsCorrection("mao", top: sentence("毛")), "too short")
    }
}
