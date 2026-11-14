import XCTest

final class ChineseCandidateRankingTests: XCTestCase {
    private func sentence(_ text: String) -> RimeCandidate { RimeCandidate(text: text, comment: nil, sentence: true) }
    private func word(_ text: String, covers: Bool = false) -> RimeCandidate {
        RimeCandidate(text: text, comment: nil, coversInput: covers)
    }

    private var candidates: [RimeCandidate] {
        [sentence("突破只会起点"), sentence("突破智慧起点"), sentence("突破指挥起点"), sentence("突破智慧奇点"),
         word("突破"), word("土坡"), word("图")]
    }

    func testSentencesLeadAndOnlyTheFirstShowsWithoutTheModel() {
        let run = ChineseCandidateRanking.sentenceRun(candidates)
        XCTAssertEqual(run, 0..<4)
        XCTAssertEqual(ChineseCandidateRanking.order(count: candidates.count, sentences: run), [0, 4, 5, 6])
        XCTAssertEqual(ChineseCandidateRanking.order(count: 3, sentences: 0..<0), [0, 1, 2])
    }

    func testSlotsWeighEverySentence() {
        let slots = ChineseCandidateRanking.slots(candidates) { _ in true }
        XCTAssertEqual(slots.sentences, [0, 1, 2, 3])
        XCTAssertEqual(slots.others, [], "words cover only part of the input")
        XCTAssertEqual(ChineseCandidateRanking.slots(candidates, sentenceLimit: 2) { _ in true }.sentences, [0, 1])
        XCTAssertEqual(ChineseCandidateRanking.slots(candidates) { $0 != "突破只会起点" }.sentences, [],
                       "a first sentence the model may not move keeps the others out")
        XCTAssertEqual(ChineseCandidateRanking.slots(candidates) { $0 != "突破指挥起点" }.sentences, [0, 1, 3])
    }

    func testTheBestSentencesShowFirst() {
        let run = ChineseCandidateRanking.sentenceRun(candidates)
        let slots = ChineseCandidateRanking.slots(candidates) { _ in true }
        // 智慧奇点 wins; 智慧起点 next; the fourth sentence shows no more.
        let order = ChineseCandidateRanking.order(count: candidates.count, sentences: run, slots: slots,
                                                  scores: [-40, -35, -45, -30])
        XCTAssertEqual(order, [3, 1, 0, 4, 5, 6])
        // A small edge is enough between sentences: Rime's order says little there.
        XCTAssertEqual(ChineseCandidateRanking.order(count: candidates.count, sentences: run, slots: slots,
                                                     scores: [-30, -29.8, -40, -40]).first, 1)
        XCTAssertEqual(ChineseCandidateRanking.order(count: candidates.count, sentences: run, slots: slots,
                                                     scores: [-30, .nan, -40, -40]), [0, 4, 5, 6])
    }

    func testWordsKeepTheirRule() {
        // No sentences: the first eight complete candidates, one log probability a place.
        let words = [word("世界", covers: true), word("视界", covers: true), word("事界", covers: true), word("是")]
        let slots = ChineseCandidateRanking.slots(words) { _ in true }
        XCTAssertEqual(slots, ChineseCandidateRanking.Slots(sentences: [], others: [0, 1, 2]))
        let order = ChineseCandidateRanking.order(count: words.count, sentences: 0..<0, slots: slots, scores: [-10, -9.5, -5])
        XCTAssertEqual(order, [2, 0, 1, 3])
        // One sentence competes with complete words as one more slot.
        let mixed = [sentence("你好吗"), word("你好嘛", covers: true), word("你")]
        let mixedSlots = ChineseCandidateRanking.slots(mixed) { _ in true }
        XCTAssertEqual(mixedSlots, ChineseCandidateRanking.Slots(sentences: [0], others: [1]))
        XCTAssertEqual(ChineseCandidateRanking.order(count: 3, sentences: 0..<1, slots: mixedSlots, scores: [-10, -9.5]), [0, 1, 2])
        XCTAssertEqual(ChineseCandidateRanking.order(count: 3, sentences: 0..<1, slots: mixedSlots, scores: [-10, -8]), [1, 0, 2])
    }

    func testTheBestSentenceCompetesWithWords() {
        let list = [sentence("你好吗"), sentence("你好嘛"), word("拟好吗", covers: true), word("你")]
        let slots = ChineseCandidateRanking.slots(list) { _ in true }
        XCTAssertEqual(slots, ChineseCandidateRanking.Slots(sentences: [0, 1], others: [2]))
        let order = ChineseCandidateRanking.order(count: list.count, sentences: 0..<2, slots: slots, scores: [-12, -10, -5])
        XCTAssertEqual(order, [2, 0, 1, 3], "the word beats the best sentence by more than a place")
    }
}
