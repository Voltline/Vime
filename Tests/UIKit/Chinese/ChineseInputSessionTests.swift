import UIKit
import XCTest

@MainActor
final class ChineseInputSessionTests: XCTestCase {
    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChineseInputSessionTests-\(UUID().uuidString)")
    private var batches: [KeyboardCommitBatch] = []

    private func session() throws -> ChineseInputSession {
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user))
        session.onCommittedEdits = { [weak self] in self?.batches.append($0) }
        return session
    }

    /// Lets queued results reach the main thread.
    private func waitUntilCurrent(_ session: ChineseInputSession, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while !session.candidatesAreCurrent && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        // A delivery already scheduled for the last result may still be pending.
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(session.candidatesAreCurrent, "Rime did not answer", file: file, line: line)
    }

    private func token(_ text: String, in session: ChineseInputSession) throws -> CandidateSelectionToken {
        try XCTUnwrap(session.candidatePresentations.first { $0.text == text }?.selectionToken,
                      "\(session.candidatePresentations.map(\.text))")
    }

    func testLettersEchoAtOnceAndChoosingCommitsOnce() throws {
        let session = try session()
        XCTAssertEqual(session.type("ni"), [])
        XCTAssertEqual(session.markedText?.text, "ni", "letters show before Rime answers")
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(session.type("hao"), [])
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "nihao")
        XCTAssertEqual(session.candidatePresentations.first?.text, "你好")
        XCTAssertEqual(session.chooseCandidate(try token("你好", in: session)), [], "the commit arrives as a batch")
        waitUntilCurrent(session)
        XCTAssertEqual(batches.map(\.edits), [[.insert("你好")]])
        XCTAssertEqual(batches.first?.hostEpoch, session.hostEpoch)
        XCTAssertFalse(session.isComposing)
        XCTAssertNil(session.markedText)
        XCTAssertTrue(session.candidatePresentations.isEmpty)
    }

    func testUserPhrasesComeFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChineseUserPhrases-\(UUID().uuidString)")
        let dictionary = ChineseUserDictionaryStore(directory: directory,
            defaults: try XCTUnwrap(UserDefaults(suiteName: "ChineseUserPhrases-\(UUID().uuidString)")))
        try dictionary.save([.init(pinyin: "ni hao", text: "你好呀")])
        let data = try XCTUnwrap(RimeEngine.bundledData)
        let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user), userDictionary: dictionary)
        _ = session.type("nh")
        waitUntilCurrent(session)
        XCTAssertEqual(session.candidatePresentations.first?.text, "你好呀")
        _ = session.type("a")
        waitUntilCurrent(session)
        XCTAssertNotEqual(session.candidatePresentations.first?.text, "你好呀", "only the whole input matches")
        _ = session.backspace()
        _ = session.backspace()
        _ = session.type("ihao")
        waitUntilCurrent(session)
        XCTAssertEqual(session.candidatePresentations.map(\.text).prefix(2), ["你好呀", "你好"])
        XCTAssertEqual(session.candidatePresentations.filter { $0.text == "你好呀" }.count, 1)
        XCTAssertEqual(session.space().last, .insert("你好呀"))
        XCTAssertFalse(session.isComposing)
        XCTAssertTrue(session.candidatePresentations.isEmpty)
    }

    func testRapidKeysKeepTheirOrder() throws {
        let session = try session()
        for letter in "women" { _ = session.type(String(letter)) }
        _ = session.backspace()
        _ = session.type("n")
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "women")
        XCTAssertEqual(session.candidatePresentations.first?.text, "我们")
        session.reset()
    }

    func testOldCandidatesCannotBeChosenWhileKeysRun() throws {
        let session = try session()
        _ = session.type("ni")
        waitUntilCurrent(session)
        let old = try XCTUnwrap(session.candidatePresentations.first?.selectionToken)
        _ = session.type("hao")
        XCTAssertFalse(session.candidatesAreCurrent)
        XCTAssertEqual(session.chooseCandidate(old), [])
        waitUntilCurrent(session)
        XCTAssertEqual(session.chooseCandidate(old), [], "a new list has a new generation")
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(session.raw, "nihao")
        session.reset()
    }

    func testPunctuationCommitsTheCompositionFirst() throws {
        let session = try session()
        _ = session.type("nihao")
        // No wait: the literal must still land after the pending letters.
        XCTAssertEqual(session.insertLiteral("，"), [.insert("你好"), .insert("，")])
        waitUntilCurrent(session)
        XCTAssertTrue(batches.isEmpty, "a commit returned as edits is never sent again")
        XCTAssertFalse(session.isComposing)
        XCTAssertEqual(session.type("!"), [.insert("!")])
    }

    func testPartialSelectionThenConfirmAll() throws {
        let session = try session()
        _ = session.type("nihaoma")
        waitUntilCurrent(session)
        _ = session.chooseCandidate(try token("你好", in: session))
        waitUntilCurrent(session)
        XCTAssertTrue(batches.isEmpty)
        XCTAssertTrue(session.isComposing)
        XCTAssertTrue(session.markedText?.text.hasPrefix("你好") == true, "\(session.markedText?.text ?? "nil")")
        XCTAssertEqual(session.candidatePresentations.first?.text, "吗")
        XCTAssertEqual(session.confirmAll(), [.insert("你好吗")])
        XCTAssertNil(session.markedText)
    }

    func testSpaceSelectsAndReturnCommitsTheLetters() throws {
        let session = try session()
        _ = session.type("zhongwen")
        XCTAssertEqual(session.space(), [])
        waitUntilCurrent(session)
        XCTAssertEqual(batches.last?.edits, [.insert("中文")])
        _ = session.type("xi")
        _ = session.type("'")
        _ = session.type("an")
        XCTAssertEqual(session.markedText?.text.replacingOccurrences(of: ChineseInputSession.syllableGap, with: ""), "xi'an")
        XCTAssertEqual(session.enter(), [])
        waitUntilCurrent(session)
        XCTAssertEqual(batches.last?.edits, [.insert("xi'an")])
        XCTAssertEqual(session.space(), [.insert(" ")])
        XCTAssertEqual(session.enter(), [.returnKey])
        XCTAssertEqual(session.backspace(), [.deleteBackward])
    }

    /// Lets a suggestion lookup answer; true once suggestions show.
    private func waitForSuggestions(_ session: ChineseInputSession) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while session.suggestionTexts.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return !session.suggestionTexts.isEmpty
    }

    func testCommittedWordsOfferWhatFollowsThem() throws {
        let session = try session()
        _ = session.type("dianhua")
        XCTAssertEqual(session.space(), [])
        waitUntilCurrent(session)
        XCTAssertEqual(batches.last?.edits, [.insert("电话")])
        XCTAssertTrue(waitForSuggestions(session))
        XCTAssertTrue(session.showsStrip)
        XCTAssertTrue(session.candidatePresentations.isEmpty, "suggestions show in the strip only")
        XCTAssertTrue(session.suggestionTexts.contains("号码"), "\(session.suggestionTexts)")
        let suggestion = try XCTUnwrap(session.stripPresentations.first { $0.text == "号码" }?.selectionToken)
        XCTAssertEqual(suggestion.kind, .suggestion)
        XCTAssertEqual(session.chooseCandidate(suggestion), [.insert("号码")])
        XCTAssertEqual(session.chooseCandidate(suggestion), [], "a chosen suggestion is gone")
        // Choosing one asks about the phrase it ends in turn; typing hides them.
        _ = waitForSuggestions(session)
        _ = session.type("w")
        XCTAssertTrue(session.suggestionTexts.isEmpty)
        waitUntilCurrent(session)
        session.reset()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // A literal after the commit, and the switch, keep them away.
        _ = session.type("women")
        XCTAssertEqual(session.insertLiteral("，"), [.insert("我们"), .insert("，")])
        XCTAssertFalse(waitForSuggestions(session))
        session.updateIntelligence(ranking: .engine, suggestionsEnabled: false)
        _ = session.type("women")
        _ = session.space()
        waitUntilCurrent(session)
        XCTAssertFalse(waitForSuggestions(session))
        session.updateIntelligence(ranking: .engine, suggestionsEnabled: true)
        _ = session.type("women")
        _ = session.space()
        waitUntilCurrent(session)
        XCTAssertTrue(waitForSuggestions(session))
        XCTAssertEqual(session.backspace(), [.deleteBackward])
        XCTAssertTrue(session.suggestionTexts.isEmpty)
        session.reset()
    }

    func testSwipingTheLineAwayPutsTheSuggestionsAway() throws {
        let session = try session()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        defer { keyboard.stopInteractions(); session.reset() }
        _ = session.type("dianhua")
        _ = session.space()
        waitUntilCurrent(session)
        XCTAssertTrue(waitForSuggestions(session))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        surface.onDeleteLine?()
        XCTAssertTrue(session.suggestionTexts.isEmpty)
        XCTAssertFalse(waitForSuggestions(session), "they do not come back")
        XCTAssertFalse(keyboard.showsNextWordClose)
    }

    /// Lets a correction lookup answer; the corrections shown.
    private func corrections(_ session: ChineseInputSession, within seconds: TimeInterval = 5) -> [CandidatePresentation] {
        let deadline = Date().addingTimeInterval(seconds)
        func found() -> [CandidatePresentation] { session.candidatePresentations.filter { $0.source == .typoCorrection } }
        while found().isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        return found()
    }

    func testCorrectedPinyinShowsOnlyWhenTurnedOn() throws {
        let session = try session()
        for enabled in [false, true] {
            session.setCorrectionSpellingHints(enabled)
            _ = session.type("shenem")
            waitUntilCurrent(session)
            let shown = try XCTUnwrap(corrections(session).first { $0.text == "什么" })
            XCTAssertEqual(shown.detailAnnotation != nil, enabled)
            session.reset()
        }
    }

    func testCapitalJoinsTheCompositionAndWaitsToBeChosen() throws {
        let session = try session()
        _ = session.type("ni")
        waitUntilCurrent(session)
        XCTAssertEqual(session.type("N"), [])
        waitUntilCurrent(session)
        XCTAssertTrue(session.isComposing, "A capital never commits the composition")
        XCTAssertTrue(batches.isEmpty)
        XCTAssertEqual(session.markedText?.text.hasSuffix("N"), true)
    }

    func testCapitalWordStaysAsTypedInTheSentence() throws {
        let session = try session()
        for (typed, meant) in [("jintianyongVimedazi", "今天用Vime打字"), ("Vimehenhaoyong", "Vime很好用"),
                               ("woyongGPTxiezuoye", "我用GPT写作业")] {
            XCTAssertEqual(try waitForLead(session, typing: typed) { $0 == meant }, meant, typed)
            let edits = session.space()
            XCTAssertEqual((batches.flatMap(\.edits) + edits).last, .insert(meant), typed)
            XCTAssertFalse(session.isComposing, typed)
            batches = []
            session.reset()
        }
    }

    func testSpaceRightAfterACapitalWaitsForTheReading() throws {
        let session = try session()
        _ = session.type("Vimehenhaoyong")
        XCTAssertEqual(session.space(), [])
        let deadline = Date().addingTimeInterval(5)
        while session.isComposing, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(batches.flatMap(\.edits).last, .insert("Vime很好用"))
        XCTAssertFalse(session.isComposing)
    }

    func testReturnEntersCapitalsAsTyped() throws {
        let session = try session()
        _ = session.type("woyongVime")
        waitUntilCurrent(session)
        XCTAssertEqual(session.markedText?.text.replacingOccurrences(of: ChineseInputSession.syllableGap, with: "")
            .hasSuffix("Vime"), true)
        let edits = session.enter()
        XCTAssertEqual((batches.flatMap(\.edits) + edits).last, .insert("woyongVime"))
        XCTAssertFalse(session.isComposing)
    }

    func testBackspaceTakesTheCapitalBack() throws {
        let session = try session()
        _ = session.type("haoV")
        waitUntilCurrent(session)
        _ = session.backspace()
        waitUntilCurrent(session)
        XCTAssertEqual(session.markedText?.text.contains("V"), false)
        _ = session.type("v")
        waitUntilCurrent(session)
        XCTAssertEqual(session.markedText?.text.contains("V"), false, "a lowercase v typed again stays lowercase")
    }

    func testTyposAcrossSyllablesOfferTheMeantPhrase() throws {
        let session = try session()
        // Across syllables, and in two-letter syllables Rime's speller leaves
        // alone, even where the typo still reads as syllables (mao ai).
        for (typed, meant) in [("shenem", "什么"), ("keiy", "可以"), ("gongzo", "工作"), ("maoai", "貌似"), ("wixiang", "我想")] {
            _ = session.type(typed)
            waitUntilCurrent(session)
            let shown = corrections(session)
            XCTAssertTrue(shown.contains { $0.text == meant }, "\(typed): \(session.candidatePresentations.map(\.text))")
            let index = try XCTUnwrap(session.candidatePresentations.firstIndex { $0.text == meant && $0.source == .typoCorrection })
            XCTAssertTrue((1...2).contains(index), "corrections never come first: \(index)")
            XCTAssertEqual(session.candidatePresentations.filter { $0.text == meant }.count, 1, "shown once")
            XCTAssertEqual(session.chooseCandidate(try XCTUnwrap(session.candidatePresentations[index].selectionToken)), [])
            waitUntilCurrent(session)
            XCTAssertEqual(batches.last?.edits, [.insert(meant)])
            XCTAssertFalse(session.isComposing)
        }
        // Editing the input drops them with Rime's next answer.
        _ = session.type("keiy")
        waitUntilCurrent(session)
        XCTAssertFalse(corrections(session).isEmpty)
        _ = session.backspace()
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "kei")
        XCTAssertTrue(corrections(session, within: 0.4).isEmpty, "\(session.candidatePresentations.map(\.text))")
        session.reset()

        // Unfinished and correct spellings get none.
        for typed in ["nihaom", "zhongg", "shenme", "nihao", "woxiangshuo"] {
            _ = session.type(typed)
            waitUntilCurrent(session)
            XCTAssertTrue(corrections(session, within: 0.5).isEmpty, typed)
            session.reset()
        }
    }

    func testLettersNoPinyinTakesKeepTheSentenceGoing() throws {
        let session = try session()
        session.setChineseLanguageModel(false)
        _ = session.type("jinxingvimedexiugai")
        let deadline = Date().addingTimeInterval(5)
        while session.candidatePresentations.first?.text.contains("vime") != true, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let lead = try XCTUnwrap(session.candidatePresentations.first?.text)
        XCTAssertTrue(lead.hasPrefix("进行vime"), lead)
        XCTAssertTrue(lead.hasSuffix("修改"), "the pinyin after the word is converted too: \(lead)")
        XCTAssertEqual(session.space().last, .insert(lead))
        XCTAssertFalse(session.isComposing)
    }

    func testAbbreviatedPinyinBeforeAWordStaysPinyin() throws {
        let session = try session()
        session.setChineseLanguageModel(false)
        let lead = try waitForLead(session, typing: "wsmzhegeshurufavime") { $0.hasSuffix("vime") }
        XCTAssertEqual(lead, "为什么这个输入法vime")
        XCTAssertEqual(session.space().last, .insert(lead))
        XCTAssertFalse(session.isComposing)
    }

    func testAWordAfterAChosenStartKeepsWhatWasChosen() throws {
        let session = try session()
        session.setChineseLanguageModel(false)
        _ = try waitForLead(session, typing: "wsmzhegeshurufavime") { $0.hasSuffix("vime") }
        let start = try XCTUnwrap(session.candidatePresentations.first { $0.text == "为什么" }, "\(session.candidatePresentations.map(\.text))")
        XCTAssertEqual(session.chooseCandidate(try XCTUnwrap(start.selectionToken)), [])
        waitUntilCurrent(session)
        XCTAssertTrue(session.markedText?.text.hasPrefix("为什么") == true, "\(session.markedText?.text ?? "")")
        let lead = try waitForLead(session) { $0.hasSuffix("vime") }
        XCTAssertEqual(lead, "这个输入法vime", "the readings are of the rest")
        XCTAssertFalse(session.candidatePresentations.contains { $0.text.hasPrefix("wsm") || $0.text.hasPrefix("为什么") })
        XCTAssertEqual(session.space().last, .insert("为什么这个输入法vime"), "what was chosen goes out in front")
        XCTAssertFalse(session.isComposing)
    }

    func testAWordRightAfterAChosenStartStillGoesOn() throws {
        let session = try session()
        session.setChineseLanguageModel(false)
        _ = try waitForLead(session, typing: "woxianzailaishishizhegezuixindevimehaiyoumeiyouzhezhong") { $0.contains("vime") }
        let start = try XCTUnwrap(session.candidatePresentations.first { $0.text == "我现在来试试这个最新的" },
                                  "\(session.candidatePresentations.map(\.text))")
        XCTAssertEqual(session.chooseCandidate(try XCTUnwrap(start.selectionToken)), [])
        waitUntilCurrent(session)
        XCTAssertTrue(session.markedText?.text.hasPrefix("我现在来试试这个最新的vime") == true, "\(session.markedText?.text ?? "")")
        // Rime has nothing for a rest that starts with the word.
        XCTAssertEqual(session.candidatePresentations.first?.text, "vime还有没有这种")
        XCTAssertEqual(session.space().last, .insert("我现在来试试这个最新的vime还有没有这种"))
        XCTAssertFalse(session.isComposing)
    }

    /// After a start is chosen, every candidate is for the rest: Rime's,
    /// the readings keeping a word, and the corrections of a typo.
    func testAChosenStartLeavesOnlyTheRest() throws {
        for model in [false, true] {
            let session = try session()
            if model { try useModel() } else { session.setChineseLanguageModel(false) }
            for (typed, start, rest, meant) in [("woxianzaiyongvimedazi", "我现在", "用vime打字", "我现在用vime打字"),
                                                ("woxianzaishenem", "我现在", "什么", "我现在什么")] {
                _ = session.type(typed)
                waitUntilCurrent(session)
                XCTAssertEqual(session.chooseCandidate(try token(start, in: session)), [], typed)
                waitUntilCurrent(session)
                // Corrections come after a pause.
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                waitUntilCurrent(session)
                let shown = session.candidatePresentations.map(\.text)
                XCTAssertFalse(shown.contains { $0.hasPrefix(start) }, "\(typed) (model \(model)): \(shown)")
                let index = try XCTUnwrap(shown.firstIndex(of: rest), "\(typed) (model \(model)): \(shown)")
                let edits = session.chooseCandidate(try XCTUnwrap(session.candidatePresentations[index].selectionToken))
                waitUntilCurrent(session)
                XCTAssertEqual((batches.flatMap(\.edits) + edits).last, .insert(meant), "\(typed) (model \(model))")
                XCTAssertFalse(session.isComposing)
                batches = []
                session.reset()
            }
        }
    }

    /// Typed key by key, a word in the sentence included, each key's list
    /// shows once; at most the model's late scores and a correction found
    /// after a pause move it again, and never back to what it showed.
    func testEachKeyShowsItsListOnce() throws {
        for model in [false, true] {
            let session = try session()
            if model { try useModel() } else { session.setChineseLanguageModel(false) }
            var leads: [(text: String, source: CandidateSource)] = []
            session.onCandidatesChange = {
                guard session.candidatesAreCurrent, let first = session.candidatePresentations.first else { return }
                if leads.last?.text != first.text { leads.append((first.text, first.source)) }
            }
            for input in ["woxianzaiyongvimedazi", "zhegegithubcangkuhenhaoyong", "jintianyongVimexiezuoye"] {
                var typed = ""
                for letter in input {
                    typed.append(letter)
                    leads = []
                    _ = session.type(String(letter))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.45))
                    waitUntilCurrent(session)
                    let changes = leads.dropFirst()
                    let late = changes.filter { $0.source != .typoCorrection }
                    XCTAssertTrue(late.count <= (model ? 1 : 0) && changes.count - late.count <= 1
                                  && Set(leads.map(\.text)).count == leads.count,
                                  "\(typed) (model \(model)): \(leads.map(\.text))")
                }
                session.reset()
            }
        }
    }

    /// The model missing the window: the list shows in Rime's order, then
    /// takes the model's order once its scores come, as when they come in time.
    func testLateScoresRefineTheListOnce() throws {
        try useModel()
        for input in Self.reorderedByModel {
            let timely = try session()
            _ = timely.type(input)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            waitUntilCurrent(timely)
            let best = try XCTUnwrap(timely.candidatePresentations.first?.text)
            timely.reset()

            let session = try session()
            session.rankingWindow = 0
            var leads: [String] = []
            session.onCandidatesChange = {
                guard session.candidatesAreCurrent, let first = session.candidatePresentations.first?.text else { return }
                if leads.last != first { leads.append(first) }
            }
            _ = session.type(input)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            waitUntilCurrent(session)
            XCTAssertEqual(leads.count, 2, "\(input): \(leads)")
            XCTAssertEqual(leads.last, best, input)
            session.reset()
        }
    }

    /// Inputs whose first sentence the model changes from Rime's.
    private static let reorderedByModel = ["zhejiancanguantaiguile", "laoshibuzhidelianxitaiduole"]

    /// The bundled Chinese model, warm, in place of the keyboard's.
    private func useModel() throws {
        let model = try ChineseLanguageModel(bundle: Bundle(for: Self.self), preload: true)
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        JapaneseCandidateWorker.modelQueue.sync { storage.useChinese(model) }
        storage.setSuspended(false)
        addTeardownBlock { JapaneseCandidateWorker.modelQueue.sync { storage.release() } }
    }

    /// Types `input`, then waits for a first candidate `matching`.
    private func waitForLead(_ session: ChineseInputSession, typing input: String = "",
                             matching: (String) -> Bool) throws -> String {
        if !input.isEmpty { _ = session.type(input) }
        let deadline = Date().addingTimeInterval(5)
        while session.candidatePresentations.first.map({ matching($0.text) }) != true, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return try XCTUnwrap(session.candidatePresentations.first?.text.nilIfUnmatched(matching),
                             "\(session.candidatePresentations.map(\.text))")
    }

    func testResetDropsPendingWorkAndMovesTheEpoch() throws {
        let session = try session()
        let epoch = session.hostEpoch
        _ = session.type("nihao")
        session.reset()
        XCTAssertEqual(session.hostEpoch, epoch + 1)
        XCTAssertNil(session.markedText)
        waitUntilCurrent(session)
        XCTAssertFalse(session.isComposing, "results from before the reset are discarded")
        XCTAssertTrue(session.candidatePresentations.isEmpty)
        session.reset(preservingContext: true)
        XCTAssertEqual(session.hostEpoch, epoch + 1)
    }

    func testEnglishPreservesCandidatesAndCommitsLettersOnTypingOrToggleBack() throws {
        let session = try session()
        // 1. Toggle to English keeps candidates; typing commits raw pinyin + letter and suppresses completions.
        _ = session.type("zhongwen")
        waitUntilCurrent(session)
        XCTAssertFalse(session.candidatePresentations.isEmpty)
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertEqual(session.inputTraits.language, .english)
        XCTAssertTrue(session.isComposing)
        XCTAssertFalse(session.candidatePresentations.isEmpty)
        XCTAssertEqual(session.inputTraits.comma, ",")
        XCTAssertEqual(session.type("A"), [.insert("zhongwen"), .insert("A")])
        XCTAssertFalse(session.isComposing)
        XCTAssertTrue(session.candidatePresentations.isEmpty)
        XCTAssertTrue(session.suppressesEnglishCompletions)
        XCTAssertEqual(session.type("b"), [.insert("b")])
        XCTAssertTrue(session.suppressesEnglishCompletions)
        XCTAssertEqual(session.space(), [.insert(" ")])
        XCTAssertFalse(session.suppressesEnglishCompletions)
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertEqual(session.inputTraits.language, .chinese)
        XCTAssertEqual(session.inputTraits.comma, "，")

        // 2. Backspace keeps Chinese candidates; Space commits the first candidate.
        var commits: [String] = []
        session.onCommittedEdits = { batch in
            for case .insert(let text) in batch.edits { commits.append(text) }
        }
        _ = session.type("zhongwen")
        waitUntilCurrent(session)
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertEqual(session.backspace(), [])
        waitUntilCurrent(session)
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(session.raw, "zhongwe")
        XCTAssertFalse(session.candidatePresentations.isEmpty)
        let lead = try XCTUnwrap(session.candidatePresentations.first?.text)
        let immediate = session.space()
        waitUntilCurrent(session)
        let spaceCommitted = immediate.compactMap { if case .insert(let t) = $0 { return t }; return nil } + commits
        XCTAssertEqual(spaceCommitted.joined(), lead)
        XCTAssertFalse(session.isComposing)
        XCTAssertEqual(session.inputTraits.language, .english)

        // 3. Return commits directly while candidates are kept in English.
        commits = []
        XCTAssertEqual(session.toggleEnglish(), [])
        _ = session.type("nihao")
        waitUntilCurrent(session)
        XCTAssertEqual(session.toggleEnglish(), [])
        _ = session.enter()
        waitUntilCurrent(session)
        XCTAssertEqual(commits.joined(), "nihao")
        XCTAssertFalse(session.isComposing)

        // 4. Toggling back to Chinese while composing commits raw letters with no candidates left.
        XCTAssertEqual(session.toggleEnglish(), [])
        _ = session.type("nihao")
        waitUntilCurrent(session)
        XCTAssertEqual(session.toggleEnglish(), [])
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(session.toggleEnglish(), [.insert("nihao")])
        XCTAssertEqual(session.inputTraits.language, .chinese)
        XCTAssertFalse(session.isComposing)
        XCTAssertTrue(session.candidatePresentations.isEmpty)
    }

    func testExpandedPanelGetsALongerList() throws {
        let session = try session()
        _ = session.type("shi")
        waitUntilCurrent(session)
        XCTAssertEqual(session.candidateCount, ChineseInputSession.collapsedCandidateLimit)
        session.setExpandedCandidates(true)
        waitUntilCurrent(session)
        XCTAssertGreaterThan(session.candidateCount, ChineseInputSession.collapsedCandidateLimit)
        let beyond = session.candidatePage(offset: ChineseInputSession.collapsedCandidateLimit, limit: 5)
        XCTAssertFalse(beyond.isEmpty)
        XCTAssertEqual(beyond.first?.selectionToken?.index, ChineseInputSession.collapsedCandidateLimit)
        session.reset()
    }

    func testKeyboardViewAppliesAsynchronousCommits() throws {
        let session = try session()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        keyboard.layoutIfNeeded()
        var edits: [KeyboardEdit] = []
        var preedits: [String?] = []
        keyboard.onEdit = { edits += $0 }
        keyboard.onPreeditChange = { preedits.append($0?.text) }
        keyboard.apply(session.type("nihao"))
        XCTAssertEqual(preedits.last, "nihao")
        waitUntilCurrent(session)
        XCTAssertEqual(preedits.last, "ni\u{2006}hao", "syllables are joined by a narrow space, not a full one")
        let button = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "候选词：你好" && $0.isUserInteractionEnabled })
        button.sendActions(for: .touchUpInside)
        waitUntilCurrent(session)
        XCTAssertEqual(edits, [.insert("你好")])
        XCTAssertEqual(preedits.last, .some(nil))
    }

    func testLeadingSyllableOptions() {
        XCTAssertEqual(PinyinLeadingSyllable.options(for: "xianren"), ["xian", "xia", "xi"])
        XCTAssertEqual(PinyinLeadingSyllable.options(for: "fangan"), ["fang", "fan", "fa"])
        XCTAssertEqual(PinyinLeadingSyllable.options(for: "xiu"), ["xiu"], "xi would leave a u no syllable starts with")
        XCTAssertEqual(PinyinLeadingSyllable.options(for: "nihao"), ["ni"], "a lone n is not offered")
        XCTAssertEqual(PinyinLeadingSyllable.input("xianren", leadingWith: "xi"), "xi'anren")
        XCTAssertEqual(PinyinLeadingSyllable.input("xi'anren", leadingWith: "xia"), "xia'nren")
        XCTAssertEqual(PinyinLeadingSyllable.input("xian'ren", leadingWith: "xian"), "xian'ren")
        XCTAssertEqual(PinyinLeadingSyllable.input("xian", leadingWith: "xian"), "xian")
        XCTAssertEqual(PinyinLeadingSyllable.input("zifu", replacing: 2, with: "zhi"), "zhi'fu")
        XCTAssertEqual(PinyinLeadingSyllable.alternatives(to: "zi", excluding: []).first, "zhi")
        XCTAssertEqual(PinyinLeadingSyllable.alternatives(to: "lan", excluding: []).prefix(3), ["nan", "ran", "lang"])
        XCTAssertEqual(PinyinLeadingSyllable.alternatives(to: "xian", excluding: ["xia"]).first, "xiang")
        XCTAssertTrue(PinyinLeadingSyllable.alternatives(to: "wo", excluding: []).allSatisfy {
            PinyinSpellingCorrection.syllables.contains($0) && $0 != "wo" })
        XCTAssertLessThanOrEqual(PinyinLeadingSyllable.alternatives(to: "de", excluding: []).count, 4)
    }

    /// The panel's syllable column: picking xi of xianren lists what starts
    /// with xi; choosing 西 takes xi off the front and the rest stays open.
    func testPickingTheLeadingSyllable() throws {
        let session = try session()
        session.setChineseLanguageModel(false)
        _ = session.type("xianren")
        waitUntilCurrent(session)
        XCTAssertEqual(session.leadingSyllables.prefix(3), ["xian", "xia", "xi"])
        XCTAssertEqual(session.currentLeadingSyllable, "xian")
        XCTAssertEqual(session.chooseLeadingSyllable("xi"), [])
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "xi'anren")
        XCTAssertEqual(session.currentLeadingSyllable, "xi")
        XCTAssertEqual(session.leadingSyllables.prefix(3), ["xian", "xia", "xi"], "the column keeps the input's options")
        let shown = session.candidatePresentations.map(\.text)
        XCTAssertTrue(shown.contains("西") && !shown.contains("先") && !shown.contains("现"), "\(shown)")
        // Rime's own reading puts the input back as typed.
        _ = session.chooseLeadingSyllable("xian")
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "xianren")
        _ = session.chooseLeadingSyllable("xi")
        waitUntilCurrent(session)
        XCTAssertEqual(session.chooseCandidate(try token("西", in: session)), [])
        waitUntilCurrent(session)
        XCTAssertTrue(batches.isEmpty, "the rest is still being typed")
        XCTAssertTrue(session.isComposing)
        XCTAssertTrue(session.markedText?.text.hasPrefix("西") == true, session.markedText?.text ?? "")
        XCTAssertEqual(session.currentLeadingSyllable, "an")
        XCTAssertEqual(session.leadingSyllables.prefix(2), ["an", "a"])
        session.reset()
        // The column stays for each piece, one with a single reading too.
        _ = session.type("xianshi")
        waitUntilCurrent(session)
        _ = session.chooseLeadingSyllable("xi")
        waitUntilCurrent(session)
        _ = session.chooseCandidate(try token("西", in: session))
        waitUntilCurrent(session)
        _ = session.chooseCandidate(try token("安", in: session))
        waitUntilCurrent(session)
        XCTAssertTrue(batches.isEmpty, "the rest is still being typed")
        XCTAssertEqual(session.leadingSyllables.first, "shi")
        XCTAssertEqual(session.currentLeadingSyllable, "shi")
        session.reset()
        _ = session.type("xianren")
        waitUntilCurrent(session)
        _ = session.chooseLeadingSyllable("xi")
        waitUntilCurrent(session)
        _ = session.chooseCandidate(try token("西", in: session))
        waitUntilCurrent(session)
        // After a chosen start, a pick sends that start out first.
        XCTAssertEqual(session.chooseLeadingSyllable("a"), [.insert("西")])
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "a'nren")
        XCTAssertEqual(session.currentLeadingSyllable, "a")
        session.reset()
    }

    func testExpandedPanelShowsTheSyllableColumn() throws {
        let session = try session()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        keyboard.layoutIfNeeded()
        keyboard.apply(session.type("xianren"))
        waitUntilCurrent(session)
        keyboard.toggleExpanded()
        waitUntilCurrent(session)
        keyboard.refresh()
        keyboard.layoutIfNeeded()
        XCTAssertFalse(keyboard.syllableColumn.isHidden)
        XCTAssertEqual(keyboard.syllableButtons.prefix(3).map { $0.title(for: .normal) }, ["xian", "xia", "xi"])
        XCTAssertEqual(keyboard.syllableButtons.first?.isSelected, true)
        let firstCandidate = try XCTUnwrap(keyboard.panelCandidates.first)
        XCTAssertGreaterThanOrEqual(firstCandidate.frame.minX, keyboard.syllableColumn.frame.maxX, "candidates sit right of the column")
        keyboard.syllableButtons[2].sendActions(for: .touchUpInside)
        waitUntilCurrent(session)
        keyboard.layoutIfNeeded()
        XCTAssertEqual(session.raw, "xi'anren")
        XCTAssertEqual(keyboard.syllableButtons[2].isSelected, true)
        keyboard.toggleExpanded()
        keyboard.layoutIfNeeded()
        XCTAssertTrue(keyboard.syllableColumn.isHidden)
        session.reset()
    }

    /// A similar sound in the column respells the syllable: zi read as zhi.
    func testSyllableColumnOffersCorrections() throws {
        let session = try session()
        session.setChineseLanguageModel(false)
        _ = session.type("zifu")
        waitUntilCurrent(session)
        XCTAssertTrue(session.correctedLeadingSyllables.contains("zhi"), "\(session.leadingSyllables)")
        XCTAssertEqual(session.chooseLeadingSyllable("zhi"), [])
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "zhi'fu")
        XCTAssertEqual(session.currentLeadingSyllable, "zhi")
        XCTAssertTrue(session.candidatePresentations.map(\.text).contains("支付"), "\(session.candidatePresentations.map(\.text))")
        // Rime's own reading puts the typed letters back.
        _ = session.chooseLeadingSyllable("zi")
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "zifu")
        session.reset()
    }

    /// Picking a syllable after a chosen start keeps the panel open.
    func testPickingAfterAChosenStartKeepsThePanel() throws {
        let session = try session()
        session.setChineseLanguageModel(false)
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        var edits: [KeyboardEdit] = []
        keyboard.onEdit = { edits += $0 }
        keyboard.layoutIfNeeded()
        keyboard.apply(session.type("xianren"))
        waitUntilCurrent(session)
        keyboard.toggleExpanded()
        waitUntilCurrent(session)
        keyboard.refresh()
        keyboard.syllableButtons[2].sendActions(for: .touchUpInside)
        waitUntilCurrent(session)
        keyboard.refresh()
        keyboard.apply(session.chooseCandidate(try token("西", in: session)))
        waitUntilCurrent(session)
        keyboard.refresh()
        XCTAssertEqual(keyboard.panel, .candidates)
        let a = try XCTUnwrap(keyboard.syllableButtons.first { $0.title(for: .normal) == "a" })
        a.sendActions(for: .touchUpInside)
        waitUntilCurrent(session)
        keyboard.refresh()
        XCTAssertEqual(edits, [.insert("西")])
        XCTAssertEqual(session.raw, "a'nren")
        XCTAssertEqual(keyboard.panel, .candidates, "the panel stays open")
        XCTAssertFalse(keyboard.syllableColumn.isHidden)
        session.reset()
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

private extension String {
    func nilIfUnmatched(_ matching: (String) -> Bool) -> String? { matching(self) ? self : nil }
}
