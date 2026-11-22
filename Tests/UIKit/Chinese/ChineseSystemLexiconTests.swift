import XCTest
@testable import VimeKeyboard

@MainActor
final class ChineseSystemLexiconTests: XCTestCase {
    override func tearDown() {
        ChineseSystemLexicon.clear()
        super.tearDown()
    }

    func testMatchesReplacementsAndChineseContactsByFullAndInitialPinyin() {
        ChineseSystemLexicon.update(
            replacements: [
                (shortcut: "dz", phrase: "北京市朝阳区"),
                (shortcut: "DZ", phrase: "上海市徐汇区"),
                (shortcut: "かな", phrase: "仮名"), // Non-ASCII skipped for Chinese
                (shortcut: "myemail", phrase: "hello@example.com"),
            ],
            contacts: [
                "张三",
                "李明",
                "Alice", // Non-Chinese contact skipped
            ]
        )

        XCTAssertEqual(ChineseSystemLexicon.matches(for: "dz"), ["北京市朝阳区", "上海市徐汇区"])
        XCTAssertEqual(ChineseSystemLexicon.matches(for: "myemail"), ["hello@example.com"])
        XCTAssertEqual(ChineseSystemLexicon.matches(for: "zhangsan"), ["张三"])
        XCTAssertEqual(ChineseSystemLexicon.matches(for: "zs"), ["张三"])
        XCTAssertEqual(ChineseSystemLexicon.matches(for: "liming"), ["李明"])
        XCTAssertEqual(ChineseSystemLexicon.matches(for: "lm"), ["李明"])
        XCTAssertTrue(ChineseSystemLexicon.matches(for: "alice").isEmpty)
    }

    func testReplacementsLeadContactsAndClearEmptiesStore() {
        ChineseSystemLexicon.update(
            replacements: [(shortcut: "zs", phrase: "正式版")],
            contacts: ["张三"]
        )
        XCTAssertEqual(ChineseSystemLexicon.matches(for: "zs"), ["正式版", "张三"])

        ChineseSystemLexicon.clear()
        XCTAssertTrue(ChineseSystemLexicon.matches(for: "zs").isEmpty)
    }

    func testChineseInputSessionSurfacesSystemLexiconCandidates() throws {
        guard let session = ChineseInputSession.bundled() else {
            throw XCTSkip("Bundled Rime data unavailable")
        }
        ChineseSystemLexicon.update(
            replacements: [(shortcut: "myaddr", phrase: "火星基地一号")],
            contacts: ["张三"]
        )

        for ch in "myaddr" {
            _ = session.type(String(ch))
        }
        let exp = expectation(description: "candidates ready")
        func poll() {
            if session.candidatesAreCurrent && !session.candidatePresentations.isEmpty {
                exp.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
        wait(for: [exp], timeout: 5.0)

        XCTAssertTrue(session.candidatePresentations.map(\.text).contains("火星基地一号"))

        session.reset()
        for ch in "zhangsan" {
            _ = session.type(String(ch))
        }
        let exp2 = expectation(description: "contact candidates ready")
        func poll2() {
            if session.candidatesAreCurrent && !session.candidatePresentations.isEmpty {
                exp2.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll2)
            }
        }
        poll2()
        wait(for: [exp2], timeout: 5.0)
        XCTAssertTrue(session.candidatePresentations.map(\.text).contains("张三"))
    }
}
