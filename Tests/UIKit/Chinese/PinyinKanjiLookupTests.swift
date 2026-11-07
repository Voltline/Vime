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
        let lookup = try lookup()
        let inputs = ["tushuguanjia", "jiansatsukan", "zhongguoren", "xinwenjizhe", "lvxingshe", "jingjixuejia"]
        _ = inputs.map { lookup.matches(for: $0) }
        var slowest = 0.0, total = 0.0, count = 0
        for input in inputs {
            // Every prefix, as typing produces them.
            for length in 2...input.count {
                let prefix = String(input.prefix(length))
                let start = CFAbsoluteTimeGetCurrent()
                _ = lookup.matches(for: prefix)
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
            XCTAssertEqual(session.candidatePresentations.first?.rubyReading.map { !$0.isEmpty }, true)
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
