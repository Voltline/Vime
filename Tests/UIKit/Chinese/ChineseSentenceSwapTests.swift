import XCTest

final class ChineseSentenceSwapTests: XCTestCase {
    func testSyllablesFollowThePreedit() {
        XCTAssertEqual(ChineseSentenceSwap.syllables(input: "nihaoma", preedit: "ni hao ma"), ["ni", "hao", "ma"])
        XCTAssertEqual(ChineseSentenceSwap.syllables(input: "xi'an", preedit: "xi'an"), ["xi", "an"])
        // The preedit spells ü where the input has v; lengths still line up.
        XCTAssertEqual(ChineseSentenceSwap.syllables(input: "nvren", preedit: "nü ren"), ["nv", "ren"])
        XCTAssertEqual(ChineseSentenceSwap.syllables(input: "wgb", preedit: "w g b"), ["w", "g", "b"])
        XCTAssertNil(ChineseSentenceSwap.syllables(input: "nihao", preedit: "你 hao"), "chosen text is not a syllable")
        XCTAssertNil(ChineseSentenceSwap.syllables(input: "nihao", preedit: "ni ha"))
    }

    func testJobNeedsOneCharacterPerSyllable() {
        let sentence = RimeCandidate(text: "课表上下周杰克", comment: nil, sentence: true)
        let input = "kebiaoshangxiazhoujieke", preedit = "ke biao shang xia zhou jie ke"
        XCTAssertEqual(ChineseSentenceSwap.job(input: input, preedit: preedit, candidate: sentence, context: "")?.syllables.count, 7)
        XCTAssertNil(ChineseSentenceSwap.job(input: input, preedit: preedit,
            candidate: RimeCandidate(text: "课表上下周杰克", comment: nil, coversInput: false), context: ""))
        XCTAssertNil(ChineseSentenceSwap.job(input: input, preedit: preedit,
            candidate: RimeCandidate(text: "课表上下周杰克", comment: nil, userPhrase: true), context: ""), "learned text stays")
        XCTAssertNil(ChineseSentenceSwap.job(input: "nihao", preedit: "ni hao",
            candidate: RimeCandidate(text: "你好", comment: nil), context: ""), "too short")
        XCTAssertNil(ChineseSentenceSwap.job(input: "woshiAI", preedit: "wo shi a i",
            candidate: RimeCandidate(text: "我是AI", comment: nil), context: ""))
    }

    func testSpansAndVariants() {
        XCTAssertEqual(ChineseSentenceSwap.weakest([-1, -5, -2, -9]), [3, 1])
        let spans = ChineseSentenceSwap.spans(around: [0], length: 3)
        XCTAssertEqual(spans, [0..<1, 0..<2, 0..<3])
        XCTAssertEqual(ChineseSentenceSwap.spans(around: [2], length: 6).count, 1 + 2 + 3 + 3, "four syllables fit three ways")
        let variants = ChineseSentenceSwap.variants(of: "周杰克", spans: [1..<3, 0..<1]) { span in
            span == 1..<3 ? ["结课", "杰克", "节课x"] : ["州"]
        }
        XCTAssertEqual(variants, ["周结课", "州杰克"], "same text, wrong lengths and repeats are left out")
    }

    func testWordsAreWholeDictionaryEntries() {
        let candidates = [
            RimeCandidate(text: "结课", comment: nil),
            RimeCandidate(text: "杰克", comment: nil),
            RimeCandidate(text: "结", comment: nil, coversInput: false),
            RimeCandidate(text: "结克", comment: nil, sentence: true),
            RimeCandidate(text: "Jack", comment: nil),
            RimeCandidate(text: "截课", comment: nil),
            RimeCandidate(text: "洁客", comment: nil),
            RimeCandidate(text: "捷克", comment: nil),
        ]
        XCTAssertEqual(ChineseSentenceSwap.words(in: candidates, syllables: 2) { $0 != "截课" }, ["结课", "杰克", "洁客", "捷克"])
    }

    private final class Counter { var value = 0 }

