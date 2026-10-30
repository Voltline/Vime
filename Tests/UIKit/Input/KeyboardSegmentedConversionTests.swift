import XCTest
import UIKit
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardSegmentedConversionTests: XCTestCase {
    func testRangeConfirmationWithoutSpaceKeepsRemainder() throws {
        let session = KeyboardSession()
        _ = session.type("toukyouhantenn")
        session.adjustConversionRange(by: -4)
        let expected = try XCTUnwrap(session.candidateSnapshots.first)
        XCTAssertFalse(expected.fullConsumption)
        XCTAssertEqual(session.enter(), [.insert(expected.text)])
        XCTAssertEqual(session.raw, "hantenn")
        XCTAssertEqual(session.preedit, "はんてん")
    }

    func testPendingRangeConfirmationConsumesOnlySelectedKana() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        _ = session.type("toukyouhantenn")
        session.adjustConversionRange(by: -4)
        XCTAssertFalse(session.candidatesAreCurrent)
        XCTAssertEqual(session.enter(), [.insert("とうきょう")])
        XCTAssertEqual(session.raw, "hantenn")
        XCTAssertEqual(session.preedit, "はんてん")
        let deadline = Date().addingTimeInterval(8)
        while !session.candidatesAreCurrent && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.candidatesAreCurrent)
        XCTAssertEqual(session.raw, "hantenn", "Late prefix results must not complete or replace the remainder")
        XCTAssertEqual(session.preedit, "はんてん")
        session.reset()
        _ = session.type("kan")
        session.adjustConversionRange(by: 0)
        XCTAssertEqual(session.enter(), [.insert("かん")], "Explicit confirmation still finalizes ambiguous n within the chosen unit")
        XCTAssertFalse(session.isComposing)
    }

    func testPanelPartialSelectionKeepsSuffixMarkedAndConvertible() async throws {
        try await exercisePartialSelection(confirmRange: false)
    }

    func testKeyboardReturnAfterRangeSelectionKeepsSuffixMarked() async throws {
        try await exercisePartialSelection(confirmRange: true)
    }

    func testAutomaticPrefixCandidateKeepsSuffixMarked() async throws {
        try await exercisePartialSelection(confirmRange: false, automaticPrefix: true)
    }

    func testExpandedSingleWordCandidateKeepsAllFollowingKanaMarked() async throws {
        try await exercisePartialSelection(confirmRange: false, singlePrefix: true)
    }

    func testExpandedMenuOffersTiananWithoutRangeAdjustment() async throws {
        try await exercisePartialSelection(confirmRange: false, automaticTianan: true)
    }

    private func exercisePartialSelection(confirmRange: Bool, automaticPrefix: Bool = false, singlePrefix: Bool = false,
                                          automaticTianan: Bool = false) async throws {
        let directory = isolatedLearningDirectory()
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 240, width: 440, height: 350), session: session)
        session.updateIntelligence(ranking: automaticTianan ? .languageModel : .engine, suggestionsEnabled: false)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        let text = UITextView(frame: CGRect(x: 0, y: 0, width: 440, height: 220))
        window.rootViewController?.view.addSubview(text)
        window.rootViewController?.view.addSubview(keyboard)
        window.isHidden = false
        defer { keyboard.stopInteractions(); window.isHidden = true }
        let host = KeyboardHostConnection(setMarkedText: { text.setMarkedText($0, selectedRange: $1) },
            unmarkText: { text.unmarkText() }, insertText: { text.insertText($0) }, deleteBackward: { text.deleteBackward() })
        var edits: [KeyboardEdit] = []
        keyboard.onEdit = { edits += $0; host.apply($0) }
        keyboard.onPreeditChange = { host.updatePreedit($0) }
        keyboard.leftContextProvider = {
            let before = (text.text as NSString).substring(to: text.selectedRange.location)
            return host.markedText.map { before.hasSuffix($0) ? String(before.dropLast($0.count)) : before } ?? before
        }
        keyboard.learningContextProvider = { [weak keyboard] in
            KeyboardLearningContext(document: "segment-fixture", before: keyboard?.leftContextProvider?(),
                after: (text.text as NSString).substring(from: NSMaxRange(text.selectedRange)), hasSelection: text.selectedRange.length > 0)
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func button(_ id: String) throws -> UIButton {
            try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == id } as? UIButton)
        }
        func visible(_ view: UIView) -> Bool {
            !view.isHidden && (view.superview.map(visible) ?? true)
        }
        func ready() async throws {
            let deadline = Date().addingTimeInterval(8)
            while !session.candidatesAreCurrent && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(session.candidatesAreCurrent)
            keyboard.layoutIfNeeded()
        }
        keyboard.layoutIfNeeded()
        for c in automaticPrefix ? "toukyouhantenn" : "tennanhantenn" {
            (try button("vime.key.\(c)") as? KeyboardKey)?.action?()
        }
        try await ready()
        try button("vime.candidates.expand").sendActions(for: .touchUpInside)
        try await ready()
        if !automaticPrefix && !singlePrefix && !automaticTianan {
            try button("vime.segment.shorten").sendActions(for: .touchUpInside)
            try await ready()
            while (session.conversionRangeDescription?.split(separator: "｜").first?.count ?? 0) > 4 {
                try button("vime.segment.shorten").sendActions(for: .touchUpInside); try await ready()
            }
            while (session.conversionRangeDescription?.split(separator: "｜").first?.count ?? 0) < 4 {
                try button("vime.segment.lengthen").sendActions(for: .touchUpInside); try await ready()
            }
        }
        let prefixText = confirmRange ? try XCTUnwrap(session.candidates.first) : automaticPrefix ? "東京" : singlePrefix ? "天" : "天安"
        if singlePrefix {
            print("SINGLE_PREFIX \(session.candidateSnapshots.filter { $0.text == "天" }.map { "\($0.reading):\($0.remainingComposition.convertTarget):\($0.source)" })")
        }
        if confirmRange {
            try button("vime.panel.close").sendActions(for: .touchUpInside)
            (try button("vime.key.return") as? KeyboardKey)?.action?()
        } else {
            let deadline = Date().addingTimeInterval(10)
            var candidate: UIButton?
            while candidate == nil && Date() < deadline {
                candidate = descendants(keyboard).compactMap { $0 as? UIButton }.first {
                    $0.title(for: .normal) == prefixText && $0.superview is UIScrollView && !$0.isHidden && $0.isUserInteractionEnabled
                }
                if candidate == nil {
                    // Exercise the full menu's existing incremental paging.
                    keyboard.layoutIfNeeded()
                    if automaticTianan, let panel = descendants(keyboard).compactMap({ $0 as? UIScrollView }).first(where: {
                        $0.subviews.contains { ($0 as? UIButton)?.title(for: .normal) == session.candidates.first }
                            && !$0.isHidden && $0.contentSize.height > $0.bounds.height
                    }) {
                        panel.setContentOffset(CGPoint(x: 0, y: max(0, panel.contentSize.height - panel.bounds.height)), animated: false)
                        keyboard.scrollViewDidScroll(panel)
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let prefix = try XCTUnwrap(candidate)
            if let panel = prefix.superview as? UIScrollView {
                keyboard.layoutIfNeeded()
                panel.scrollRectToVisible(prefix.frame, animated: false)
                let point = prefix.convert(CGPoint(x: prefix.bounds.midX, y: prefix.bounds.midY), to: window)
                XCTAssertTrue(window.hitTest(point, with: nil) === prefix,
                    "The displayed menu candidate must own its actual hit area")
            }
            prefix.sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(edits, [.insert(prefixText)])
        let remaining = singlePrefix ? "あんはんてん" : "はんてん"
        XCTAssertEqual(session.raw, singlePrefix ? "anhantenn" : "hantenn")
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(host.markedText, remaining)
        XCTAssertEqual(text.text(in: try XCTUnwrap(text.markedTextRange)), remaining)
        XCTAssertEqual(text.text, prefixText + remaining)
        try await ready()
        if singlePrefix {
            // Exercise the rest of the exact user path, not just the first tap.
            let an = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? UIButton }.first {
                $0.title(for: .normal) == "安" && visible($0) && $0.isUserInteractionEnabled
            })
            an.sendActions(for: .touchUpInside)
            try await ready()
            XCTAssertEqual(session.raw, "hantenn")
            XCTAssertEqual(host.markedText, "はんてん")
        }
        let suffix = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? UIButton }.first {
            $0.title(for: .normal) == "飯店" && visible($0) && $0.isUserInteractionEnabled
        })
        suffix.sendActions(for: .touchUpInside)
        XCTAssertEqual(edits, singlePrefix ? [.insert("天"), .insert("安"), .insert("飯店")] : [.insert(prefixText), .insert("飯店")])
        XCTAssertEqual(text.text, (singlePrefix ? "天安" : prefixText) + "飯店")
        XCTAssertNil(text.markedTextRange)
        XCTAssertFalse(session.isComposing)
    }

    func testCandidateTouchCannotSelectReplacementAfterPrimaryPublication() throws {
        let session = KeyboardSession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        _ = session.type("tennanhantenn")
        session.onCandidatesChange?()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let expand = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates.expand" } as? UIButton)
        expand.sendActions(for: .touchUpInside)
        let button = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? UIButton }.first {
            $0.title(for: .normal) == "天" && $0.superview is UIScrollView
        })
        let originalInput = session.raw
        var committed: [KeyboardEdit] = []
        keyboard.onEdit = { committed += $0 }
        button.sendActions(for: .touchDown)
        session.acceptCandidateUpdate(Array(session.candidateSnapshots.reversed()), revision: session.revision, supplementary: false)
        XCTAssertNotEqual(button.title(for: .normal), "天", "The same pooled button now presents another candidate")
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(session.raw, originalInput)
        XCTAssertTrue(committed.isEmpty, "A stale touched token must not commit a replacement")
    }

    func testAutomaticPrefixCoverageIncludesUnrecognisedWholePhrase() throws {
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        let engine = JapaneseCandidateEngine()
        let composition = query("tennanhantenn")
        let base = engine.candidates(for: composition, revision: 1, includeCorrections: false)
        let values = engine.addingPrefixCandidates(to: base, for: composition, katakana: false, revision: 1)
        print("PREFIX_EXPANDED " + values.enumerated().filter { ["天", "天安", "天案", "てんあん"].contains($0.element.text) }
            .map { "\($0.offset + 1):\($0.element.text):\($0.element.reading):\($0.element.consumedReadingCount):\($0.element.remainingComposition.convertTarget):engineRank=\($0.element.engineRank):words=\($0.element.candidate.data.map(\.word))" }.joined(separator: " | "))
        print("PREFIX_TIMING \(KeyboardPerformance.report()) count=\(values.count)")
        let tianan = try XCTUnwrap(values.first { $0.text == "天安" && $0.remainingComposition.convertTarget == "はんてん" })
        XCTAssertEqual(tianan.consumedReadingCount, 4)
        XCTAssertTrue(tianan.exactReading && tianan.engineFullConsumption && !tianan.fullConsumption)
        for length in 1..<composition.convertTarget.count {
            XCTAssertTrue(values.contains { $0.consumedReadingCount == length }, "Boundary \(length)")
        }
        XCTAssertEqual(engine.addingPrefixCandidates(to: base, for: composition, katakana: false,
            revision: 1, cancelled: { true }).map(\.presentation), base.map(\.presentation))
    }

    private func query(_ raw: String) -> ComposingText {
        var value = ComposingText()
        RomajiConverter.insert(raw, into: &value)
        return value
    }

    func testPartialCommitPreservesRomanRemainderAndLearning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = KeyboardSession(memoryDirectoryURL: directory)
        _ = session.type("tennanhantenn")
        print("SEGMENT_INPUT \(session.raw) \(session.composition)")
        session.adjustConversionRange(by: -4)
        let tianan = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "天安" && !$0.fullConsumption })
        XCTAssertEqual(session.choose(tianan), [.insert("天安")])
        XCTAssertEqual(session.preedit, "はんてん")
        XCTAssertEqual(session.raw, "hantenn")
        _ = session.backspace()
        XCTAssertEqual(session.preedit, "はんて")
        _ = session.type("nn")
        XCTAssertEqual(session.preedit, "はんてん")
        let hotel = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "飯店" && $0.fullConsumption })
        XCTAssertEqual(session.choose(hotel), [.insert("飯店")])
        // Test an independently known prefix too, without requiring a dictionary
        // to recognize an entire unfamiliar proper name.
        session.reset()
        _ = session.type("toukyouhantenn")
        session.adjustConversionRange(by: -4)
        print("SEGMENT_RANGE \(session.conversionRangeDescription ?? "") \(session.candidates)")
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "東京" && !$0.fullConsumption })
        let selected = session.candidateSnapshots[index]
        XCTAssertEqual(selected.reading, "トウキョウ")
        XCTAssertTrue(selected.exactReading && selected.scopeFullConsumption && selected.learningEligible)
        XCTAssertEqual(selected.remainingComposition.convertTarget, "はんてん")
        XCTAssertEqual(session.choose(index), [.insert("東京")])
        XCTAssertEqual(session.raw, "hantenn")
        XCTAssertEqual(session.preedit, "はんてん")
        session.reset()
        _ = session.type("toukyouhantenn")
        session.adjustConversionRange(by: -4)
        let again = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "東京" && !$0.fullConsumption })
        _ = session.choose(again)
        session.reset()
        let memory = CandidatePreferenceMemory(directory: directory)
        XCTAssertGreaterThan(memory.score(reading: "トウキョウ", surface: "東京"), 0)
        let restored = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        XCTAssertTrue(restored.candidates(for: query("toukyou"), revision: 1, includeCorrections: false).contains {
            $0.text == "東京" && $0.hasLearningEvidence
        })
    }

    func testEveryKanaBoundaryCanBeSelectedWithoutEatingSuffix() throws {
        let engine = JapaneseCandidateEngine()
        for input in ["kyouhantenn", "gakkouhantenn", "tennanhantenn"] {
            let composition = query(input)
            for length in 1..<composition.convertTarget.count {
                let values = engine.candidates(for: composition, revision: length, includeCorrections: false, conversionLength: length)
                let literal = String(composition.convertTarget.prefix(length))
                let value = try XCTUnwrap(values.first { $0.text == literal && $0.scopeFullConsumption }, "\(input) boundary \(length)")
                XCTAssertEqual(value.remainingComposition.convertTarget, String(composition.convertTarget.dropFirst(length)))
                XCTAssertEqual(value.consumedReadingCount, length)
                XCTAssertNotNil(value.presentation.annotation)
            }
        }
    }

    func testShortNeighborCorrectionsAndCorrectInputProtection() throws {
        let engine = JapaneseCandidateEngine(); engine.diagnosticsEnabled = true
        for input in ["dedu", "masy", "arigatougozaimadu"] {
            engine.reset()
            let values = engine.candidates(for: query(input), revision: 3)
            print("NEIGHBOR \(input) \(values.filter { $0.correction != nil }.map { "\($0.text):\($0.correction!.suggestedReading)" })")
            if input == "dedu" {
                XCTAssertTrue(values.contains { $0.correction?.correctedRomanInput == "desu" && $0.reading == "デス" })
            }
        }
        let variants = KeyboardCorrectionVariants.generate(for: query("dedu"))
        XCTAssertTrue(variants.allSatisfy { $0.suggestion.kind == .neighboringKey && $0.suggestion.editCount == 1 })
        for input in ["desu", "masu", "sushi", "kega"] {
            engine.reset()
            XCTAssertFalse(engine.candidates(for: query(input), revision: 4).contains { $0.correction != nil }, input)
        }
        XCTAssertTrue(KeyboardCorrectionVariants.generate(for: query("ki")).isEmpty)
    }

    func testSystemTextReplacementsAreConversionCandidates() {
        defer { JapaneseSystemShortcuts.update([]) }
        let engine = JapaneseCandidateEngine()
        JapaneseSystemShortcuts.update([("おつ", "お疲れさまです"), ("ｏｍｗ", "On my way"), ("おつ", "お疲れさまです")])
        XCTAssertEqual(JapaneseSystemShortcuts.entries.count, 1, "Non-kana and repeated shortcuts are dropped")
        XCTAssertTrue(engine.candidates(for: query("otsu"), revision: 1, includeCorrections: false).contains { $0.text == "お疲れさまです" })
        JapaneseSystemShortcuts.update([])
        XCTAssertFalse(engine.candidates(for: query("otsu"), revision: 2, includeCorrections: false).contains { $0.text == "お疲れさまです" })
    }

    func testOrthographyAndSupplementalDictionaryAreSelectable() throws {
        let engine = JapaneseCandidateEngine()
        let values = engine.candidates(for: query("kega"), revision: 7, includeCorrections: false)
        print("ORTHOGRAPHY \(values.prefix(12).map { "\($0.text):\($0.features.orthography)" })")
        let kana = try XCTUnwrap(values.firstIndex { $0.text == "けが" })
        let kanji = try XCTUnwrap(values.firstIndex { $0.text == "怪我" })
        XCTAssertLessThan(kana, kanji)
        if values[kana].displaySurface != nil { XCTAssertFalse(values[kana].learningEligible) }
        let words = JapaneseLanguageResources.shared.matchingWords("リアジュウ")
        XCTAssertTrue(words.contains { $0.word == "リア充" })
        let slang = engine.candidates(for: query("riajuu"), revision: 8, includeCorrections: false)
        XCTAssertTrue(slang.contains { $0.text == "リア充" && $0.lexical })
        let model = try VimeLanguageModel()
        let spellings = [values[kana], values[kanji]]
        let neural = model.rerank(spellings, context: "", katakana: false, cancelled: { false })
        print("ORTHOGRAPHY_NEURAL \(neural.map(\.text))")
        XCTAssertEqual(neural.first?.text, "けが")
    }

    func testCandidateTimingAndUncappedPool() throws {
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        let engine = JapaneseCandidateEngine()
        for input in ["yo-r", "yo-roppa", "be-to-ben", "dedu", "toukyouhantenn"] {
            let composing = query(input.replacingOccurrences(of: "-", with: "ー"))
            let started = KeyboardPerformance.start()
            engine.reconcileContext("昨日")
            let base = engine.candidates(for: composing, revision: 9, includeCorrections: false)
            KeyboardPerformance.record(.candidateCompute, since: started)
            let typoStarted = KeyboardPerformance.start()
            let values = engine.addingCorrections(to: base, for: composing, katakana: false, revision: 9)
            KeyboardPerformance.record(.correctionCompute, since: typoStarted)
            print("SEGMENT_CANDIDATES \(input) \(values.prefix(12).map(\.text)) total=\(values.count)")
        }
        let many = engine.candidates(for: query("hashi"), revision: 10, includeCorrections: false, conversionLength: 2)
        XCTAssertGreaterThan(many.count, 15)
        print("SEGMENT_PERFORMANCE \(KeyboardPerformance.report())")
    }

    func testPartialFeedbackCanBeCancelledBeforeLearning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        let values = engine.candidates(for: query("hashihantenn"), revision: 1, includeCorrections: false, conversionLength: 2)
        let eligible = values.enumerated().filter { $0.element.learningEligible && $0.element.exactReading && !$0.element.fullConsumption }
        let selection = try XCTUnwrap(eligible.dropFirst().first)
        let rejected = CandidateLearningFeedback(id: UUID(), kind: .explicitCandidate, rank: selection.offset, context: "", selectedAt: Date())
        engine.stageSelection(selection.element, event: rejected)
        engine.resolveFeedback(rejected.id, accepted: false)
        engine.flushLearning()
        XCTAssertEqual(CandidatePreferenceMemory(directory: directory).score(reading: selection.element.reading, surface: selection.element.text), 0)
        for _ in 0..<8 {
            let feedback = CandidateLearningFeedback(id: UUID(), kind: .explicitCandidate, rank: selection.offset, context: "", selectedAt: Date())
            engine.stageSelection(selection.element, event: feedback)
            engine.resolveFeedback(feedback.id, accepted: true)
        }
        let restored = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        let final = restored.candidates(for: query("hashihantenn"), revision: 2, includeCorrections: false, conversionLength: 2)
        let rank = try XCTUnwrap(final.firstIndex { $0.text == selection.element.text && $0.exactReading })
        print("SEGMENT_LEARNING \(selection.element.text) \(selection.offset + 1) -> \(rank + 1)")
        XCTAssertLessThan(rank, selection.offset)
        XCTAssertGreaterThan(final[rank].userPreferenceScore, 0)
        XCTAssertTrue(final[rank].hasLearningEvidence)
    }

    func testBackspaceRightAfterConversionRestoresItsReading() throws {
        let session = KeyboardSession()
        var host = ""
        session.leftContextProvider = { host }
        func run(_ edits: [KeyboardEdit]) {
            for edit in edits {
                switch edit {
                case .insert(let text): host += text
                case .deleteBackward: if !host.isEmpty { host.removeLast() }
                default: XCTFail("Unexpected \(edit)")
                }
            }
        }
        func convert() throws -> String {
            run(session.type("nihongo"))
            let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.fullConsumption && $0.text != "にほんご" })
            let text = session.candidateSnapshots[index].text
            run(session.choose(index))
            XCTAssertFalse(session.isComposing)
            return text
        }

        XCTAssertFalse(session.undoesCommitOnBackspace, "Backspace undo is opt-in")
        let plain = try convert()
        XCTAssertEqual(session.reconvertibleCommit?.text, plain)
        XCTAssertEqual(session.reconvertibleCommit?.reading, "にほんご")
        XCTAssertTrue(session.showsStrip, "The reconvert chip keeps the toolbar row")
        run(session.backspace())
        XCTAssertEqual(host, String(plain.dropLast()), "Backspace deletes normally while undo is off")
        XCTAssertNil(session.reconvertibleCommit, "Backspace forgets the conversion")
        session.reset(); host = ""

        let chip = try convert()
        XCTAssertEqual(host, chip)
        run(session.reconvertCommit())
        XCTAssertEqual(host, "")
        XCTAssertEqual(session.preedit, "にほんご", "The chip returns the conversion to its reading")
        XCTAssertNil(session.reconvertibleCommit)
        session.reset(); host = ""

        let dismissed = try convert()
        session.dismissSuggestions()
        XCTAssertNil(session.reconvertibleCommit, "Closing the next-word row drops the chip")
        XCTAssertEqual(host, dismissed)
        session.reset(); host = ""

        session.setUndoesCommitOnBackspace(true)
        _ = try convert()
        run(session.backspace())
        XCTAssertEqual(host, "")
        XCTAssertEqual(session.preedit, "にほんご", "One backspace returns the conversion to its reading")

        run(session.backspace())
        XCTAssertTrue(session.isComposing, "Later backspaces edit the reading")
        session.reset(); host = ""

        let second = try convert()
        run(session.space()); run(session.backspace())
        XCTAssertEqual(host, second, "Any other action forgets the conversion")
        run(session.backspace())
        XCTAssertEqual(host, String(second.dropLast()))
        XCTAssertFalse(session.isComposing)
        session.reset(); host = ""

        let changed = try convert()
        host += "x"
        run(session.backspace())
        XCTAssertEqual(host, changed, "A changed host is never rewritten")
        XCTAssertFalse(session.isComposing)
        session.reset(); host = ""

        session.setUndoesCommitOnBackspace(false)
        let third = try convert()
        run(session.backspace())
        XCTAssertEqual(host, String(third.dropLast()))
        XCTAssertFalse(session.isComposing)
    }
}
