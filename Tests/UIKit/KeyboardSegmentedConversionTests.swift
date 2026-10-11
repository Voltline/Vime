import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardSegmentedConversionTests: XCTestCase {
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
}
