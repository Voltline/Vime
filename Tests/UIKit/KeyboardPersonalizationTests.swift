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
        XCTAssertEqual(restored.score(reading: "ハシ", surface: "橋", now: date.addingTimeInterval(CandidatePreferenceMemory.Policy.halfLife)), score / 2, accuracy: 0.001)
        XCTAssertEqual(restored.nextWords(["書く", "読む", "テスト"], context: "プログラムを", now: date).first?.text, "テスト")
        XCTAssertEqual(restored.nextWords(["書く", "読む"], context: "プログラムを", now: date).first?.source, .userHistory)
        XCTAssertFalse(restored.nextWords(["行く"], context: "昨日", now: date).contains { $0.text == "テスト" })
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
            engine.complete(candidate); engine.flushLearning(); engine.reset()
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
}
