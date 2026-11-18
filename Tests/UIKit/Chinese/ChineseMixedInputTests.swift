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
        let found = texts("kanyixiagithubshangdeissue")
        XCTAssertTrue(found.contains(["py:kanyixia", "raw:github", "py:shangde", "raw:issue"]), "\(found)")
    }

    func testAbbreviationsReadAsPinyinAsRimeReadsThem() {
        XCTAssertEqual(texts("wsmzhegeshurufa"), [], "wsm is 为什么 to Rime")
        XCTAssertEqual(texts("nhzgsrf"), [])
        XCTAssertEqual(texts("wsmzhegeshurufavime").first, ["py:wsmzhegeshurufa", "raw:vime"])
        XCTAssertEqual(texts("wsmvimedexiugai").first, ["py:wsm", "raw:vime", "py:dexiugai"])
        let github = texts("kanyixiagithub")
        XCTAssertEqual(github.first?.prefix(2), ["py:kanyixia", "raw:git"], "the word starts at g, not kanyixiag|ithub")
        XCTAssertTrue(github.contains(["py:kanyixia", "raw:github"]))
        XCTAssertEqual(texts("vimehenhaoyong").first, ["raw:vime", "py:henhaoyong"])
    }

    func testOneWordComesBeforeTwo() {
        XCTAssertEqual(texts("womenzaigithubshangtijiaole").first, ["py:womenzai", "raw:github", "py:shangtijiaole"],
                       "not git|hu|bs|hang")
    }

    func testAWordRimeReadsAsAbbreviationsIsKeptToo() {
        // Rime reads these whole (这个不过我, 我用朋友通红); the model weighs the words.
        XCTAssertEqual(texts("zhegebugwomingtian").first, ["py:zhege", "raw:bug", "py:womingtian"], "not zhegebu|gwo")
        XCTAssertEqual(texts("woyongpythonxielejiaoben").first, ["py:woyong", "raw:python", "py:xielejiaoben"])
        XCTAssertTrue(texts("bangwokanyixiacommitxinxi").contains(["py:bangwokanyixia", "raw:commit", "py:xinxi"]))
        XCTAssertTrue(texts("woyongxcodedabao").contains(["py:woyong", "raw:xcode", "py:dabao"]))
        // A word needs a vowel and spelled-out pinyin before it.
        XCTAssertEqual(texts("zhegedfwm").filter { $0.contains("raw:dfwm") }, [])
        XCTAssertEqual(texts("nhzgsrf"), [])
        XCTAssertEqual(texts("zhegebug"), [], "bu|g reads as pinyin until the next letter")
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

    func testACapitalStartsAWordKeptAsTyped() {
        let py = ChineseMixedInput.Segment.pinyin, raw = ChineseMixedInput.Segment.raw
        XCTAssertEqual(ChineseMixedInput.splits(for: "jintianyongVimedazi").first, [py("jintianyong"), raw("Vime"), py("dazi")])
        XCTAssertEqual(ChineseMixedInput.splits(for: "Vimehenhaoyong").first, [raw("Vime"), py("henhaoyong")])
        XCTAssertEqual(ChineseMixedInput.splits(for: "woyongGPTxiezuoye"), [[py("woyong"), raw("GPT"), py("xiezuoye")]])
        XCTAssertEqual(ChineseMixedInput.splits(for: "Ta").first, [raw("Ta")], "a capital is never pinyin")
        XCTAssertEqual(ChineseMixedInput.splits(for: "maileMcDonald").first, [py("maile"), raw("McDonald")])
        XCTAssertFalse(ChineseMixedInput.splits(for: "jintianyongVimedazi").contains { $0.contains(raw("V")) },
                       "the lowercase letters right after a capital belong to its word unless they read as pinyin")
    }
}
