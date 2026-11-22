import XCTest
@testable import VimeKeyboard

@MainActor
final class ChineseSystemLexiconTests: XCTestCase {
    override func tearDown() {
        ChineseSystemLexicon.clear()
        super.tearDown()
    }

    func testReplacementsContactsInitialsPolicyAndSingleCharExclusion() {
        ChineseSystemLexicon.update(
            replacements: [
                (shortcut: "dz", phrase: "北京市朝阳区"),
                (shortcut: "DZ", phrase: "上海市徐汇区"),
                (shortcut: "かな", phrase: "仮名"), // Non-ASCII skipped for Chinese
                (shortcut: "myemail", phrase: "hello@example.com"),
            ],
            contacts: [
                "王",       // Single-char name must be excluded
                "王军",     // 2-char name: full pinyin only, NO initials (`wj`)
                "张小明",   // 3-char name: both full pinyin and initials (`zxm`)
                "Alice",    // Non-Chinese contact skipped
            ]
        )

        XCTAssertEqual(ChineseSystemLexicon.replacements(for: "dz"), ["北京市朝阳区", "上海市徐汇区"])
        XCTAssertEqual(ChineseSystemLexicon.replacements(for: "myemail"), ["hello@example.com"])

        // Single-character contact name is excluded
        XCTAssertTrue(ChineseSystemLexicon.contacts(for: "wang").isEmpty)

        // 2-character name matches full pinyin only, never 2-letter initials
        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "wangjun"), ["王军"])
        XCTAssertTrue(ChineseSystemLexicon.contacts(for: "wj").isEmpty)

        // 3-character name matches both full pinyin and 3-letter initials
        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "zhangxiaoming"), ["张小明"])
        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "zxm"), ["张小明"])

        XCTAssertTrue(ChineseSystemLexicon.contacts(for: "alice").isEmpty)
    }

    func testPolyphonicSurnameOverrides() {
        ChineseSystemLexicon.update(
            replacements: [],
            contacts: [
                "单伟",
                "曾强",
                "解敏",
                "仇明",
                "区浩",
                "朴树",
                "单小明",
            ]
        )

        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "shanwei"), ["单伟"])
        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "zengqiang"), ["曾强"])
        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "xiemin"), ["解敏"])
        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "qiuming"), ["仇明"])
        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "ouhao"), ["区浩"])
        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "piaoshu"), ["朴树"])
        // Initials for 3-char polyphonic surname use overridden surname initial (`s` for 单)
        XCTAssertEqual(ChineseSystemLexicon.contacts(for: "sxm"), ["单小明"])
    }

    func testSlotOrderReplacementsLeadAndContactsFollowSecondCandidate() {
        let slots = ChineseCandidateList.slots(
            rime: ["文件", "危机", "晚间"],
            order: [0, 1, 2],
            corrections: [],
            correctionLeads: false,
            mixed: 0,
            placement: .none,
            phrases: ["自定义短语"],
            contacts: ["王军"]
        )
        // Phrases/replacements lead at slot 0; contacts appear after the 2nd candidate (index 2).
        XCTAssertEqual(slots, [.phrase(0), .rime(0), .contact(0), .rime(1), .rime(2)])
    }

    func testChineseInputSessionPlacesReplacementsFirstAndContactsAfterSecond() throws {
        guard let session = ChineseInputSession.bundled() else {
            throw XCTSkip("Bundled Rime data unavailable")
        }
        ChineseSystemLexicon.update(
            replacements: [(shortcut: "myaddr", phrase: "火星基地一号")],
            contacts: ["王军", "林语棠"]
        )

        // 1. Text replacement appears at slot 0
        for ch in "myaddr" {
            _ = session.type(String(ch))
        }
        let exp1 = expectation(description: "replacement ready")
        func poll1() {
            if session.candidatesAreCurrent && !session.candidatePresentations.isEmpty { exp1.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll1) }
        }
        poll1()
        wait(for: [exp1], timeout: 5.0)
        XCTAssertEqual(session.candidatePresentations.first?.text, "火星基地一号")

        // 2. 2-char contact name never displaces `wj` (文件)
        session.reset()
        for ch in "wj" {
            _ = session.type(String(ch))
        }
        let exp2 = expectation(description: "wj ready")
        func poll2() {
            if session.candidatesAreCurrent && !session.candidatePresentations.isEmpty { exp2.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll2) }
        }
        poll2()
        wait(for: [exp2], timeout: 5.0)
        XCTAssertFalse(session.candidatePresentations.map(\.text).contains("王军"))

        // 3. Full pinyin / 3-char initials contact appears after the 2nd slot (index >= 2)
        session.reset()
        for ch in "lyt" {
            _ = session.type(String(ch))
        }
        let exp3 = expectation(description: "lyt ready")
        func poll3() {
            if session.candidatesAreCurrent && session.candidatePresentations.count >= 3 { exp3.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll3) }
        }
        poll3()
        wait(for: [exp3], timeout: 5.0)
        let texts = session.candidatePresentations.map(\.text)
        XCTAssertTrue(texts.contains("林语棠"))
        XCTAssertEqual(texts.firstIndex(of: "林语棠"), 2, "Contact name must appear right after the 2nd candidate")
    }
}
