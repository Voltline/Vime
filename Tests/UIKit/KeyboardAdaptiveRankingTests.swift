import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardAdaptiveRankingTests: XCTestCase {
    func testStandaloneWordPreferenceTransfersToUnseenPhrase() throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        var word = ComposingText(); RomajiConverter.insert("hashi", into: &word)
        for _ in 0..<3 {
            let selected = try XCTUnwrap(engine.candidates(for: word, revision: 1, includeCorrections: false)
                .first { $0.text == "箸" && $0.learningEligible })
            engine.complete(selected); engine.flushLearning(); engine.reset()
        }
        var phrase = ComposingText(); RomajiConverter.insert("hashiwotsukau", into: &phrase)
        let value = try XCTUnwrap(engine.candidates(for: phrase, revision: 2, includeCorrections: false)
            .first { $0.text == "箸を使う" })
        XCTAssertGreaterThan(value.userPreferenceScore, 0)
        XCTAssertEqual(value.userPreferenceConfidence, 0, "A word habit must not lock an entire unseen phrase")
    }

    func testDiverseHomophoneChoicesSurviveModelAndDiskReload() throws {
        let model = try VimeLanguageModel()
        for input in ["hashi", "kami", "ame", "ishi", "kikai", "kikou", "katei", "kansei", "taishou", "shiyou", "kaeru", "koushou"] {
            let directory = isolatedLearningDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
            var query = ComposingText(); RomajiConverter.insert(input, into: &query)
            func values(_ context: String) -> [CandidateSnapshot] {
                engine.reconcileContext(context)
                return model.rerank(engine.candidates(for: query, revision: 1, includeCorrections: false),
                    context: context, katakana: false, cancelled: { false })
            }
            let initial = values("")
            let eligible = initial.indices.filter { initial[$0].learningEligible && initial[$0].fullConsumption && initial[$0].exactReading }
            let originalRank = try XCTUnwrap(eligible.dropFirst().prefix(4).last, input)
            let target = initial[originalRank].text
            var ranks = [originalRank + 1]
            for _ in 0..<3 {
                let current = values("")
                let index = try XCTUnwrap(current.firstIndex { $0.text == target })
                let event = CandidateLearningFeedback(id: UUID(), kind: .explicitCandidate, rank: index, context: "", selectedAt: Date())
                engine.stageSelection(current[index], event: event); engine.resolveFeedback(event.id, accepted: true)
                engine.reset()
                ranks.append(try XCTUnwrap(values("").firstIndex { $0.text == target }) + 1)
            }
            engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
            let restored = values("")
            let newContext = values("今日は")
            let restoredRank = try XCTUnwrap(restored.firstIndex { $0.text == target }) + 1
            let contextRank = try XCTUnwrap(newContext.firstIndex { $0.text == target }) + 1
            print("LEARNING_MATRIX input=\(input) target=\(target) ranks=\(ranks) reload=\(restoredRank) newContext=\(contextRank)")
            XCTAssertEqual(restoredRank, 1, "\(input): repeated deliberate choices must win after reload")
            XCTAssertLessThanOrEqual(contextRank, 3, "\(input): a new sentence must retain the learned habit")
        }
    }

    func testShortContextBackoffPreservesTheMoreSpecificPreference() throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = CandidatePreferenceMemory(directory: directory)
        let date = Date()
        for _ in 0..<2 {
            memory.record(reading: "ハシ", surface: "橋", context: "昨日の川を渡る", scope: "choice", now: date)
        }
        let backoff = memory.choicePreference(reading: "ハシ", surface: "橋", context: "明日の川を渡る", now: date)
        XCTAssertEqual(backoff.confidence, 0.85, accuracy: 0.001)
        for _ in 0..<3 {
            memory.record(reading: "ハシ", surface: "箸", context: "食事", scope: "choice", now: date.addingTimeInterval(1))
        }
        XCTAssertEqual(memory.choicePreference(reading: "ハシ", surface: "箸", context: "明日の川を渡る", now: date).confidence, 0)
        XCTAssertEqual(memory.choicePreference(reading: "ハシ", surface: "橋", context: "明日の川を渡る", now: date).confidence, 0.85, accuracy: 0.001)
    }

    func testRepeatedChoicesCarryConfidenceToNewSentencesWithLocalOverrides() throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = CandidatePreferenceMemory(directory: directory)
        var date = Date()
        for context in ["昨日", "今日は", "それから"] {
            date = date.addingTimeInterval(0.01)
            memory.record(reading: "ハシ", surface: "箸", context: context, scope: "choice", now: date)
        }
        XCTAssertGreaterThanOrEqual(memory.choicePreference(reading: "ハシ", surface: "箸", context: "新しい文章", now: date).confidence, 0.65)
        for _ in 0..<2 {
            date = date.addingTimeInterval(0.01)
            memory.record(reading: "ハシ", surface: "橋", context: "川を渡る", scope: "choice", now: date)
        }
        XCTAssertGreaterThanOrEqual(memory.choicePreference(reading: "ハシ", surface: "橋", context: "川を渡る", now: date).confidence, 0.65)
        XCTAssertEqual(memory.choicePreference(reading: "ハシ", surface: "箸", context: "川を渡る", now: date).confidence, 0)
    }

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
