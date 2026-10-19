import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

/// Deterministic virtual-time storage simulation plus real converter feedback.
/// These are behavioral scenarios, separate from clean-state corpus accuracy.
@MainActor
final class KeyboardLongTermLearningTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private struct Habit {
        let reading: String
        let surface: String
        let context: String
    }
    private let habits: [Habit] = [
        .init(reading: "ハシ", surface: "橋", context: "川を渡るための"),
        .init(reading: "ハシ", surface: "箸", context: "食事に使う"),
        .init(reading: "カミ", surface: "紙", context: "プリンターに入れる白い"),
        .init(reading: "カミ", surface: "髪", context: "美容院で切った"),
        .init(reading: "キシャ", surface: "記者", context: "新聞社に勤める"),
        .init(reading: "キシャ", surface: "汽車", context: "線路を走る古い")
    ]
    private func directory() throws -> URL {
        let directory = isolatedLearningDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func archiveRows(_ directory: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("VimeSelectionFrequency.json"))
        let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Array(try XCTUnwrap(archive["entries"] as? [String: [String: Any]]).values)
    }
    private func noiseReading(_ number: Int) -> String {
        let kana = Array("アイウエオカキクケコサシスセソタチツテトナニヌネノ")
        return "ユ" + String([kana[number / 625 % 25], kana[number / 25 % 25], kana[number % 25]])
    }

    func testNinetyVirtualDaysRetainActiveHabitsAcrossRestartAndCapacityPressure() throws {
        let directory = try directory()
        var memory = CandidatePreferenceMemory(directory: directory)
        let start = Date().addingTimeInterval(-90 * day)
        var checks = 0, maximumRows = 0, maximumBytes = 0
        for index in 0..<90 {
            let now = start.addingTimeInterval(Double(index) * day)
            // Daily deliberate use in two distinct contexts for each reading.
            for habit in habits {
                for scope in ["conversion", "choice", "wordChoice"] {
                    memory.record(reading: habit.reading, surface: habit.surface, context: habit.context,
                        scope: scope, weight: 0.7, now: now)
                }
            }
            // 1080 unrelated one-off selections over the run exceed the
            // reserved global tier and exercise eviction without enormous RAM.
            for offset in 0..<12 {
                let number = index * 12 + offset
                memory.record(reading: noiseReading(number), surface: "記録\(number)", context: "別の入力\(number)",
                    scope: "choice", now: now.addingTimeInterval(Double(offset + 1)))
            }
            memory.flush()
            let rows = try archiveRows(directory)
            let bytes = try Data(contentsOf: directory.appendingPathComponent("VimeSelectionFrequency.json")).count
            maximumRows = max(maximumRows, rows.count); maximumBytes = max(maximumBytes, bytes)
            XCTAssertLessThanOrEqual(rows.count, CandidatePreferenceMemory.Policy.maximumEntries)
            XCTAssertLessThanOrEqual(bytes, CandidatePreferenceMemory.Policy.maximumFileBytes)
            XCTAssertNil(memory.persistenceError)
            memory = CandidatePreferenceMemory(directory: directory) // Daily process restart.
            if index >= 2 {
                for habit in habits {
                    let preference = memory.choicePreference(reading: habit.reading, surface: habit.surface,
                        context: habit.context, now: now.addingTimeInterval(60))
                    XCTAssertGreaterThanOrEqual(preference.confidence, 0.65, "day \(index + 1): \(habit.surface)")
                    XCTAssertTrue(preference.matchesExactContext)
                    XCTAssertTrue(memory.rememberedConversions(reading: habit.reading, context: habit.context,
                        now: now.addingTimeInterval(60)).contains(habit.surface))
                    checks += 1
                }
            }
        }
        let rows = try archiveRows(directory)
        for habit in habits {
            XCTAssertTrue(rows.contains { $0["scope"] as? String == "choice" && $0["context"] as? String == ""
                && $0["reading"] as? String == habit.reading && $0["surface"] as? String == habit.surface })
        }
        print("LONG_TERM_RETENTION days=90 dailyRestarts=90 recurringHabits=6 unrelatedChoices=1080 checks=\(checks) maxRows=\(maximumRows) maxArchiveBytes=\(maximumBytes)")
    }

    func testInactivePreferenceDecaysAndNeedsFreshEvidenceWithoutRejuvenatingOldCounts() throws {
        let directory = try directory(), memory = CandidatePreferenceMemory(directory: directory)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<2 { memory.record(reading: "ハシ", surface: "橋", context: "川を渡るための", scope: "choice", now: start) }
        let confidence = [0, 30, 90].map { days in
            memory.choicePreference(reading: "ハシ", surface: "橋", context: "川を渡るための",
                now: start.addingTimeInterval(Double(days) * day)).confidence
        }
        XCTAssertEqual(confidence[0], 1, accuracy: 0.0001)
        XCTAssertEqual(confidence[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(confidence[2], 0.125, accuracy: 0.0001)
        let later = start.addingTimeInterval(90 * day)
        XCTAssertFalse(memory.rememberedConversions(reading: "ハシ", context: "川を渡るための", now: later).contains("橋"))
        memory.record(reading: "ハシ", surface: "橋", context: "川を渡るための", scope: "choice", now: later)
        XCTAssertEqual(memory.choicePreference(reading: "ハシ", surface: "橋", context: "川を渡るための", now: later).confidence,
            0.625, accuracy: 0.0001, "A fresh event must not refresh all historical evidence")
        memory.record(reading: "ハシ", surface: "橋", context: "川を渡るための", scope: "choice", now: later.addingTimeInterval(1))
        XCTAssertGreaterThanOrEqual(memory.choicePreference(reading: "ハシ", surface: "橋", context: "川を渡るための",
            now: later.addingTimeInterval(1)).confidence, 0.65)
        print("LONG_TERM_DECAY confidenceDay0=\(confidence[0]) confidenceDay30=\(confidence[1]) confidenceDay90=\(confidence[2]) freshChoicesToRestoreProtection=2")
    }

    func testRealConverterCorrectionsReplaceSixtyOldChoicesAndRecoverFromOneMistake() throws {
        let directory = try directory(), model = try VimeLanguageModel()
        var engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        var input = ComposingText(); RomajiConverter.insert("hashi", into: &input)
        let context = "川を渡るための", otherContext = "食事に使う"
        let start = Date().addingTimeInterval(-70 * day)
        var revision = 0
        func values(_ context: String) -> [CandidateSnapshot] {
            engine.reset(); engine.reconcileContext(context); revision += 1
            return engine.candidates(for: input, revision: revision, includeCorrections: false)
        }
        func choose(_ surface: String, context: String, date: Date, accepted: Bool = true) throws {
            let candidates = values(context)
            let slot = try XCTUnwrap(candidates.firstIndex { $0.text == surface && $0.fullConsumption })
            let feedback = CandidateLearningFeedback(id: UUID(), kind: .explicitCandidate,
                rank: slot, context: context, selectedAt: date)
            engine.stageSelection(candidates[slot], event: feedback)
            engine.resolveFeedback(feedback.id, accepted: accepted)
        }
        for index in 0..<60 {
            try choose("橋", context: context, date: start.addingTimeInterval(Double(index) * day))
            if index.isMultiple(of: 10) { engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true) }
        }
        XCTAssertEqual(values(context).first?.text, "橋")
        // A separate established context survives changes to the first one.
        let now = Date().addingTimeInterval(-60)
        for index in 0..<3 { try choose("箸", context: otherContext, date: now.addingTimeInterval(Double(index))) }
        var correctionRanks: [Int] = []
        for index in 0..<2 {
            try choose("箸", context: context, date: now.addingTimeInterval(Double(index + 10)))
            correctionRanks.append(try XCTUnwrap(values(context).firstIndex { $0.text == "箸" }) + 1)
        }
        engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        let corrected = values(context)
        XCTAssertEqual(corrected.first?.text, "箸")
        XCTAssertTrue(try XCTUnwrap(corrected.first).personalPreferenceProtectsOrder)
        XCTAssertEqual(model.rerank(corrected, context: context, katakana: false, cancelled: { false }).first?.text, "箸")
        XCTAssertEqual(values(otherContext).first?.text, "箸")
        // Unverified/rejected input must not create persistent evidence.
        let beforeRejected = try Data(contentsOf: directory.appendingPathComponent("VimeSelectionFrequency.json"))
        try choose("橋", context: context, date: now.addingTimeInterval(20), accepted: false)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("VimeSelectionFrequency.json")), beforeRejected)
        XCTAssertEqual(values(context).first?.text, "箸")
        // One accepted return to a high-count habit may promote it, but must
        // not reclaim protection until consecutive confirmations support it.
        try choose("橋", context: context, date: now.addingTimeInterval(30))
        let mistaken = values(context)
        let mistakenLeader = try XCTUnwrap(mistaken.first)
        XCTAssertFalse(mistakenLeader.personalPreferenceProtectsOrder)
        try choose("箸", context: context, date: now.addingTimeInterval(31))
        engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        let recovered = values(context)
        XCTAssertEqual(recovered.first?.text, "箸")
        XCTAssertFalse(try XCTUnwrap(recovered.first).personalPreferenceProtectsOrder)
        try choose("箸", context: context, date: now.addingTimeInterval(32))
        engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        XCTAssertTrue(try XCTUnwrap(values(context).first).personalPreferenceProtectsOrder)
        print("LONG_TERM_CORRECTION oldChoices=60 correctionRanks=\(correctionRanks) rejectedUnchanged=true mistakeProtected=\(mistakenLeader.personalPreferenceProtectsOrder) recoveryChoices=1 recoveredRank=1 protectionRestoredAfter=2")
    }
}