    /// A model that likes some texts, with every character scored by the
    /// sentence it is in, so the weakest characters are the ones it dislikes.
    private func scorer(liked: [String: Double], dislikedCharacters: Set<Character>,
                        words: [String: [String]], secondRound: Bool = true, rounds: Counter) -> ChineseSentenceSwap.Scorer {
        ChineseSentenceSwap.Scorer(
            characters: { _, text in
                rounds.value += 1
                return text.map { dislikedCharacters.contains($0) ? -10 : -1 }
            },
            sentences: { _, texts in texts.map { liked[$0] ?? -100 } },
            lookUp: { spellings in
                spellings.map { (words[$0] ?? []).map { RimeCandidate(text: $0, comment: nil) } }
            },
            allows: { _ in true },
            secondRound: { secondRound })
    }

    func testTwoRoundsFixTwoWords() throws {
        // 只会起点 → 智慧起点 → 智慧奇点
        let job = ChineseSentenceSwap.Job(sentence: "突破只会起点", syllables: ["tu", "po", "zhi", "hui", "qi", "dian"], context: "")
        let rounds = Counter()
        let scorer = scorer(liked: ["突破只会起点": -40, "突破智慧起点": -38, "突破智慧奇点": -30],
                            dislikedCharacters: ["只", "会", "起"],
                            words: ["zhihui": ["只会", "智慧"], "qidian": ["起点", "奇点"]], rounds: rounds)
        XCTAssertEqual(try ChineseSentenceSwap.search(job, scorer: scorer), "突破智慧奇点")
        XCTAssertEqual(rounds.value, 2)
    }

    func testOneRoundUnderPressureAndTheMargin() throws {
        let job = ChineseSentenceSwap.Job(sentence: "突破只会起点", syllables: ["tu", "po", "zhi", "hui", "qi", "dian"], context: "")
        let rounds = Counter()
        let liked = ["突破只会起点": -40.0, "突破智慧起点": -38, "突破智慧奇点": -30]
        let words = ["zhihui": ["只会", "智慧"], "qidian": ["起点", "奇点"]]
        let single = scorer(liked: liked, dislikedCharacters: ["只", "会", "起"], words: words, secondRound: false, rounds: rounds)
        // One round reaches 智慧起点, only 2 better than Rime's: below the margin.
        XCTAssertNil(try ChineseSentenceSwap.search(job, scorer: single))
        XCTAssertEqual(rounds.value, 1)
        var more = liked
        more["突破智慧起点"] = -36
        rounds.value = 0
        let clear = scorer(liked: more, dislikedCharacters: ["只", "会", "起"], words: words, secondRound: false, rounds: rounds)
        XCTAssertEqual(try ChineseSentenceSwap.search(job, scorer: clear), "突破智慧起点")
    }

    func testRimeStaysWhenNothingIsBetter() throws {
        let job = ChineseSentenceSwap.Job(sentence: "我要给它配一个模型", syllables: ["wo", "yao", "gei", "ta", "pei", "yi", "ge", "mo", "xing"], context: "")
        let rounds = Counter()
        let scorer = scorer(liked: ["我要给它配一个模型": -20], dislikedCharacters: ["它"],
                            words: ["ta": ["他", "她", "它"]], rounds: rounds)
        XCTAssertNil(try ChineseSentenceSwap.search(job, scorer: scorer))
        XCTAssertEqual(rounds.value, 1, "no second round when the first keeps Rime's sentence")
    }
}

final class ChineseCharacterScoreTests: XCTestCase {
    func testCharacterScoresAddUpToTheSentenceScore() throws {
        let model = try (try? VimeLanguageModel(variant: .zhV1))
            ?? VimeLanguageModel(bundle: Bundle(for: Self.self), variant: .zhV1)
        for (context, text) in [("", "突破智慧奇点"), ("我觉得", "马上就要突破智慧奇点"), ("", "还问我八股")] {
            let characters = try model.characterScores(context: context, text: text)
            XCTAssertEqual(characters.count, text.count)
            let whole = try model.scores(context: context, candidates: [text])[0]
            XCTAssertEqual(characters.reduce(0, +), whole, accuracy: 1e-3, "\(context)|\(text)")
            XCTAssertTrue(characters.allSatisfy { $0 <= 0 })
        }
    }
}
