import XCTest
@testable import Vime

final class LateCorrectionMarkTests: XCTestCase {
    func testSubstitutionsMarkOnlyTheReplacedCharacters() {
        XCTAssertEqual(LateCorrectionMark.changedCharacters(from: "今天天汽很好", to: "今天天气很好"), [3])
        XCTAssertEqual(LateCorrectionMark.changedCharacters(from: "我在西安人", to: "我在先人"), [2])
        XCTAssertEqual(LateCorrectionMark.changedCharacters(from: "一起去吃反", to: "一齐去吃饭"), [1, 4])
    }

    func testInsertedCharactersAreMarked() {
        XCTAssertEqual(LateCorrectionMark.changedCharacters(from: "明天见", to: "明天再见"), [2])
        XCTAssertEqual(LateCorrectionMark.changedCharacters(from: "", to: "你好"), [0, 1])
    }

    func testIdenticalOrShorterLeadsMarkNothingExtra() {
        XCTAssertEqual(LateCorrectionMark.changedCharacters(from: "你好", to: "你好"), [])
        XCTAssertEqual(LateCorrectionMark.changedCharacters(from: "你好吗", to: "你好"), [])
    }

    func testMinimumChangesKeepsSingleCharacterFixesQuiet() {
        XCTAssertGreaterThan(LateCorrectionMark.minimumChanges, 1)
    }
}
