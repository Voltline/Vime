import XCTest

final class ChineseMixedInputTests: XCTestCase {
    private func texts(_ input: String) -> [[String]] {
        ChineseMixedInput.splits(for: input).map { $0.map {
            switch $0 { case .pinyin(let text): "py:" + text; case .raw(let text): "raw:" + text }
        } }
    }

    func testPinyinAloneIsLeftToRime() {
        XCTAssertEqual(texts("nihao"), [])
        XCTAssertEqual(texts("wozhengzaixiug"), [], "a half-typed syllable at the end still reads as pinyin")
        XCTAssertEqual(texts("ni hao"), [])
    }

    func testTheWordIsKeptAndThePinyinAfterItGoesOn() {
        let found = texts("jinxingvimedexiugai")
        XCTAssertEqual(found.first, ["py:jinxing", "raw:vime", "py:dexiugai"], "a word ending in e before an initial comes first")
        XCTAssertTrue(found.contains(["py:jinxing", "raw:vi", "py:medexiugai"]), "other ends stay for the model")
        XCTAssertTrue(found.allSatisfy { $0.joined().replacingOccurrences(of: "py:", with: "")
            .replacingOccurrences(of: "raw:", with: "") == "jinxingvimedexiugai" })
    }

    func testAWordAtTheEndIsKeptWhole() {
        XCTAssertEqual(texts("jinxingvim").first, ["py:jinxing", "raw:vim"])
    }

    func testTwoWordsInOneSentence() {
        XCTAssertTrue(texts("kanyixiagithubshangdeissue").contains(["py:kanyixia", "raw:github", "py:shangde", "raw:issue"]))
    }

    func testOptionsJoinRimesReadings() {
        let splits = [[ChineseMixedInput.Segment.pinyin("jinxing"), .raw("vime"), .pinyin("de")],
                      [.pinyin("jinxing"), .raw("vimede")]]
        let options = ChineseMixedInput.options(splits, converted: [
            ("jinxing", [RimeCandidate(text: "進行", comment: nil, genuine: "进行")]),
            ("de", [RimeCandidate(text: "的", comment: nil)]),
        ])
        XCTAssertEqual(options.map(\.text), ["進行vime的", "進行vimede"])
        XCTAssertEqual(options.map(\.genuine), ["进行vime的", "进行vimede"])
        XCTAssertEqual(ChineseMixedInput.ranked(options, scores: [-9, -3]).map(\.text), ["進行vimede", "進行vime的"])
        XCTAssertEqual(ChineseMixedInput.ranked(options, scores: nil).map(\.text), ["進行vime的", "進行vimede"])
    }
}
