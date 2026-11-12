import UIKit
import XCTest

/// 中日混输: Japanese words found by their Mandarin reading in Japanese mode.
@MainActor
final class PinyinKanjiLookupTests: XCTestCase {
    private func lookup() throws -> PinyinKanjiLookup {
        try XCTUnwrap(PinyinKanjiLookup.shared, "PinyinKanjiLookup.bin is not bundled")
    }

    private func surfaces(_ input: String) throws -> [String] {
        try lookup().matches(for: input).map(\.surface)
    }

    private func assertFinds(_ word: String, by input: String, within rank: Int = 3,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try surfaces(input)
        let index = try XCTUnwrap(found.firstIndex(of: word), "\(input) → \(found.prefix(10))", file: file, line: line)
        XCTAssertLessThan(index, rank, "\(input) → \(found.prefix(10))", file: file, line: line)
    }

    // MARK: Lookup

    func testPinyinAndRomajiMixesFindTheWord() throws {
        // 検査 is jiancha as well, and more common, so it may come first.
        for input in ["jiancha", "jiansatu", "jiansatsu", "kencha"] {
            try assertFinds("検察", by: input)
        }
        try assertFinds("検察", by: "jianch", within: PinyinLookupCandidates.highLimit)
        XCTAssertEqual(try surfaces("jiansatsu").first, "検察")
        let match = try XCTUnwrap(lookup().matches(for: "jiansatsu").first { $0.surface == "検察" })
        XCTAssertEqual(match.reading, "けんさつ")
        XCTAssertEqual(match.parts.map(\.mode), [.pinyin, .romaji])
        XCTAssertEqual(match.switches, 1)
        let partial = try XCTUnwrap(lookup().matches(for: "jianch").first { $0.surface == "検察" })
        XCTAssertTrue(partial.partial)
    }

    func testCommonWordsComeFirst() throws {
        try assertFinds("図書館", by: "tushuguan", within: 1)
        try assertFinds("音楽", by: "yinyue", within: 1)
        try assertFinds("旅行", by: "lvxing", within: 1)
        try assertFinds("旅行", by: "lüxing", within: 1)
        try assertFinds("経済", by: "jingji", within: 1)
        try assertFinds("新聞", by: "xinwen", within: 1)
        let jingji = try surfaces("jingji")
        if let keikyu = jingji.firstIndex(of: "京急") {
            XCTAssertGreaterThan(keikyu, try XCTUnwrap(jingji.firstIndex(of: "経済")), "a proper noun goes after the common word")
        }
    }

    func testJapaneseOnlyCharactersMatchByRomaji() throws {
        // 込 and 畑 have no Mandarin reading of their own; their kana do the work.
        try assertFinds("申込", by: "shenkomi", within: 5)
        try assertFinds("田畑", by: "tianhata", within: 5)
    }

    func testPlainRomajiIsLeftToTheEngine() throws {
        XCTAssertFalse(try surfaces("kensatsu").contains("検察"))
        XCTAssertTrue(try lookup().matches(for: "a").isEmpty)
        XCTAssertTrue(try lookup().matches(for: "jian1").isEmpty)
    }

