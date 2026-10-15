import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardAdaptiveRankingTests: XCTestCase {
    private func pool(_ scores: [Double], surfaces: [String] = ["橋", "箸", "端", "梯", "嘴", "波止"]) -> [CandidateSnapshot] {
        zip(surfaces, scores).enumerated().map { rank, pair in
            let native = Candidate(text: pair.0, value: -10, composingCount: .inputCount(2), lastMid: MIDData.一般.mid,
                data: [.init(word: pair.0, ruby: "ハシ", cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)])
            var value = CandidateSnapshot(candidate: native, revision: 1, source: .conversion,
                remainingComposition: ComposingText(), originalInputCount: 2, consumedInputCount: 2,
                queryReading: "ハシ", engineRank: rank)
            value.features.engine = pair.1
            return value
        }
    }

    func testCompetitionWidensOnlyForPlausibleContenders() {
        let close = pool([10, 9.8, 9.6, 9.4, 9.2, 9])
        XCTAssertEqual(CandidateCompetitionPolicy.plan(close, katakana: false).slots.count, 6)
        XCTAssertTrue(CandidateCompetitionPolicy.plan(pool([10, 5]), katakana: false).slots.isEmpty)
        XCTAssertEqual(CandidateCompetitionPolicy.plan(pool([10, 7, 6, 5]), katakana: false).slots.count, 2)
        XCTAssertTrue(CandidateCompetitionPolicy.plan(close, katakana: true).slots.isEmpty)
        XCTAssertTrue(CandidateCompetitionPolicy.plan(close, katakana: false, maximumCandidates: 1).slots.isEmpty)
    }

    func testModelAdjustmentPreservesEvidenceAndStrongPersonalChoice() {
        let strongDictionary = pool([10, 8.5])
        XCTAssertEqual(CandidateCompetitionPolicy.applying([-100, 0], slots: [0, 1], limit: 1,
            to: strongDictionary).first?.text, "橋")
        var close = pool([10, 9.8])
        XCTAssertEqual(CandidateCompetitionPolicy.applying([-100, 0], slots: [0, 1], limit: 4,
            to: close).first?.text, "箸")
        close[0].userPreferenceConfidence = 1
        XCTAssertEqual(CandidateCompetitionPolicy.applying([-100, 0], slots: [0, 1], limit: 4,
            to: close).first?.text, "橋")
    }

    func testCompletedCoreSurvivesCancellationDuringExpansion() throws {
        let model = try VimeLanguageModel()
        let values = pool([0, 0, 0], surfaces: ["買う", "飲む", "飲みたい"])
        var stopped = false
        var completed: [CandidateSnapshot]?
        let result = model.rerank(values, context: "コーヒーを", katakana: false, onRefinement: {
            completed = $0
            stopped = true
        }, cancelled: { stopped })
        XCTAssertEqual(try XCTUnwrap(completed).map(\.text), result.map(\.text))
        XCTAssertEqual(result.first?.text, "飲む")
        XCTAssertEqual(result[2].presentation, values[2].presentation)
    }

    func testActiveCorrectionsLearnWithinTwoSelectionsAndSurviveRestart() throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        var query = ComposingText(); RomajiConverter.insert("hashi", into: &query)
        let context = "川を渡るための"
        engine.reconcileContext(context)
        let initial = engine.candidates(for: query, revision: 1, includeCorrections: false)
        let choice = try XCTUnwrap(initial.enumerated().filter {
            $0.element.learningEligible && $0.element.fullConsumption && $0.element.exactReading && $0.element.source == .conversion
        }.dropFirst().first)
        for revision in 2...3 {
            engine.reset(); engine.reconcileContext(context)
            let current = engine.candidates(for: query, revision: revision, includeCorrections: false)
            let index = try XCTUnwrap(current.firstIndex { $0.text == choice.element.text })
            let id = UUID()
            engine.stageSelection(current[index], event: CandidateLearningFeedback(id: id, kind: .explicitCandidate,
                rank: index, context: context, selectedAt: Date()))
            engine.resolveFeedback(id, accepted: true)
            engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
            engine.reconcileContext(context)
            let ranked = engine.candidates(for: query, revision: revision + 10, includeCorrections: false)
            let learned = try XCTUnwrap(ranked.first { $0.text == choice.element.text })
            XCTAssertGreaterThan(learned.userPreferenceScore, 0)
            if revision == 2 { XCTAssertLessThan(try XCTUnwrap(ranked.firstIndex { $0.text == learned.text }), choice.offset) }
            if revision == 3 {
                XCTAssertEqual(ranked.first?.text, learned.text)
                XCTAssertGreaterThanOrEqual(learned.userPreferenceConfidence, 0.65)
                let neural = try VimeLanguageModel().rerank(ranked, context: context, katakana: false, cancelled: { false })
                XCTAssertEqual(neural.first?.text, learned.text)
            }
        }
    }

    func testPassiveConfirmationAndRejectedChoiceDoNotCreateStrongPreferences() throws {
        for accepted in [false, true] {
            let directory = isolatedLearningDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
            var query = ComposingText(); RomajiConverter.insert("hashi", into: &query)
            let value = try XCTUnwrap(engine.candidates(for: query, revision: 1, includeCorrections: false).first { $0.learningEligible })
            let id = UUID()
            engine.stageSelection(value, event: CandidateLearningFeedback(id: id,
                kind: accepted ? .conversionConfirmation : .explicitCandidate, rank: 0, context: "", selectedAt: Date()))
            engine.resolveFeedback(id, accepted: accepted)
            let preference = CandidatePreferenceMemory(directory: directory).choicePreference(reading: value.reading, surface: value.text, context: "")
            XCTAssertEqual(preference.bonus, 0)
            XCTAssertEqual(preference.confidence, 0)
        }
    }

    func testWordPreferenceTransfersToAnotherPhraseWithoutStrongGlobalLock() throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        var phrase = ComposingText(); RomajiConverter.insert("hashiwotsukau", into: &phrase)
        let choice = try XCTUnwrap(engine.candidates(for: phrase, revision: 1, includeCorrections: false).first {
            $0.text == "箸を使う" && $0.learningEligible
        })
        engine.complete(choice); engine.flushLearning(); engine.reset()
        var word = ComposingText(); RomajiConverter.insert("hashi", into: &word)
        let value = try XCTUnwrap(engine.candidates(for: word, revision: 2, includeCorrections: false).first { $0.text == "箸" })
        XCTAssertGreaterThan(value.userPreferenceScore, 0)
        XCTAssertEqual(value.userPreferenceConfidence, 0)
        XCTAssertLessThanOrEqual(value.userPreferenceScore, 1.5)
    }

    func testNewCorrectionsReplaceAnEstablishedHabitWithoutErasingHistory() throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        var query = ComposingText(); RomajiConverter.insert("hashi", into: &query)
        let context = "川を渡るための"
        var date = Date()
        for (surface, times) in [("橋", 20), ("箸", 2)] {
            for _ in 0..<times {
                engine.reset(); engine.reconcileContext(context)
                let values = engine.candidates(for: query, revision: 1, includeCorrections: false)
                let index = try XCTUnwrap(values.firstIndex { $0.text == surface && $0.learningEligible })
                let id = UUID()
                date = date.addingTimeInterval(0.01)
                engine.stageSelection(values[index], event: CandidateLearningFeedback(id: id, kind: .explicitCandidate,
                    rank: index, context: context, selectedAt: date))
                engine.resolveFeedback(id, accepted: true)
            }
        }
        let restored = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        restored.reconcileContext(context)
        let result = restored.candidates(for: query, revision: 2, includeCorrections: false)
        XCTAssertEqual(result.first?.text, "箸")
        let memory = CandidatePreferenceMemory(directory: directory)
        XCTAssertEqual(memory.choicePreference(reading: "ハシ", surface: "橋", context: context).confidence, 0)
        XCTAssertGreaterThan(memory.choicePreference(reading: "ハシ", surface: "橋", context: "別の場面").bonus, 0)
        XCTAssertGreaterThan(memory.choicePreference(reading: "ハシ", surface: "箸", context: context).confidence, 0.65)
    }

    func testExplicitKatakanaModeOverridesLearnedHiraganaStyle() throws {
        let directory = isolatedLearningDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = CandidatePreferenceMemory(directory: directory)
        for _ in 0..<8 {
            memory.record(reading: "ハシ", surface: "はし", scope: "choice")
            memory.record(reading: "ハシ", surface: "はし", scope: "style")
        }
        memory.flush()
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        var query = ComposingText(); RomajiConverter.insert("hashi", into: &query)
        XCTAssertEqual(engine.candidates(for: query, revision: 1, includeCorrections: false).first?.text, "はし")
        XCTAssertEqual(engine.candidates(for: query, katakana: true, revision: 2, includeCorrections: false).first?.text, "ハシ")
    }
}
