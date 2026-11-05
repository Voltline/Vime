import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardPersonalRecallTests: XCTestCase {
    private let reading = "ホシネコ"
    private let surface = "星猫連絡室"

    private func directory() throws -> URL {
        let url = isolatedLearningDirectory()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func query(_ raw: String = "hoshineko") -> ComposingText {
        var value = ComposingText(); RomajiConverter.insert(raw, into: &value)
        return value
    }
    private func seed(_ directory: URL, times: Int = 3, context: String = "") {
        let memory = CandidatePreferenceMemory(directory: directory)
        for _ in 0..<times { memory.record(reading: reading, surface: surface, context: context, scope: "choice") }
        memory.flush()
    }
    private func rows(_ directory: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("VimeSelectionFrequency.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Array(try XCTUnwrap(object["entries"] as? [String: [String: Any]]).values)
    }

    func testConfirmedNativeSelectionIsRecalledAfterNativeHistoryAndDictionaryRemoval() throws {
        let root = try directory(), memoryURL = root.appendingPathComponent("memory")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let dictionary = JapaneseUserDictionaryStore(directory: root, defaults: defaults)
        try dictionary.save([.init(reading: reading, surface: surface)])
        let input = query()
        do {
            let engine = JapaneseCandidateEngine(memoryDirectoryURL: memoryURL, learningEnabled: true, userDictionary: dictionary)
            let values = engine.candidates(for: input, revision: 1, includeCorrections: false)
            let index = try XCTUnwrap(values.firstIndex { $0.text == surface && $0.fullConsumption })
            XCTAssertTrue(values[index].learningEligible)
            XCTAssertEqual(values[index].source, .userDictionary)
            let event = CandidateLearningFeedback(id: UUID(), kind: .explicitCandidate, rank: index, context: "", selectedAt: Date())
            engine.stageSelection(values[index], event: event)
            engine.resolveFeedback(event.id, accepted: true)
        }
        try dictionary.save([])
        for url in try FileManager.default.contentsOfDirectory(at: memoryURL, includingPropertiesForKeys: nil)
            where url.lastPathComponent != "VimeSelectionFrequency.json" {
            try FileManager.default.removeItem(at: url)
        }
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: memoryURL, learningEnabled: true, userDictionary: dictionary)
        let trace = CandidatePipelineTrace(revision: 2, references: [surface], consumedInputCount: input.input.count)
        let values = engine.candidates(for: input, revision: 2, includeCorrections: false, trace: trace)
        let recalled = try XCTUnwrap(values.first { $0.text == surface })
        XCTAssertNil(trace.snapshot()[.native]?.referenceRank)
        XCTAssertNotNil(trace.snapshot()[.pooled]?.referenceRank)
        XCTAssertEqual(recalled.source, .rememberedConversion)
        XCTAssertTrue(recalled.exactReading && recalled.fullConsumption && recalled.lexical)
        XCTAssertEqual(recalled.consumedInputCount, input.input.count)
        XCTAssertTrue(recalled.candidate.data.isEmpty)
        XCTAssertFalse(recalled.learningEligible)
        XCTAssertGreaterThan(recalled.userPreferenceScore, 0)
        XCTAssertEqual(recalled.presentation.annotation, "个人记忆")
        XCTAssertTrue(VimeLanguageModel.rerankingSlots(values, katakana: false).contains(try XCTUnwrap(values.firstIndex { $0.text == surface })))
    }

    func testNativeCandidateKeepsSegmentationWhenMemoryAlsoRecallsIt() throws {
        let url = try directory(), memory = CandidatePreferenceMemory(directory: url)
        for _ in 0..<3 { memory.record(reading: "ハシ", surface: "箸", scope: "choice") }
        memory.flush()
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: url, learningEnabled: true)
        let values = engine.candidates(for: query("hashi"), revision: 1, includeCorrections: false)
        let value = try XCTUnwrap(values.first { $0.text == "箸" && $0.fullConsumption })
        XCTAssertNotEqual(value.source, .rememberedConversion)
        XCTAssertTrue(value.learningEligible)
        XCTAssertFalse(value.candidate.data.isEmpty)
        XCTAssertEqual(values.filter { $0.text == "箸" && $0.fullConsumption }.count, 1)
    }

    func testKeyboardCommitsRecalledTextAndLearnsOnlyAfterHostReceipt() throws {
        let url = try directory(); seed(url)
        let session = KeyboardSession(memoryDirectoryURL: url)
        var before = "昨日"
        session.leftContextProvider = { before }
        session.learningContextProvider = { KeyboardLearningContext(document: "field", before: before, after: "") }
        _ = session.type("hoshineko")
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == surface })
        XCTAssertEqual(session.candidateSnapshots[index].source, .rememberedConversion)
        let edits = session.choose(index)
        XCTAssertEqual(edits, [.insert(surface)])
        session.didApplyEdits(edits)
        func confirmations() throws -> Int? {
            try rows(url).first { $0["scope"] as? String == "choice" && $0["context"] as? String == "" }?["confirmations"] as? Int
        }
        XCTAssertEqual(try confirmations(), 3)
        before += surface
        session.didApplyEdits(); session.finishLearningFeedback()
        XCTAssertEqual(try confirmations(), 4)
        XCTAssertFalse(session.isComposing)
        session.reset(); before = "別の文脈"
        _ = session.type("hoshineko")
        XCTAssertEqual(session.candidates.first, surface)
    }

    func testForgettingACandidateSurvivesAnInstanceThatLoadedItEarlier() throws {
        let url = try directory(); seed(url)
        let stale = CandidatePreferenceMemory(directory: url)
        let memory = CandidatePreferenceMemory(directory: url)
        memory.record(reading: "ハシ", surface: "箸", scope: "choice")
        memory.forget([(reading, surface)])
        XCTAssertEqual(memory.score(reading: reading, surface: surface, scope: "choice"), 0)
        stale.record(reading: "ハシ", surface: "橋", scope: "choice"); stale.flush()
        XCTAssertEqual(Set(try rows(url).compactMap { $0["surface"] as? String }), ["箸", "橋"])
    }

    func testLongPressForgetsARecalledCandidateOnlyAfterConfirmation() throws {
        let url = try directory(); seed(url)
        let session = KeyboardSession(memoryDirectoryURL: url)
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        defer { keyboard.stopInteractions() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        _ = session.type("hoshineko"); keyboard.refresh(); keyboard.layoutIfNeeded()
        let button = try XCTUnwrap(views(keyboard).compactMap { $0 as? KeyboardCandidateButton }
            .first { $0.accessibilityLabel?.contains(surface) == true })
        let token = try XCTUnwrap(button.selectionToken)
        keyboard.promptForget(button); keyboard.layoutIfNeeded()
        let prompt = try XCTUnwrap(keyboard.forgetPrompt)
        XCTAssertFalse(prompt.isHidden)
        // The bubble hangs under the candidate, and the keys behind it cannot type.
        let bubble = prompt.confirm.convert(prompt.confirm.bounds, to: keyboard)
        XCTAssertGreaterThan(bubble.minY, button.convert(button.bounds, to: keyboard).maxY)
        XCTAssertTrue(keyboard.hitTest(CGPoint(x: bubble.midX, y: bubble.midY), with: nil) === prompt.confirm)
        XCTAssertTrue(keyboard.hitTest(CGPoint(x: 20, y: 330), with: nil) === prompt)
        prompt.sendActions(for: .touchDown)
        XCTAssertTrue(prompt.isHidden)
        XCTAssertTrue(try rows(url).contains { $0["surface"] as? String == surface })
        keyboard.promptForget(button)
        prompt.confirm.sendActions(for: .touchUpInside)
        XCTAssertTrue(prompt.isHidden)
        XCTAssertFalse(try rows(url).contains { $0["surface"] as? String == surface })
        XCTAssertFalse(session.candidates.contains(surface))
        XCTAssertTrue(session.isComposing, "Forgetting keeps the reading being typed")
        XCTAssertNil(session.forgettableCandidate(token), "A stale list cannot be forgotten from")
    }

    func testLongPressOffersNothingForCandidatesNoChoiceTaught() throws {
        let session = KeyboardSession(memoryDirectoryURL: try directory())
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        defer { keyboard.stopInteractions() }
        func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
        _ = session.type("hashi"); keyboard.refresh(); keyboard.layoutIfNeeded()
        let tokens = views(keyboard).compactMap { ($0 as? KeyboardCandidateButton)?.selectionToken }
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.allSatisfy { session.forgettableCandidate($0) == nil })
        keyboard.promptForget(try XCTUnwrap(views(keyboard).compactMap { $0 as? KeyboardCandidateButton }.first))
        XCTAssertNil(keyboard.forgetPrompt)
    }

    func testScopedRecallConsumesOnlyRequestedPrefixAndPreservesRemainder() throws {
        let url = try directory(); seed(url)
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: url, learningEnabled: true)
        let input = query("hoshinekoheiku")
        XCTAssertFalse(engine.candidates(for: input, revision: 1, includeCorrections: false).contains { $0.source == .rememberedConversion })
        let values = engine.candidates(for: input, revision: 2, includeCorrections: false, conversionLength: reading.count)
        let value = try XCTUnwrap(values.first { $0.text == surface })
        XCTAssertTrue(value.explicitScope && value.scopeFullConsumption && value.exactReading)
        XCTAssertFalse(value.fullConsumption)
        XCTAssertEqual(value.reading, reading)
        XCTAssertEqual(value.remainingComposition.convertTarget, "へいく")
        XCTAssertEqual(value.consumedInputCount, query().input.count)
        XCTAssertEqual(value.originalInputCount, input.input.count)
        engine.complete(value)
        let remaining = engine.candidates(for: value.remainingComposition, revision: 3, includeCorrections: false)
        XCTAssertTrue(remaining.contains { $0.text == "へ行く" && $0.fullConsumption })
        XCTAssertFalse(engine.candidates(for: query("hoshinekok"), revision: 4, includeCorrections: false).contains { $0.source == .rememberedConversion })
    }

    func testRecalledSelectionsRequireAcceptedFeedbackAndSurviveRestartAndContextChange() throws {
        let url = try directory(); seed(url, times: 1)
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: url, learningEnabled: true)
        let before = try rows(url)
        let selected = try XCTUnwrap(engine.candidates(for: query(), revision: 1, includeCorrections: false).first { $0.text == surface })
        let rejected = CandidateLearningFeedback(id: UUID(), kind: .explicitCandidate, rank: 1, context: "昨日", selectedAt: Date())
        engine.stageSelection(selected, event: rejected)
        engine.resolveFeedback(rejected.id, accepted: false); engine.flushLearning(); engine.reset()
        XCTAssertEqual(try rows(url).first?["confirmations"] as? Int, before.first?["confirmations"] as? Int)
        for context in ["昨日", "今日は", "それから", "新しい文章"] {
            engine.reconcileContext(context)
            let values = engine.candidates(for: query(), revision: 2, includeCorrections: false)
            let index = try XCTUnwrap(values.firstIndex { $0.text == surface })
            let event = CandidateLearningFeedback(id: UUID(), kind: .explicitCandidate, rank: index, context: context, selectedAt: Date())
            engine.stageSelection(values[index], event: event)
            engine.resolveFeedback(event.id, accepted: true); engine.reset()
        }
        let restored = JapaneseCandidateEngine(memoryDirectoryURL: url, learningEnabled: true)
        restored.reconcileContext("別の話題")
        let values = restored.candidates(for: query(), revision: 3, includeCorrections: false)
        XCTAssertEqual(values.first?.text, surface)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(values.first).userPreferenceConfidence, 0.65)
        restored.clearLearning()
        XCTAssertFalse(restored.candidates(for: query(), revision: 4, includeCorrections: false).contains { $0.text == surface })
        seed(url)
        let disabled = JapaneseCandidateEngine(memoryDirectoryURL: url, learningEnabled: false)
        XCTAssertFalse(disabled.candidates(for: query(), revision: 5, includeCorrections: false).contains { $0.text == surface })
    }

    func testRecallAdmissionExcludesProvisionalPassiveAndExpiredEvidence() throws {
        let url = try directory(), memory = CandidatePreferenceMemory(directory: url), now = Date()
        let id = UUID()
        memory.stage(id: id, reading: reading, surface: surface, context: "", weight: 1, now: now)
        XCTAssertTrue(memory.rememberedConversions(reading: reading, context: "", now: now).isEmpty)
        memory.cancel(id)
        memory.record(reading: reading, surface: surface, weight: 0.35, now: now)
        XCTAssertTrue(memory.rememberedConversions(reading: reading, context: "", now: now).isEmpty)
        memory.record(reading: reading, surface: surface, scope: "choice", weight: 0.7, now: now)
        XCTAssertEqual(memory.rememberedConversions(reading: reading, context: "", now: now), [surface])
        XCTAssertTrue(memory.rememberedConversions(reading: reading, context: "", now: now.addingTimeInterval(CandidatePreferenceMemory.Policy.halfLife * 2)).isEmpty)
        XCTAssertTrue(memory.rememberedConversions(reading: reading + "k", context: "", now: now).isEmpty)
        XCTAssertTrue(memory.rememberedConversions(reading: "", context: "", now: now).isEmpty)
    }
    func testRecallLimitUsesContextPreferenceAndSharedWordEvidence() throws {
        let url = try directory(), memory = CandidatePreferenceMemory(directory: url), now = Date()
        for index in 0..<8 {
            memory.record(reading: reading, surface: "表記\(index)", scope: "choice", now: now)
        }
        for _ in 0..<3 { memory.record(reading: reading, surface: surface, context: "昨日の", scope: "choice", now: now.addingTimeInterval(1)) }
        let recalled = memory.rememberedConversions(reading: reading, context: "昨日の", now: now.addingTimeInterval(1))
        XCTAssertEqual(recalled.count, CandidatePreferenceMemory.Policy.maximumRememberedSuggestions)
        XCTAssertEqual(recalled.first, surface)
        for _ in 0..<2 { memory.record(reading: "ホシ", surface: "星", scope: "wordChoice", now: now) }
        XCTAssertEqual(memory.rememberedConversions(reading: "ホシ", context: "", now: now), ["星"])
        memory.flush()
        XCTAssertEqual(CandidatePreferenceMemory(directory: url).rememberedConversions(reading: reading, context: "昨日の", now: now.addingTimeInterval(1)), recalled)
    }

    func testContextFloodCannotEvictGlobalRecallAndTiersBorrowFreeCapacity() throws {
        let url = try directory(), memory = CandidatePreferenceMemory(directory: url), now = Date()
        for _ in 0..<3 { memory.record(reading: reading, surface: surface, scope: "choice", now: now) }
        for index in 0..<1_200 { memory.recordNextWord("続き\(index)", context: "話題\(index)", now: now.addingTimeInterval(1)) }
        memory.flush()
        let stored = try rows(url)
        XCTAssertEqual(stored.count, CandidatePreferenceMemory.Policy.maximumEntries)
        XCTAssertEqual(stored.filter { $0["context"] as? String == "" }.count, 1)
        XCTAssertEqual(memory.rememberedConversions(reading: reading, context: "別の文脈", now: now), [surface])
        XCTAssertEqual(CandidatePreferenceMemory(directory: url).rememberedConversions(reading: reading, context: "別の文脈", now: now), [surface])
    }

    func testMixedTiersReserveGlobalCapacityAndGlobalFloodPreservesFrequentAndRecentChoices() throws {
        let url = try directory(), memory = CandidatePreferenceMemory(directory: url), now = Date()
        for _ in 0..<10 { memory.record(reading: reading, surface: surface, scope: "choice", now: now) }
        for index in 0..<2_200 { memory.record(reading: "テスト", surface: "表記\(index)", scope: "choice", now: now.addingTimeInterval(Double(index + 1))) }
        memory.flush()
        XCTAssertEqual(memory.rememberedConversions(reading: reading, context: "", now: now), [surface])
        XCTAssertEqual(memory.rememberedConversions(reading: "テスト", context: "", now: now).first, "表記2199")
        XCTAssertFalse(try rows(url).contains { $0["surface"] as? String == "表記0" })
        for index in 0..<1_200 { memory.recordNextWord("続き\(index)", context: "話題\(index)", now: now.addingTimeInterval(3_000)) }
        memory.flush()
        let stored = try rows(url)
        XCTAssertEqual(stored.count, CandidatePreferenceMemory.Policy.maximumEntries)
        XCTAssertEqual(stored.filter { $0["context"] as? String == "" }.count, CandidatePreferenceMemory.Policy.reservedGlobalEntries)
        XCTAssertEqual(memory.rememberedConversions(reading: reading, context: "", now: now), [surface])
        XCTAssertTrue(stored.contains { $0["surface"] as? String == "表記2199" })
    }

    func testFullReadingPopulationRecallStaysWithinInteractiveBudget() throws {
        try skipTimingSensitiveTestOnCI()
        let url = try directory(), now = Date()
        let initial = Dictionary(uniqueKeysWithValues: (0..<CandidatePreferenceMemory.Policy.maximumEntries).map { index in
            let text = "記憶\(index)"
            return ("choice\0" + reading + "\0\0" + text,
                ["scope": "choice", "reading": reading, "context": "", "surface": text,
                 "evidence": 3.0, "confirmations": 3, "selectedAt": now.timeIntervalSince1970 - Double(2048 - index)] as [String: Any])
        })
        try JSONSerialization.data(withJSONObject: ["version": 2, "entries": initial])
            .write(to: url.appendingPathComponent("VimeSelectionFrequency.json"))
        let memory = CandidatePreferenceMemory(directory: url)
        var durations: [Double] = []
        for _ in 0..<20 {
            let started = ProcessInfo.processInfo.systemUptime
            let values = memory.rememberedConversions(reading: reading, context: "別の文脈", now: now)
            durations.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            XCTAssertEqual(values, ["記憶2047", "記憶2046", "記憶2045"])
        }
        durations.sort()
        print("PERSONAL_RECALL_FULL_POPULATION count=2048 p50Ms=\(durations[10]) p95Ms=\(durations[18])")
        // This catches repeated whole-population scans per recalled surface.
        XCTAssertLessThan(durations[18], 50)
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: url, learningEnabled: true)
        engine.reconcileContext("別の文脈")
        let input = query()
        _ = engine.candidates(for: input, revision: 1, includeCorrections: false)
        durations = []
        for revision in 2...21 {
            let started = ProcessInfo.processInfo.systemUptime
            let values = engine.candidates(for: input, revision: revision, includeCorrections: false)
            durations.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            XCTAssertEqual(values.filter { $0.source == .rememberedConversion }.count, 3)
        }
        durations.sort()
        print("PERSONAL_RECALL_FULL_ENGINE count=2048 p50Ms=\(durations[10]) p95Ms=\(durations[18])")
        XCTAssertLessThan(durations[18], 100)
    }
}
