import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardPersonalizationTests: XCTestCase {
    func testFrequencyPersistenceDecayAndContextIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = CandidatePreferenceMemory(directory: directory)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        memory.record(reading: "ハシ", surface: "橋", now: date)
        XCTAssertEqual(memory.score(reading: "ハシ", surface: "橋", now: date), 0, "One exceptional choice does not bias ranking")
        for _ in 0..<10 {
            memory.record(reading: "ハシ", surface: "橋", now: date)
            memory.recordNextWord("テスト", context: "プログラムを", now: date)
        }
        memory.flush()
        let restored = CandidatePreferenceMemory(directory: directory)
        let score = restored.score(reading: "ハシ", surface: "橋", now: date)
        XCTAssertGreaterThan(score, 2)
        XCTAssertLessThanOrEqual(score, CandidatePreferenceMemory.Policy.maximumBonus)
        let aged = date.addingTimeInterval(CandidatePreferenceMemory.Policy.halfLife)
        XCTAssertEqual(restored.score(reading: "ハシ", surface: "橋", now: aged), log(5.5), accuracy: 0.001)
        XCTAssertLessThan(restored.score(reading: "ハシ", surface: "橋", now: aged), score)
        let words = [ScoredNextWord(text: "書く", logProbabilitySum: -1, tokenCount: 1),
            ScoredNextWord(text: "読む", logProbabilitySum: -1.2, tokenCount: 1)]
        let remembered = ScoredNextWord(text: "テスト", logProbabilitySum: -1.4, tokenCount: 1)
        XCTAssertEqual(restored.nextWords(words + [remembered], history: [], context: "プログラムを", now: date).first?.text, "テスト")
        XCTAssertEqual(restored.nextWords(words, history: [remembered], context: "プログラムを", now: date).first?.source, .userHistory)
        XCTAssertFalse(restored.rememberedNextWords(context: "昨日", now: date).contains("テスト"))
        restored.clear()
        XCTAssertEqual(CandidatePreferenceMemory(directory: directory).score(reading: "ハシ", surface: "橋", now: date), 0)
    }

    func testLearningSurvivesNeuralRerankingAndConverterRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lm = try VimeLanguageModel()
        var query = ComposingText(); RomajiConverter.insert("hashi", into: &query)
        var engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        let initial = lm.rerank(engine.candidates(for: query, revision: 1, includeCorrections: false), context: "", katakana: false, cancelled: { false })
        let eligible = initial.enumerated().filter { $0.element.learningEligible && $0.element.fullConsumption && $0.element.exactReading && $0.element.source == .conversion }
        let choice = try XCTUnwrap(eligible.dropFirst().first)
        for i in 0..<16 {
            let candidate = try XCTUnwrap(engine.candidates(for: query, revision: i + 2, includeCorrections: false).first { $0.text == choice.element.text })
            let event = CandidateLearningFeedback(id: UUID(), kind: .explicitCandidate, rank: choice.offset, context: "", selectedAt: Date())
            engine.stageSelection(candidate, event: event)
            engine.resolveFeedback(event.id, accepted: true); engine.reset()
        }
        engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        let final = lm.rerank(engine.candidates(for: query, revision: 30, includeCorrections: false), context: "", katakana: false, cancelled: { false })
        let target = try XCTUnwrap(final.first { $0.text == choice.element.text })
        XCTAssertGreaterThan(target.userPreferenceScore, 2)
        let rank = try XCTUnwrap(final.firstIndex { $0.text == target.text })
        print("PERSONALIZED_RANK \(target.text) \(choice.offset) -> \(rank) userScore=\(target.userPreferenceScore)")
        XCTAssertLessThan(rank, choice.offset)
        engine.clearLearning()
        XCTAssertEqual(engine.candidates(for: query, revision: 31, includeCorrections: false).first { $0.text == target.text }?.userPreferenceScore, 0)
    }

    func testDecayedEvidenceContextShrinkageMigrationAndProvisionalCancellation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy: [String: Any] = ["version": 1, "entries": ["legacy": ["scope": "conversion", "context": "ハシ", "surface": "橋", "count": 100,
            "selectedAt": now.addingTimeInterval(-CandidatePreferenceMemory.Policy.halfLife * 10).timeIntervalSince1970]]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appendingPathComponent("VimeSelectionFrequency.json"))
        let memory = CandidatePreferenceMemory(directory: directory)
        memory.record(reading: "ハシ", surface: "橋", now: now)
        XCTAssertLessThan(memory.score(reading: "ハシ", surface: "橋", now: now), 0.1, "A new selection must not revive 100 old choices")
        for _ in 0..<4 {
            memory.record(reading: "ハシ", surface: "橋", context: "川を渡る", now: now)
            memory.record(reading: "ハシ", surface: "箸", context: "ご飯を食べる", now: now)
        }
        XCTAssertGreaterThan(memory.score(reading: "ハシ", surface: "箸", context: "ご飯を食べる", now: now),
            memory.score(reading: "ハシ", surface: "箸", context: "川を渡る", now: now))
        let id = UUID()
        memory.stage(id: id, reading: "ハシ", surface: "端", context: "川を渡る", weight: 1, now: now)
        XCTAssertGreaterThan(memory.score(reading: "ハシ", surface: "端", context: "川を渡る", now: now), 0)
        memory.cancel(id)
        XCTAssertEqual(memory.score(reading: "ハシ", surface: "端", context: "川を渡る", now: now), 0)
        memory.flush()
        let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("VimeSelectionFrequency.json"))) as? [String: Any])
        XCTAssertEqual(archive["version"] as? Int, 2)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: archive), as: UTF8.self).contains("ご飯を食べる"))
    }

    func testHostReceiptRejectsDeletionFieldChangesAndMissingAcknowledgement() throws {
        for scenario in ["deleted", "partial", "field", "noReceipt", "retained"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = KeyboardSession(memoryDirectoryURL: directory)
            var before = "昨日"; var document = "fieldA"
            let input = scenario == "partial" ? "toukyou" : "hashi"
            session.leftContextProvider = { before }
            session.learningContextProvider = { KeyboardLearningContext(document: document, before: before, after: "") }
            var selected: CandidateSnapshot?
            for _ in 0..<2 {
                before = "昨日"; document = "fieldA"; session.reset()
                _ = session.type(input)
                let index: Int
                if let selected { index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == selected.text }) }
                else { index = try XCTUnwrap(session.candidateSnapshots.indices.dropFirst().first {
                    let candidate = session.candidateSnapshots[$0]
                    return candidate.learningEligible && candidate.fullConsumption && (scenario != "partial" || candidate.text.count > 1)
                }) }
                selected = session.candidateSnapshots[index]
                let edits = session.choose(index)
                before += try XCTUnwrap(selected).text
                if scenario != "noReceipt" { session.didApplyEdits(edits) }
                if scenario == "deleted" || scenario == "partial" {
                    let count = scenario == "deleted" ? try XCTUnwrap(selected).text.count : 1
                    for _ in 0..<count { _ = session.backspace(); before.removeLast(); session.didApplyEdits() }
                }
                if scenario == "field" { document = "fieldB" }
                session.finishLearningFeedback()
            }
            let choice = try XCTUnwrap(selected)
            let memory = CandidatePreferenceMemory(directory: directory)
            let score = memory.score(reading: choice.reading, surface: choice.text, context: "昨日")
            if scenario == "retained" { XCTAssertGreaterThan(score, 0) }
            else { XCTAssertEqual(score, 0, scenario) }
            let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
            var query = ComposingText(); RomajiConverter.insert(input, into: &query)
            let evidence = engine.candidates(for: query, revision: 1, includeCorrections: false).contains { $0.text == choice.text && $0.hasLearningEvidence }
            XCTAssertEqual(evidence, scenario == "retained", scenario)
        }
    }

    func testRetentionTimerAcceptsVerifiedHostText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = KeyboardSession(memoryDirectoryURL: directory)
        var before = ""
        session.leftContextProvider = { before }
        session.learningContextProvider = { KeyboardLearningContext(document: "field", before: before, after: "") }
        _ = session.type("hashi")
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.learningEligible && $0.fullConsumption })
        let edits = session.choose(index)
        for edit in edits { if case let .insert(text) = edit { before += text } }
        session.didApplyEdits(edits)
        try await Task.sleep(for: .seconds(CandidateLearningFeedback.Policy.retentionSeconds + 0.2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("VimeSelectionFrequency.json").path))
    }

    func testScoredHistoryUsesModelEvidenceAndBoundedPersonalization() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = CandidatePreferenceMemory(directory: directory)
        for _ in 0..<20 { memory.recordNextWord("テスト", context: "プログラムを") }
        let generated = [ScoredNextWord(text: "書く", logProbabilitySum: -1, tokenCount: 1)]
        XCTAssertEqual(memory.nextWords(generated, history: [.init(text: "テスト", logProbabilitySum: -8, tokenCount: 2)], context: "プログラムを").map(\.text), ["書く"])
        let admitted = memory.nextWords(generated, history: [.init(text: "テスト", logProbabilitySum: -2, tokenCount: 2)], context: "プログラムを")
        XCTAssertEqual(admitted.first?.text, "テスト")
        XCTAssertEqual(admitted.first?.modelScore, -2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(admitted.first?.userScore), CandidatePreferenceMemory.Policy.maximumBonus)
        let lm = try VimeLanguageModel()
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        for prompt in ["プログラムを", "明日の会議までに", "朝起きたら、コーヒーを"] {
            let scored = try lm.scoredNextWords(prompt: prompt, history: ["テスト"])
            let all = scored.generated + scored.history
            XCTAssertFalse(scored.generated.isEmpty)
            XCTAssertFalse(memory.nextWords(scored.generated, history: scored.history, context: prompt).isEmpty)
            print("NEXT_WORD_SCORE_CACHE", prompt, "reused", lm.nextWordScoreReuses, "fresh", lm.nextWordScoringPasses)
            let reference = try lm.scores(context: prompt, candidates: all.map(\.text))
            for (word, expected) in zip(all, reference) {
                XCTAssertEqual(word.logProbabilitySum, expected, accuracy: 0.0001)
                XCTAssertGreaterThan(word.tokenCount, 0)
            }
        }
        print("PERSONALIZATION_TIMING", KeyboardPerformance.report())
        XCTAssertThrowsError(try lm.scoredNextWords(prompt: "プログラムを", cancelled: { true }))
    }
}
