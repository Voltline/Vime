import XCTest
import UIKit
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardCandidateStabilityTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    func testLateRankingCannotMoveDisplayedCandidatesOrInvalidateTheirTouches() throws {
        let session = KeyboardSession()
        _ = session.type("hashi")
        let displayed = session.candidateSnapshots
        XCTAssertGreaterThan(displayed.count, 2)
        let token = try XCTUnwrap(session.candidatePresentations.first?.selectionToken)
        var publications = 0
        session.onCandidatesChange = { publications += 1 }
        session.acceptCandidateUpdate(Array(displayed.reversed()), revision: session.revision, supplementary: true)
        XCTAssertEqual(session.candidates, displayed.map(\.text), "Pausing after the final sound must not move the word already under the user's finger")
        XCTAssertEqual(session.candidatePresentations.first?.selectionToken, token)
        XCTAssertEqual(publications, 0, "A late permutation has no visible change to render")
        XCTAssertEqual(session.chooseCandidate(token), [.insert(displayed[0].text)])
    }

    func testLateCorrectionsAppendWithoutDisplacingLiteralCandidates() throws {
        let session = KeyboardSession()
        _ = session.type("shitsuka")
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: isolatedLearningDirectory())
        var query = ComposingText()
        RomajiConverter.insert("shitsuka", into: &query)
        let base = engine.candidates(for: query, revision: session.revision, includeCorrections: false)
        session.acceptCandidateUpdate(base, revision: session.revision, supplementary: false)
        let token = try XCTUnwrap(session.candidatePresentations.first?.selectionToken)
        let corrected = engine.addingCorrections(to: base, for: query, katakana: false, revision: session.revision)
        XCTAssertTrue(corrected.contains { $0.text == "静か" && $0.source == .correction })
        session.acceptCandidateUpdate(corrected, revision: session.revision, supplementary: true)
        XCTAssertEqual(Array(session.candidates.prefix(base.count)), base.map(\.text))
        XCTAssertEqual(session.candidatePresentations.first?.selectionToken, token, "Appending new choices preserves the existing touch targets")
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "静か" && $0.source == .correction })
        XCTAssertEqual(session.choose(index), [.insert("静か")])
    }

    func testNewInputAllowsFreshRankingAndRejectsOldRevision() throws {
        let session = KeyboardSession()
        _ = session.type("hashi")
        let old = session.candidateSnapshots
        let oldRevision = session.revision
        let token = try XCTUnwrap(session.candidatePresentations.first?.selectionToken)
        _ = session.type("ra")
        let current = session.candidateSnapshots
        let fresh = Array(current.reversed())
        session.acceptCandidateUpdate(fresh, revision: session.revision, supplementary: false)
        XCTAssertEqual(session.candidates, fresh.map(\.text), "Stability is scoped to one input, not an unconditional lock on the previous word")
        session.acceptCandidateUpdate(old, revision: oldRevision, supplementary: true)
        XCTAssertEqual(session.candidates, fresh.map(\.text))
        XCTAssertTrue(session.chooseCandidate(token).isEmpty)
    }

    func testSupplementaryAppendPreservesScrollAndHeldCandidateButton() throws {
        let session = KeyboardSession()
        _ = session.type("hashi")
        session.acceptCandidateUpdate(Array(session.candidateSnapshots.prefix(8)), revision: session.revision, supplementary: false)
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 320, height: 350), session: session)
        keyboard.layoutIfNeeded()
        let scroll = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates" } as? UIScrollView)
        let button = try XCTUnwrap(descendants(scroll).compactMap { $0 as? UIButton }.first)
        let displayed = session.candidateSnapshots
        let first = try XCTUnwrap(displayed.first)
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
        let offset = CGPoint(x: min(30, scroll.contentSize.width - scroll.bounds.width), y: 0)
        scroll.setContentOffset(offset, animated: false)
        var committed: [KeyboardEdit] = []
        keyboard.onEdit = { committed += $0 }
        button.sendActions(for: .touchDown)
        var addition = first
        addition.displaySurface = "安定性テスト"
        session.acceptCandidateUpdate([addition] + Array(displayed.reversed()), revision: session.revision, supplementary: true)
        keyboard.layoutIfNeeded()
        XCTAssertEqual(scroll.contentOffset, offset)
        XCTAssertEqual(button.title(for: .normal), first.text)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(committed, [.insert(first.text)], "A supplement arriving between touch down and release must preserve the touched word")
    }

    func testSameSurfaceWithDifferentConsumptionRemainsASeparateChoice() throws {
        let session = KeyboardSession()
        _ = session.type("nihongo")
        let original = try XCTUnwrap(session.candidateSnapshots.first { $0.text == "日本語" && $0.fullConsumption })
        let token = try XCTUnwrap(session.candidatePresentations.first { $0.text == original.text }?.selectionToken)
        var remainder = ComposingText()
        RomajiConverter.insert("go", into: &remainder)
        let partial = CandidateSnapshot(candidate: original.candidate, revision: session.revision, source: .conversion,
            remainingComposition: remainder, originalInputCount: original.originalInputCount,
            consumedInputCount: original.consumedInputCount - remainder.input.count)
        session.acceptCandidateUpdate([partial] + Array(session.candidateSnapshots.reversed()), revision: session.revision, supplementary: true)
        XCTAssertEqual(session.candidateSnapshots.filter { $0.text == original.text }.count, 2)
        XCTAssertEqual(session.chooseCandidate(token), [.insert(original.text)])
        XCTAssertNil(session.preedit, "The original full-word button must still consume the full composition")
    }

    func testRealAsyncModelAndCorrectionUpdatesKeepFirstDisplayedOrder() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.candidateRanking = .languageModel
        session.leftContextProvider = { "川を渡る" }
        let ready = expectation(description: "first current candidate list")
        var first: [CandidateIdentity]?
        var firstToken: CandidateSelectionToken?
        var publications = 0
        session.onCandidatesChange = {
            guard session.candidatesAreCurrent, !session.candidateSnapshots.isEmpty else { return }
            publications += 1
            let identities = session.candidateSnapshots.map(CandidateIdentity.init)
            if let first {
                XCTAssertEqual(Array(identities.prefix(first.count)), first)
                XCTAssertEqual(session.candidatePresentations.first?.selectionToken, firstToken)
            } else {
                first = identities
                firstToken = session.candidatePresentations.first?.selectionToken
                ready.fulfill()
            }
        }
        for key in "hashi" { _ = session.type(String(key)) }
        await fulfillment(of: [ready], timeout: 5)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertNotNil(first)
        XCTAssertGreaterThanOrEqual(publications, 1)
        session.reset()
    }

    func testColdModelCannotDelayInitialDictionaryPublicationOrPublishTwice() async throws {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        worker.disableLanguageModel()
        let unloaded = await worker.resourceState()
        XCTAssertFalse(unloaded.modelLoaded)
        worker.allowLanguageModel()
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        var query = ComposingText()
        RomajiConverter.insert("hashi", into: &query)
        let ready = expectation(description: "dictionary fallback during cold model load")
        var initialCount = 0
        worker.candidates(for: query, katakana: false, revision: 1, leftContext: "川を渡る", continuity: nil) { values, readyAt, supplementary in
            guard !supplementary else { return }
            initialCount += 1
            XCTAssertFalse(values.isEmpty)
            if let readyAt {
                let delay = (ProcessInfo.processInfo.systemUptime - readyAt) * 1000
                print("CANDIDATE_INITIAL_COLD_WINDOW_MS \(delay)")
                XCTAssertLessThan(delay, 150, "Cold model loading must not hold the first dictionary result")
            } else { XCTFail("Expected instrumented result timestamp") }
            if initialCount == 1 { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        _ = await worker.resourceState()
        XCTAssertEqual(initialCount, 1)
        worker.reset()
    }

    func testWarmModelStillRanksBeforeFirstDisplay() async throws {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        worker.allowLanguageModel()
        var warmup = ComposingText()
        RomajiConverter.insert("hashi", into: &warmup)
        worker.candidates(for: warmup, katakana: false, revision: 0, leftContext: "川を渡る", continuity: nil) { _, _, _ in }
        _ = await worker.resourceState()
        let model = try VimeLanguageModel()
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: isolatedLearningDirectory())
        var verified = 0
        for (raw, context) in [("hashi", "ご飯を食べるための"), ("kisha", "新聞の"), ("ame", "お菓子の"), ("kouen", "研究者の")] {
            var query = ComposingText()
            RomajiConverter.insert(raw, into: &query)
            engine.reset(); engine.reconcileContext(context)
            let base = engine.candidates(for: query, revision: 2, includeCorrections: false)
            let started = ProcessInfo.processInfo.systemUptime
            var completedOrders: [[String]] = []
            let ranked = model.rerank(base, context: context, katakana: false,
                maximumCandidates: JapaneseCandidateWorker.initialRankingCandidateLimit,
                onRefinement: { completedOrders.append($0.map(\.text)) }, cancelled: { false })
            print("CANDIDATE_WARM_REFERENCE \(raw) ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000) slots=\(min(JapaneseCandidateWorker.initialRankingCandidateLimit, VimeLanguageModel.rerankingSlots(base, katakana: false).count)) base=\(base.prefix(3).map(\.text)) ranked=\(ranked.prefix(3).map(\.text))")
            let refinedSlots = Set(CandidateCompetitionPolicy.plan(base, katakana: false,
                maximumCandidates: JapaneseCandidateWorker.initialRankingCandidateLimit).slots)
            for index in base.indices where !refinedSlots.contains(index) {
                XCTAssertEqual(ranked[index].presentation, base[index].presentation, "Neural refinement must preserve unselected slots")
            }
            guard ranked.map(\.presentation) != base.map(\.presentation) else { continue }
            worker.reset()
            _ = await worker.resourceState()
            let ready = expectation(description: "warm neural order is the first displayed order")
            worker.candidates(for: query, katakana: false, revision: 2, leftContext: context, continuity: nil) { values, _, supplementary in
                guard !supplementary else { return }
                XCTAssertTrue(completedOrders.contains(values.map(\.text)), "First display must use a completed comparison within the time budget")
                ready.fulfill()
            }
            await fulfillment(of: [ready], timeout: 5)
            verified += 1
        }
        XCTAssertGreaterThan(verified, 0, "The corpus must exercise at least one actual model reorder")
        worker.reset()
    }

    func testColdSentenceInitialPublishesDictionaryOnceAndWarmsFollowingInput() async throws {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        worker.disableLanguageModel()
        _ = await worker.resourceState()
        worker.allowLanguageModel()
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: isolatedLearningDirectory())
        engine.reconcileContext("前の文。")
        var query = ComposingText()
        RomajiConverter.insert("hashi", into: &query)
        let base = engine.candidates(for: query, revision: 1, includeCorrections: false)
        let ready = expectation(description: "first publication without preceding sentence context")
        var publications = 0
        worker.candidates(for: query, katakana: false, revision: 1, leftContext: "前の文。", continuity: nil) { values, _, supplementary in
            guard !supplementary else { return }
            XCTAssertFalse(values.isEmpty)
            XCTAssertEqual(values.map(\.presentation), base.map(\.presentation))
            publications += 1
            if publications == 1 { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 5)
        let resources = await worker.resourceState()
        XCTAssertTrue(resources.modelLoaded, "Cold sentence-initial work warms later input without delaying this first list")
        XCTAssertEqual(publications, 1, "Cold scoring must not publish a second initial order")
        worker.reset()
    }
}
