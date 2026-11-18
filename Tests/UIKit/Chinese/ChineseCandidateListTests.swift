import XCTest

final class ChineseCandidateListTests: XCTestCase {
    private typealias List = ChineseCandidateList

    private func slots(_ rime: [String], order: [Int]? = nil, corrections: [String] = [], correctionLeads: Bool = false,
                       mixed: Int = 0, placement: List.MixedPlacement = .none, phrases: [String] = []) -> [List.Slot] {
        List.slots(rime: rime, order: order ?? Array(rime.indices), corrections: corrections, correctionLeads: correctionLeads,
                   mixed: mixed, placement: placement, phrases: phrases)
    }

    func testRimeAloneKeepsItsOrder() {
        XCTAssertEqual(slots(["你好", "你", "尼"], order: [0, 2, 1]), [.rime(0), .rime(2), .rime(1)])
        XCTAssertEqual(slots([]), [])
    }

    func testCorrectionsGoSecondAndMoveTheirPhraseUp() {
        XCTAssertEqual(slots(["可", "开", "可以"], corrections: ["可以"]), [.rime(0), .correction(0), .rime(1)])
        // One the same as Rime's first shows once, as Rime's.
        XCTAssertEqual(slots(["可以", "可"], corrections: ["可以", "开衣"]), [.rime(0), .correction(1), .rime(1)])
    }

    func testAClearSentenceCorrectionLeads() {
        XCTAssertEqual(slots(["是", "事", "时"], corrections: ["什么", "深么"], correctionLeads: true),
                       [.correction(0), .rime(0), .correction(1), .rime(1), .rime(2)])
        // Only the sentence correction (the first) may lead.
        XCTAssertEqual(slots(["什么", "是"], corrections: ["什么", "深么"], correctionLeads: true),
                       [.rime(0), .correction(1), .rime(1)])
    }

    func testReadingsKeepingCapitalsAllLead() {
        XCTAssertEqual(slots(["今天"], mixed: 2, placement: .leadAll), [.mixed(0), .mixed(1), .rime(0)])
    }

    func testReadingsGoingOnWhereRimeStopsLeadOnce() {
        XCTAssertEqual(slots(["进行", "进"], mixed: 3, placement: .leadFirst),
                       [.mixed(0), .rime(0), .mixed(1), .mixed(2), .rime(1)])
        // Rime has nothing for the rest.
        XCTAssertEqual(slots([], mixed: 2, placement: .leadFirst), [.mixed(0), .mixed(1)])
        // A typo: its correction keeps its place, the readings follow it.
        XCTAssertEqual(slots(["我", "无"], corrections: ["我想"], mixed: 1, placement: .leadFirst),
                       [.rime(0), .correction(0), .mixed(0), .rime(1)])
    }

    func testAReadingTheModelPrefersLeadsAlone() {
        XCTAssertEqual(slots(["这个不过我", "这个"], mixed: 1, placement: .overRime), [.mixed(0), .rime(0), .rime(1)])
        XCTAssertEqual(slots(["这个不过我"], mixed: 1, placement: .none), [.rime(0)])
    }

    func testUserPhrasesComeFirstAndOnce() {
        XCTAssertEqual(slots(["你好", "你"], phrases: ["你好呀", "你好"]), [.phrase(0), .phrase(1), .rime(1)])
    }

    func testPlacement() {
        XCTAssertEqual(List.placement(readings: 0, capitals: true, rimeShort: true, best: nil, rival: nil), .none)
        XCTAssertEqual(List.placement(readings: 2, capitals: true, rimeShort: false, best: nil, rival: nil), .leadAll)
        XCTAssertEqual(List.placement(readings: 2, capitals: false, rimeShort: true, best: nil, rival: nil), .leadFirst)
        // Rime read the whole input: only the model can tell a word from abbreviations.
        XCTAssertEqual(List.placement(readings: 2, capitals: false, rimeShort: false, best: nil, rival: nil), .none)
        XCTAssertEqual(List.placement(readings: 2, capitals: false, rimeShort: false, best: -10, rival: -12), .overRime)
        XCTAssertEqual(List.placement(readings: 2, capitals: false, rimeShort: false, best: -12, rival: -10), .none)
    }
}
