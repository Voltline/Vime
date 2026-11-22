import XCTest
@testable import VimeKeyboard

@MainActor
final class ChineseSpecialConversionsTests: XCTestCase {
    private var fixedDate: Date {
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        comps.year = 2026
        comps.month = 11
        comps.day = 22
        comps.hour = 14
        comps.minute = 5
        comps.second = 30
        return comps.date!
    }

    private var shanghaiTZ: TimeZone {
        TimeZone(secondsFromGMT: 8 * 3600)!
    }

    func testDateTimeWeekdayAndLunarTriggers() {
        let now = fixedDate
        let tz = shanghaiTZ

        // Date: single format matching user preference
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "rq", now: now, options: .init(dateFormat: .chinese), timeZone: tz).map(\.text),
            ["2026年11月22日"]
        )
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "riqi", now: now, options: .init(dateFormat: .hyphen), timeZone: tz).map(\.text),
            ["2026-11-22"]
        )
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "mt", now: now, options: .init(dateFormat: .slash), timeZone: tz).map(\.text),
            ["2026/11/23"]
        )
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "zt", now: now, options: .init(dateFormat: .chinese), timeZone: tz).map(\.text),
            ["2026年11月21日"]
        )

        // Time: single format matching user preference
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "sj", now: now, options: .init(timeFormat: .colon), timeZone: tz).map(\.text),
            ["14:05"]
        )
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "shijian", now: now, options: .init(timeFormat: .chinese), timeZone: tz).map(\.text),
            ["14时05分"]
        )
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "sj", now: now, options: .init(timeFormat: .chinese, traditional: true), timeZone: tz).map(\.text),
            ["14時05分"]
        )

        // Weekday: xq/xingqi -> 星期日, zj/zhouji -> 周日 / 週日
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "xq", now: now, timeZone: tz).map(\.text),
            ["星期日"]
        )
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "xingqi", now: now, timeZone: tz).map(\.text),
            ["星期日"]
        )
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "zj", now: now, timeZone: tz).map(\.text),
            ["周日"]
        )
        XCTAssertEqual(
            ChineseSpecialConversions.candidates(for: "zhouji", now: now, options: .init(traditional: true), timeZone: tz).map(\.text),
            ["週日"]
        )

        // Lunar: full 干支年+月+日 format (without trailing 日) using Calendar(identifier: .chinese)
        let lunar = ChineseSpecialConversions.candidates(for: "nl", now: now, timeZone: tz).map(\.text)
        XCTAssertEqual(lunar, ["丙午年十月十四"])
        let lunarFull = ChineseSpecialConversions.candidates(for: "nongli", now: now, timeZone: tz).map(\.text)
        XCTAssertEqual(lunarFull, ["丙午年十月十四"])
    }

    func testRMBUppercaseFormatting() {
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("0"), "零元整")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("0.00"), "零元整")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("1234"), "壹仟贰佰叁拾肆元整")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("1234.56"), "壹仟贰佰叁拾肆元伍角陆分")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("1234.5"), "壹仟贰佰叁拾肆元伍角整")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("1234.05"), "壹仟贰佰叁拾肆元零伍分")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("10005"), "壹万零伍元整")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("100200"), "壹拾万零贰佰元整")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("100000000"), "壹亿元整")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("0.56"), "伍角陆分")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("0.08"), "捌分")
        XCTAssertEqual(ChineseSpecialConversions.formatRMBUppercase("1234.56", traditional: true), "壹仟貳佰參拾肆圓伍角陸分")
    }

    func testSpecialCandidatesAppearInSecondPositionAfterLead() {
        let slots = ChineseCandidateList.slots(
            rime: ["日期", "人群", "人气"],
            order: [0, 1, 2],
            corrections: [],
            correctionLeads: false,
            mixed: 0,
            placement: .none,
            phrases: [],
            specials: ["2026年11月22日"]
        )
        XCTAssertEqual(slots, [.rime(0), .special(0), .rime(1), .rime(2)])
    }

    func testTypingRqPlacesDateInSecondCandidateSlot() throws {
        guard let session = ChineseInputSession.bundled() else {
            throw XCTSkip("Bundled Rime data unavailable")
        }
        session.specialConversionsNow = { self.fixedDate }
        _ = session.type("r")
        _ = session.type("q")

        let exp = expectation(description: "rq candidates ready")
        func poll() {
            if session.candidatesAreCurrent && session.candidatePresentations.count >= 2 {
                exp.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            }
        }
        poll()
        wait(for: [exp], timeout: 5.0)

        let texts = session.candidatePresentations.map(\.text)
        XCTAssertGreaterThanOrEqual(texts.count, 2)
        XCTAssertNotEqual(texts[0], "2026年11月22日", "Date must not displace the top normal candidate")
        XCTAssertEqual(texts[1], "2026年11月22日", "Date should appear in the 2nd slot right after the lead candidate")
    }

    func testVPrefixNumericModeInSessionAndNumberPageAcceptance() throws {
        guard let session = ChineseInputSession.bundled() else {
            throw XCTSkip("Bundled Rime data unavailable")
        }
        session.specialConversionsNow = { self.fixedDate }

        // Typing 'v' then digits bypasses Rime and produces RMB uppercase candidates.
        _ = session.type("v")
        XCTAssertTrue(session.acceptsCompositionSymbol("1"))
        XCTAssertFalse(session.acceptsCompositionSymbol("."))

        _ = session.type("1")
        _ = session.type("2")
        _ = session.type("3")
        _ = session.type("4")
        XCTAssertEqual(session.markedText?.text, "v1234")
        XCTAssertEqual(session.candidatePresentations.map(\.text), ["壹仟贰佰叁拾肆元整", "1234"])

        XCTAssertTrue(session.acceptsCompositionSymbol("."))
        _ = session.type(".")
        _ = session.type("5")
        _ = session.type("6")
        XCTAssertEqual(session.markedText?.text, "v1234.56")
        XCTAssertEqual(session.candidatePresentations.map(\.text), ["壹仟贰佰叁拾肆元伍角陆分", "1234.56"])
        // Max 2 fractional digits
        XCTAssertFalse(session.acceptsCompositionSymbol("7"))

        // Backspace edits the vBuffer cleanly.
        _ = session.backspace()
        XCTAssertEqual(session.markedText?.text, "v1234.5")
        XCTAssertEqual(session.candidatePresentations.map(\.text), ["壹仟贰佰叁拾肆元伍角整", "1234.5"])

        // Space commits the lead RMB uppercase candidate.
        let edits = session.space()
        XCTAssertEqual(edits, [.insert("壹仟贰佰叁拾肆元伍角整")])
        XCTAssertFalse(session.isComposing)
    }
}