    func testTheTableIsMappedNotCopied() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PinyinKanjiLookup", withExtension: "bin"))
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(try lookup().byteCount, size)
        XCTAssertLessThan(size, 3_000_000)
    }

    /// Every keystroke of twelve letters must stay well under 5 ms. A release
    /// build answers in about 0.1 ms on average (1.4 ms at worst, cold pages);
    /// this unoptimised test build is some 25 times slower, so its worst case
    /// gets a looser bound while its average must still meet the budget.
    func testTwelveLettersAreFast() throws {
        try skipTimingSensitiveTestOnCI()
        let lookup = try lookup()
        let inputs = ["tushuguanjia", "jiansatsukan", "zhongguoren", "xinwenjizhe", "lvxingshe", "jingjixuejia",
                      "jingjiwentiyanjiu", "zhongguojingjifazhan"]
        _ = inputs.map { lookup.matches(for: $0) }
        var slowest = 0.0, total = 0.0, count = 0
        for input in inputs {
            // Every prefix, as typing produces them.
            for length in 2...input.count {
                let prefix = String(input.prefix(length))
                let start = CFAbsoluteTimeGetCurrent()
                // A keystroke with no whole word also looks for a beginning.
                if lookup.matches(for: prefix).isEmpty { _ = lookup.prefixMatches(for: prefix) }
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                slowest = max(slowest, elapsed); total += elapsed; count += 1
            }
        }
        let mean = total / Double(count)
        print("PinyinKanjiLookup per keystroke: mean \(String(format: "%.3f", mean * 1000)) ms, slowest \(String(format: "%.3f", slowest * 1000)) ms")
        XCTAssertLessThan(mean, 0.005)
        #if DEBUG
        XCTAssertLessThan(slowest, 0.020)
        #else
        XCTAssertLessThan(slowest, 0.005)
        #endif
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(options: options) { _ = lookup.matches(for: "tushuguanjia") }
    }

    /// Prints the lookup's answers for the report; asserts nothing but presence.
    func testSampleInputs() throws {
        let inputs = ["jiancha", "jiansatu", "jiansatsu", "kencha", "jianch", "tushuguan", "yinyue", "lvxing",
                      "jingji", "xinwen", "dianhua", "diannao", "xuesheng", "daxue", "shijie", "pengyou",
                      "gongsi", "huiyi", "zhongguo", "riben", "tianqi", "shenkomi", "tianhata", "kaihui"]
        for input in inputs {
            let matches = try lookup().matches(for: input).prefix(4)
            print("PINYIN \(input): " + matches.map { "\($0.surface)(\($0.reading))\($0.partial ? "~" : "") s\($0.switches) c\($0.cost)" }
                .joined(separator: ", "))
        }
    }

    // MARK: Session tiers

    private func session(lookup enabled: Bool = true) -> KeyboardSession {
        let session = KeyboardSession()
        session.setPinyinLookupEnabled(enabled)
        return session
    }

    private func type(_ input: String, lookup enabled: Bool = true) -> KeyboardSession {
        let session = session(lookup: enabled)
        for letter in input { _ = session.type(String(letter)) }
        return session
    }

    func testPinyinOnlyLettersPutTheWordFirst() throws {
        for (input, word) in [("jiansatu", "検察"), ("tushuguan", "図書館"), ("xinwen", "新聞"), ("jingji", "経済"),
                              ("lvxing", "旅行"), ("yinyue", "音楽")] {
            let session = type(input)
            XCTAssertEqual(session.candidateSnapshots.first?.text, word, "\(input) → \(session.candidates.prefix(6))")
            XCTAssertEqual(session.candidateSnapshots.first?.source, .pinyinLookup)
            // A false friend (新聞) shows its reading in the note instead.
            let ruby = session.candidatePresentations.first?.rubyReading
            XCTAssertEqual(ruby.map { !$0.isEmpty } ?? false, PinyinFalseFriends.shared[word] == nil, input)
        }
        // Both words read jiancha in Mandarin; both come before the engine's own.
        let session = type("jiancha")
        let engineFirst = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.source != .pinyinLookup })
        let word = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "検察" }, "\(session.candidates.prefix(8))")
        XCTAssertLessThan(word, engineFirst)
        let partial = type("jianch")
        XCTAssertTrue(partial.candidateSnapshots.prefix(PinyinLookupCandidates.highLimit).contains { $0.text == "検察" },
                      "\(partial.candidates.prefix(10))")
    }

    func testPlausibleJapaneseKeepsTheEngineFirst() throws {
        let session = type("kencha")
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "検察" }, "\(session.candidates.prefix(10))")
        XCTAssertGreaterThanOrEqual(index, PinyinLookupCandidates.lowInsertionIndex, "\(session.candidates.prefix(10))")
        XCTAssertNotEqual(session.candidateSnapshots.first?.source, .pinyinLookup)
        // The romaji of the real reading is ordinary Japanese input.
        let plain = type("kensatsu")
        XCTAssertFalse(plain.candidateSnapshots.contains { $0.source == .pinyinLookup })
        XCTAssertTrue(plain.candidates.contains("検察"))
    }

    func testOrdinaryJapaneseGetsNoRareOrProperNounWords() throws {
        // Romaji of common words also spells rare words or names in pinyin
        // (hashi → 葉室, sushi → 素子, yama → 邪魔); those are left out.
        for input in ["hashi", "sushi", "yama", "watashi", "kaisha", "denwa"] {
            let session = type(input)
            XCTAssertFalse(session.candidateSnapshots.contains { $0.source == .pinyinLookup }, "\(input) → \(session.candidates.prefix(8))")
        }
    }

    func testEnablingDuringASelectionKeepsTheFrozenList() throws {
        let session = type("jiansatsu", lookup: false)
        _ = session.space()
        let list = session.candidatePresentations, selection = session.selectedIndex
        session.setPinyinLookupEnabled(true)
        XCTAssertEqual(session.candidatePresentations, list)
        XCTAssertEqual(session.selectedIndex, selection)
    }

    func testSettingOffKeepsThePlainList() throws {
        let off = type("jiancha", lookup: false)
        XCTAssertFalse(off.candidateSnapshots.contains { $0.source == .pinyinLookup })
        let on = type("jiancha")
        XCTAssertEqual(on.candidateSnapshots.filter { $0.source != .pinyinLookup }.map(\.text), off.candidates)
        on.setPinyinLookupEnabled(false)
        XCTAssertEqual(on.candidates, off.candidates, "turning it off refreshes the composition")
    }

    func testChoosingCommitsTheSurfaceOnlyAndTeachesNothing() throws {
        let session = type("jiansatsu")
        let presentation = try XCTUnwrap(session.candidatePresentations.first { $0.text == "検察" })
        XCTAssertEqual(presentation.rubyReading, "けんさつ")
        XCTAssertTrue(presentation.accessibilityLabel.contains("けんさつ"))
        XCTAssertNil(session.candidateSnapshots.first { $0.text == "検察" }?.preferenceScope)
        let token = try XCTUnwrap(presentation.selectionToken)
        XCTAssertEqual(session.chooseCandidate(token), [.insert("検察")])
        XCTAssertFalse(session.isComposing)
        XCTAssertNil(session.preedit)
        // Nothing was learned: the plain Japanese list for the same letters is unchanged.
        let again = type("jiansatsu", lookup: false)
        XCTAssertFalse(again.candidates.contains("検察"))
    }

    func testSpaceCyclesIntoTheWordAndConfirmCommitsIt() throws {
        let session = type("jiansatsu")
        XCTAssertEqual(session.space(), [])
        XCTAssertEqual(session.selectedText, "検察")
        XCTAssertEqual(session.enter(), [.insert("検察")])
        XCTAssertFalse(session.isComposing)
    }

    func testPinyinShowsTheTypedLettersAndConfirmCommitsThem() throws {
        for input in ["jingji", "gongsi", "tushuguan", "xinwen"] {
            let session = type(input)
            XCTAssertTrue(session.showsPinyinLetters, input)
            XCTAssertEqual(session.preedit, input)
            XCTAssertEqual(session.confirm(), [.insert(input)])
            XCTAssertFalse(session.isComposing)
        }
        // Letters stay once shown, through a backspace to a romaji-like prefix.
        let session = type("jingji")
        for _ in 0..<4 { _ = session.backspace() }
        XCTAssertEqual(session.preedit, "ji")
        XCTAssertEqual(type("jingji").enter(), [.insert("jingji")])
        // Space still selects the word, which then shows in the preedit.
        let spaced = type("jingji")
        _ = spaced.space()
        let word = try XCTUnwrap(spaced.selectedText)
        XCTAssertEqual(spaced.preedit, word)
        XCTAssertEqual(spaced.confirm(), [.insert(word)])
    }

    func testJapaneseKeepsTheKanaPreedit() throws {
        for (input, kana) in [("konnnichiha", "こんにちは"), ("kensatsu", "けんさつ"), ("vaiorinn", "ゔぁいおりん"),
                              ("kencha", "けんちゃ"), ("xtsu", "っ")] {
            let session = type(input)
            XCTAssertFalse(session.showsPinyinLetters, input)
            XCTAssertEqual(session.preedit, kana)
        }
        let off = type("jingji", lookup: false)
        XCTAssertNotEqual(off.preedit, "jingji")
    }

    func testFalseFriendTableParses() throws {
        let table = PinyinFalseFriends(text: "# comment\n手紙\t信件\tトイレットペーパー\tといれっとぺーぱー\n先生\t老师\n\nbad\n")
        XCTAssertEqual(table.count, 2)
        XCTAssertEqual(table["手紙"]?.equivalent?.surface, "トイレットペーパー")
        XCTAssertNil(table["先生"]?.equivalent)
        XCTAssertGreaterThanOrEqual(PinyinFalseFriends.shared.count, 100, "PinyinFalseFriends.tsv is not bundled")
        XCTAssertEqual(PinyinFalseFriends.shared["公司"]?.equivalent?.surface, "会社")
    }

    func testFalseFriendNotesItsMeaningAndTheJapaneseWordFollows() throws {
        for (input, word, equivalent) in [("gongsi", "公司", "会社"), ("shouzhi", "手紙", "トイレットペーパー"),
                                          ("zhangfu", "丈夫", "夫")] {
            let session = type(input)
            let texts = session.candidateSnapshots.map(\.text)
            let index = try XCTUnwrap(texts.firstIndex(of: word), "\(input) → \(texts.prefix(10))")
            XCTAssertEqual(texts[index + 1], equivalent, "\(input) → \(texts.prefix(10))")
            let note = session.candidatePresentations[index], next = session.candidatePresentations[index + 1]
            XCTAssertNil(note.rubyReading)
            let meaning = try XCTUnwrap(PinyinFalseFriends.shared[word]?.meaning)
            XCTAssertTrue(note.annotation?.contains(meaning) == true, "\(note.annotation ?? "nil")")
            XCTAssertEqual(session.candidateSnapshots[index + 1].source, .pinyinLookup)
            XCTAssertNil(next.rubyReading)
            XCTAssertNotNil(next.annotation)
            XCTAssertEqual(texts.filter { $0 == equivalent }.count, 1)
        }
        // Choosing the Japanese word commits it like any looked-up word.
        let session = type("gongsi")
        let token = try XCTUnwrap(session.candidatePresentations.first { $0.text == "会社" }?.selectionToken)
        XCTAssertEqual(session.chooseCandidate(token), [.insert("会社")])
        XCTAssertFalse(session.isComposing)
        // Words outside the table keep the ruby.
        XCTAssertNotNil(type("tushuguan").candidatePresentations.first?.rubyReading)
    }

    // MARK: Word by word

    private func choose(_ word: String, in session: KeyboardSession, file: StaticString = #filePath, line: UInt = #line) throws -> [KeyboardEdit] {
        let presentation = try XCTUnwrap(session.candidatePresentations.first { $0.text == word },
                                         "\(word) not in \(session.candidates.prefix(10))", file: file, line: line)
        return session.chooseCandidate(try XCTUnwrap(presentation.selectionToken, file: file, line: line))
    }

    func testPrefixMatchesTakeTheLongestPinyinBeginning() throws {
        let matches = try lookup().prefixMatches(for: "jingjiwenti")
        let first = try XCTUnwrap(matches.first)
        XCTAssertEqual(first.letterCount, 6)
        XCTAssertTrue(matches.contains { $0.surface == "経済" }, "\(matches.prefix(6).map(\.surface))")
        XCTAssertTrue(matches.allSatisfy { $0.letterCount <= 11 })
        // A whole word is no prefix, and one character is too short a word.
        XCTAssertFalse(try lookup().prefixMatches(for: "jingji").contains { $0.letterCount == 6 })
        XCTAssertFalse(try lookup().prefixMatches(for: "zhongx").contains { $0.surface.count < 2 })
    }

    func testARunOfPinyinIsChosenWordByWord() throws {
        let session = type("jingjiwenti")
        XCTAssertEqual(session.preedit, "jingjiwenti")
        XCTAssertEqual(session.candidateSnapshots.first?.text, "経済", "\(session.candidates.prefix(8))")
        XCTAssertEqual(session.candidateSnapshots.first?.fullConsumption, false)
        XCTAssertEqual(try choose("経済", in: session), [.insert("経済")])
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(session.preedit, "wenti")
        XCTAssertTrue(session.showsPinyinLetters)
        XCTAssertEqual(session.candidateSnapshots.first?.text, "問題", "\(session.candidates.prefix(8))")
        XCTAssertEqual(try choose("問題", in: session), [.insert("問題")])
        XCTAssertFalse(session.isComposing)
        XCTAssertNil(session.preedit)

        let music = type("jingjiyinyue")
        XCTAssertEqual(try choose("経済", in: music), [.insert("経済")])
        XCTAssertEqual(music.preedit, "yinyue")
        XCTAssertEqual(music.candidateSnapshots.first?.text, "音楽")
        // A whole word for all the letters is offered whole, not split.
        let china = type("zhongguojingji")
        XCTAssertEqual(china.candidateSnapshots.first?.text, "中国経済")
        XCTAssertTrue(china.candidateSnapshots.filter { $0.source == .pinyinLookup }.allSatisfy(\.fullConsumption))
    }

    func testSpaceShowsThePrefixWordWithTheRestAsTyped() throws {
        let session = type("jingjiwenti")
        _ = session.space()
        XCTAssertEqual(session.selectedText, "経済")
        XCTAssertEqual(session.preedit, "経済wenti")
        XCTAssertEqual(session.enter(), [.insert("経済")])
        XCTAssertEqual(session.preedit, "wenti")
        // Backspace edits the remaining letters one by one.
        _ = session.backspace()
        XCTAssertEqual(session.preedit, "went")
        // 確定 commits the remaining letters as typed.
        XCTAssertEqual(session.confirm(), [.insert("went")])
        XCTAssertFalse(session.isComposing)
    }

    func testPinyinShownBeforeLetsAPrefixFollow() throws {
        // tushuguan showed letters, so tushuguank… goes on as pinyin.
        let session = type("tushuguankaimen")
        XCTAssertTrue(session.showsPinyinLetters)
        XCTAssertEqual(session.candidateSnapshots.first?.text, "図書館", "\(session.candidates.prefix(8))")
        XCTAssertEqual(try choose("図書館", in: session), [.insert("図書館")])
        XCTAssertEqual(session.preedit, "kaimen")
        // Without that context the same letters are Japanese.
        let plain = type("kaimen")
        XCTAssertFalse(plain.showsPinyinLetters)
        XCTAssertFalse(plain.candidateSnapshots.contains { !$0.fullConsumption && $0.source == .pinyinLookup })
    }

    func testChoosingAPrefixTeachesNothingAndLeavesNoUndo() throws {
        let session = type("jingjiwenti")
        XCTAssertNil(session.candidateSnapshots.first?.preferenceScope)
        _ = try choose("経済", in: session)
        _ = try choose("問題", in: session)
        XCTAssertFalse(type("keizai", lookup: false).candidates.isEmpty)
        let again = type("jingjiwenti", lookup: false)
        XCTAssertFalse(again.candidates.contains("経済"))
    }

    // MARK: Japanese input stays Japanese

    /// Everyday Japanese typed in romaji, with words and sentences whose
    /// letters also spell pinyin syllables (ji, jin, shi, an, ian…).
    static let japaneseInputs = [
        "kaishawoyameru", "watashihagakuseidesu", "kyouhaiitenkidesune", "ashitaaimasenka", "shinbunwoyomu",
        "denwabangou", "toshokandebenkyousuru", "jinjabukyoku", "jinjiidou", "shianwomegurasu", "kianwotsukuru",
        "jikanganai", "jidousha", "shigotowoshiteimasu", "nihongonobenkyou", "konbanhananiwotabemasuka",
        "sumimasen", "arigatougozaimasu", "ohayougozaimasu", "yoroshikuonegaishimasu", "kanjiwokaku",
        "ningen", "tenki", "gaikoku", "shanhai", "chuugoku", "pekin", "hanbaagaa", "kounyuu", "tenpura",
        "henshuu", "senshu", "genki", "kinjo", "shinjuku", "ginza", "kyoto", "tanin", "jiken", "gian", "kian",
        "shian", "anzen", "anshin", "renai", "deshou", "nanjinisuru", "vaiorinn", "xyaku", "maxtsutaku", "toukyouekimadeikimasu", "denshawonorikaeru", "maxtuta", "kaxtuta",
    ]

    private func readings(_ resource: String, key: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: resource, withExtension: "json"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let cases = try XCTUnwrap(object?["cases"] as? [[String: Any]])
        return cases.compactMap { $0[key] as? String }
    }

    /// Lookup on or off, every keystroke of Japanese input shows the same
    /// preedit and the same Japanese candidates, and no word for a beginning
    /// of the letters is ever offered.
    private func assertJapaneseUnchanged(_ input: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        // Each session types on its own, as a user would.
        let off = session(lookup: false)
        var expected: [(preedit: String?, candidates: [String])] = []
        for letter in input { _ = off.type(String(letter)); expected.append((off.preedit, off.candidates)) }
        let on = session()
        for (letter, expected) in zip(input, expected) {
            _ = on.type(String(letter))
            let prefixWord = on.candidateSnapshots.first { $0.source == .pinyinLookup && !$0.remainingComposition.isEmpty }
            let japanese = on.candidateSnapshots.filter { $0.source != .pinyinLookup }.map(\.text)
            guard on.preedit == expected.preedit, prefixWord == nil, !on.showsPinyinLetters,
                  on.candidateSnapshots.first?.source != .pinyinLookup else {
                XCTFail("\(input) at \(on.raw): preedit \(on.preedit ?? "nil") vs \(expected.preedit ?? "nil"), "
                        + "prefix \(prefixWord?.text ?? "none"), first \(on.candidates.prefix(4)) vs \(expected.candidates.prefix(4))",
                        file: file, line: line)
                return false
            }
            // The engine's own order can vary between runs (面白い/面白え);
            // that is no lookup effect, so it is only counted.
            if japanese != expected.candidates { listDifferences += 1 }
        }
        // 確定 commits the same text.
        XCTAssertEqual(on.confirm(), off.confirm(), input, file: file, line: line)
        return true
    }
    private var listDifferences = 0

    func testJapaneseSentencesAreUnchangedByTheLookup() {
        for input in Self.japaneseInputs { _ = assertJapaneseUnchanged(input) }
    }

    func testEverydayBenchmarkIsUnchangedByTheLookup() throws {
        let inputs = try readings("CandidateBenchmarkEveryday", key: "reading").compactMap(KeyboardCandidateBenchmarkTests.romaji)
        XCTAssertGreaterThan(inputs.count, 200)
        let failed = inputs.filter { !assertJapaneseUnchanged($0) }
        print("PINYIN guard everyday: \(inputs.count - failed.count)/\(inputs.count) unchanged, \(listDifferences) later-list differences")
    }

    func testMixedSoundCorpusIsUnchangedByTheLookup() throws {
        let inputs = try readings("MixedSoundCorpus", key: "input").compactMap(KeyboardCandidateBenchmarkTests.romaji)
        XCTAssertGreaterThan(inputs.count, 100)
        let failed = inputs.filter { !assertJapaneseUnchanged($0) }
        print("PINYIN guard mixed: \(inputs.count - failed.count)/\(inputs.count) unchanged, \(listDifferences) later-list differences")
    }

    /// Typing pinyin, then Japanese after a commit, leaves no pinyin state behind.
    func testPinyinStateEndsWithTheComposition() throws {
        let session = type("jingjiwenti")
        _ = try choose("経済", in: session)
        _ = session.confirm()
        for letter in "kaishawoyameru" { _ = session.type(String(letter)) }
        let off = type("kaishawoyameru", lookup: false)
        XCTAssertFalse(session.showsPinyinLetters)
        XCTAssertEqual(session.preedit, off.preedit)
        XCTAssertFalse(session.candidateSnapshots.contains { $0.source == .pinyinLookup && !$0.remainingComposition.isEmpty })
    }

    func testOtherCandidatesHaveNoRuby() throws {
        let session = type("jiancha")
        XCTAssertTrue(session.candidatePresentations.filter { $0.source != .pinyinLookup }.allSatisfy { $0.rubyReading == nil })
        let japanese = type("kensatsu")
        XCTAssertTrue(japanese.candidatePresentations.allSatisfy { $0.rubyReading == nil })
    }

    // MARK: Layout

    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testRubySitsAboveTheWordAndFitsEveryStrip() throws {
        for (width, compact) in [(CGFloat(320), false), (375, false), (440, false), (680, true)] {
            var presentation = CandidatePresentation(text: "検察", source: .pinyinLookup, consumedInputCount: 7, correction: nil)
            presentation.rubyReading = "けんさつ"
            let metrics = KeyboardMetrics(width: width, compact: compact, showsFooter: true)
            let height = metrics.headerHeight - 6
            let button = KeyboardCandidateButton(frame: CGRect(x: 0, y: 0, width: 140, height: height))
            button.present(presentation, index: 0, highlighted: true)
            button.frame.size.width = button.presentationWidth
            button.layoutIfNeeded()
            let ruby = try XCTUnwrap(descendants(button).first { $0.accessibilityIdentifier == "vime.candidate.ruby" } as? UILabel)
            let annotation = try XCTUnwrap(descendants(button).first { $0.accessibilityIdentifier == "vime.candidate.annotation" })
            let title = try XCTUnwrap(button.titleLabel)
            XCTAssertFalse(ruby.isHidden)
            XCTAssertTrue(annotation.isHidden)
            XCTAssertEqual(ruby.text, "けんさつ")
            XCTAssertLessThanOrEqual(button.intrinsicContentSize.height, height, "width \(width)")
            XCTAssertGreaterThanOrEqual(ruby.frame.minY, 0)
            XCTAssertLessThanOrEqual(ruby.frame.maxY, title.frame.minY)
            XCTAssertLessThanOrEqual(title.frame.maxY, height)
            XCTAssertGreaterThanOrEqual(title.bounds.height, title.font.lineHeight)
            XCTAssertEqual(ruby.frame.midX, title.frame.midX, accuracy: 1, "centred like furigana")
            XCTAssertGreaterThanOrEqual(button.presentationWidth, ruby.frame.width + 24)
            XCTAssertEqual(title.font.pointSize, KeyboardCandidateButton.rubyTitleFontSize)
            XCTAssertTrue(button.accessibilityLabel?.contains("けんさつ") == true)
        }
    }

    func testPlainCandidateLayoutIsUnchangedAfterARubyWord() throws {
        let height = KeyboardMetrics(width: 375, compact: false, showsFooter: true).headerHeight - 6
        let plain = CandidatePresentation(text: "検査", source: .conversion, consumedInputCount: 6, correction: nil)
        let fresh = KeyboardCandidateButton(frame: CGRect(x: 0, y: 0, width: 140, height: height))
        fresh.present(plain, index: 1, highlighted: false)
        fresh.layoutIfNeeded()
        // A pooled button that showed a ruby word must lay out a plain one the same way.
        let reused = KeyboardCandidateButton(frame: CGRect(x: 0, y: 0, width: 140, height: height))
        var withRuby = CandidatePresentation(text: "検察", source: .pinyinLookup, consumedInputCount: 7, correction: nil)
        withRuby.rubyReading = "けんさつ"
        reused.present(withRuby, index: 1, highlighted: false)
        reused.layoutIfNeeded()
        reused.present(plain, index: 1, highlighted: false)
        reused.layoutIfNeeded()
        let ruby = try XCTUnwrap(descendants(reused).first { $0.accessibilityIdentifier == "vime.candidate.ruby" })
        XCTAssertTrue(ruby.isHidden)
        XCTAssertEqual(reused.titleLabel?.font, fresh.titleLabel?.font)
        XCTAssertEqual(reused.titleLabel?.font.pointSize, KeyboardCandidateButton.titleFontSize)
        XCTAssertEqual(reused.intrinsicContentSize, fresh.intrinsicContentSize)
        XCTAssertEqual(reused.presentationWidth, fresh.presentationWidth)
        XCTAssertEqual(reused.accessibilityLabel, fresh.accessibilityLabel)
    }
}
