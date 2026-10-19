import XCTest
import CryptoKit

private actor LearningWriterBarrier {
    private var arrivals = 0
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        arrivals += 1
        if arrivals == 2 { waiting?.resume(); waiting = nil; return }
        await withCheckedContinuation { waiting = $0 }
    }
}

@MainActor
final class CandidatePreferenceTransactionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let url = isolatedLearningDirectory()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func rows(_ directory: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent("VimeSelectionFrequency.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Array(try XCTUnwrap(object["entries"] as? [String: [String: Any]]).values)
    }

    func testContextKeyCachePreservesArchiveKeysAndDoesNotCacheLearningScores() throws {
        let url = try directory()
        let memory = CandidatePreferenceMemory(directory: url)
        let context = "  昨日は川を渡るための\n"
        XCTAssertEqual(memory.score(reading: "ハシ", surface: "橋", context: context, now: date), 0)
        for _ in 0..<3 { memory.record(reading: "ハシ", surface: "橋", context: context, now: date) }
        let learned = memory.score(reading: "ハシ", surface: "橋", context: context, now: date)
        XCTAssertGreaterThan(learned, memory.score(reading: "ハシ", surface: "橋", now: date))
        memory.flush()
        // This is the archive's original hex encoding, retained across updates.
        func oldKey(_ length: Int) -> String {
            let tail = String(context.trimmingCharacters(in: .whitespacesAndNewlines).suffix(length))
            return SHA256.hash(data: Data(tail.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(Set(try rows(url).compactMap { $0["context"] as? String }), ["", oldKey(12), "short:" + oldKey(4)])
        let reloaded = CandidatePreferenceMemory(directory: url)
        for index in 0..<40 { _ = reloaded.score(reading: "ハシ", surface: "橋", context: "別の文脈\(index)", now: date) }
        XCTAssertEqual(reloaded.score(reading: "ハシ", surface: "橋", context: context, now: date), learned, accuracy: 1e-9)
        let id = UUID()
        reloaded.stage(id: id, reading: "ハシ", surface: "橋", context: context, weight: 1, now: date)
        XCTAssertGreaterThan(reloaded.score(reading: "ハシ", surface: "橋", context: context, now: date), learned)
        reloaded.cancel(id)
        XCTAssertEqual(reloaded.score(reading: "ハシ", surface: "橋", context: context, now: date), learned, accuracy: 1e-9)
    }

    func testContextKeyCachePreservesDistinctUTF8SpellingsInExistingArchives() throws {
        let url = try directory()
        let memory = CandidatePreferenceMemory(directory: url)
        let contexts = ["ガラスの", "カ\u{3099}ラスの"]
        XCTAssertEqual(contexts[0], contexts[1], "Swift compares canonical equivalents as equal")
        var expected: Set<String> = [""]
        for context in contexts {
            let oldKey = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
            expected.formUnion([oldKey, "short:" + oldKey])
            memory.record(reading: "ガラス", surface: "硝子", context: context, now: date)
        }
        memory.flush()
        XCTAssertEqual(expected.count, 5)
        XCTAssertEqual(Set(try rows(url).compactMap { $0["context"] as? String }), expected)
    }

    func testReadOnlyInstanceRefreshesExternalLearningWithoutOwnWrite() throws {
        let url = try directory()
        let reader = CandidatePreferenceMemory(directory: url), writer = CandidatePreferenceMemory(directory: url)
        for _ in 0..<3 { writer.record(reading: "ハシ", surface: "箸", now: date) }
        writer.flush()
        reader.refreshIfChanged()
        XCTAssertEqual(reader.score(reading: "ハシ", surface: "箸", now: date), log(3), accuracy: 1e-9)
        reader.refreshIfChanged(); reader.flush()
        XCTAssertEqual(reader.pendingPersistenceEntryCount, 0)
        XCTAssertEqual(try rows(url).first?["confirmations"] as? Int, 3, "Refreshing must not add evidence")
        for _ in 0..<2 { writer.record(reading: "アメ", surface: "雨", now: date) }
        writer.flush(); reader.flush()
        XCTAssertEqual(reader.score(reading: "アメ", surface: "雨", now: date), log(2), accuracy: 1e-9)
    }

    func testRefreshMergesPendingDeltaOnceAndExternalClearDiscardsOldGeneration() throws {
        let url = try directory()
        let reader = CandidatePreferenceMemory(directory: url), writer = CandidatePreferenceMemory(directory: url)
        for _ in 0..<2 {
            reader.record(reading: "ハシ", surface: "箸", now: date)
            writer.record(reading: "ハシ", surface: "箸", now: date)
        }
        writer.flush(); reader.refreshIfChanged(); reader.refreshIfChanged()
        XCTAssertEqual(reader.score(reading: "ハシ", surface: "箸", now: date), log(4), accuracy: 1e-9)
        reader.flush()
        XCTAssertEqual(try rows(url).first?["confirmations"] as? Int, 4)
        reader.record(reading: "ネコ", surface: "猫", now: date)
        reader.stage(id: UUID(), reading: "ハシ", surface: "箸", context: "", weight: 1, now: date)
        writer.clear(); reader.refreshIfChanged()
        XCTAssertEqual(reader.pendingPersistenceEntryCount, 0)
        XCTAssertEqual(reader.score(reading: "ハシ", surface: "箸", now: date), 0)
        XCTAssertEqual(reader.score(reading: "ネコ", surface: "猫", now: date), 0)
        reader.flush()
        XCTAssertTrue(try rows(url).isEmpty)
    }

    func testCorruptRefreshKeepsLastGoodSnapshotAndPendingFeedback() throws {
        let url = try directory()
        let memory = CandidatePreferenceMemory(directory: url)
        for _ in 0..<3 { memory.record(reading: "ハシ", surface: "箸", now: date) }
        memory.flush(); memory.record(reading: "ネコ", surface: "猫", now: date)
        let archive = url.appendingPathComponent("VimeSelectionFrequency.json")
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: archive, options: .atomic)
        memory.refreshIfChanged()
        XCTAssertNotNil(memory.persistenceError)
        XCTAssertEqual(memory.score(reading: "ハシ", surface: "箸", now: date), log(3), accuracy: 1e-9)
        XCTAssertEqual(memory.pendingPersistenceEntryCount, 1)
        XCTAssertEqual(try Data(contentsOf: archive), corrupt)
    }

    func testExternalClearRejectsOldEngineFeedbackAfterReadRefreshButAcceptsNewSelections() throws {
        let url = try directory()
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: url, learningEnabled: true)
        let writer = CandidatePreferenceMemory(directory: url)
        let old = CandidateLearningFeedback(id: UUID(), kind: .nextWord, rank: 1, context: "本を", selectedAt: date)
        engine.stageNextWord("読む", event: old)
        writer.clear()
        // A query updates the reader's epoch before the old host receipt arrives.
        _ = engine.postCompositionSuggestions(leftContext: "本を読む")
        engine.resolveFeedback(old.id, accepted: true)
        XCTAssertEqual(engine.feedbackAccepted, 0)
        XCTAssertEqual(engine.feedbackCancelled, 1)
        XCTAssertTrue(try rows(url).isEmpty)
        for _ in 0..<2 {
            let event = CandidateLearningFeedback(id: UUID(), kind: .nextWord, rank: 1, context: "本を", selectedAt: date)
            engine.stageNextWord("読む", event: event)
            engine.resolveFeedback(event.id, accepted: true)
        }
        XCTAssertEqual(engine.feedbackAccepted, 2)
        XCTAssertEqual(CandidatePreferenceMemory(directory: url).rememberedNextWords(context: "本を", now: date), ["読む"])
    }

    func testStaleWritersMergeSameKeyExactlyOnceAcrossRepeatedFlushAndReload() throws {
        let url = try directory()
        let first = CandidatePreferenceMemory(directory: url), second = CandidatePreferenceMemory(directory: url)
        for _ in 0..<3 {
            first.record(reading: "ハシ", surface: "橋", context: "昨日", now: date)
            second.record(reading: "ハシ", surface: "橋", context: "昨日", now: date)
        }
        first.flush(); first.flush(); second.flush(); second.flush()
        XCTAssertNil(first.persistenceError); XCTAssertNil(second.persistenceError)
        let third = CandidatePreferenceMemory(directory: url)
        third.record(reading: "ハシ", surface: "橋", context: "昨日", now: date)
        third.flush(); first.flush(); second.flush()
        let entries = try rows(url)
        XCTAssertEqual(entries.count, 3, "Global plus two hashed context buckets")
        for entry in entries {
            XCTAssertEqual(entry["confirmations"] as? Int, 7)
            XCTAssertEqual(try XCTUnwrap(entry["evidence"] as? Double), 7, accuracy: 1e-9)
        }
        XCTAssertEqual(CandidatePreferenceMemory(directory: url).score(reading: "ハシ", surface: "橋", now: date), log(7), accuracy: 1e-9)
    }

    func testOutOfOrderWritersDecayEvidenceWithoutRefreshingOlderCounts() throws {
        let url = try directory()
        let older = CandidatePreferenceMemory(directory: url), newer = CandidatePreferenceMemory(directory: url)
        let later = date.addingTimeInterval(CandidatePreferenceMemory.Policy.halfLife)
        for _ in 0..<4 { older.record(reading: "ハシ", surface: "橋", now: date) }
        for _ in 0..<2 { newer.record(reading: "ハシ", surface: "橋", now: later) }
        newer.flush(); older.flush()
        let entry = try XCTUnwrap(try rows(url).first)
        XCTAssertEqual(entry["confirmations"] as? Int, 6)
        XCTAssertEqual(try XCTUnwrap(entry["evidence"] as? Double), 4, accuracy: 1e-9)
        XCTAssertEqual(entry["selectedAt"] as? Double, later.timeIntervalSince1970)
        XCTAssertEqual(CandidatePreferenceMemory(directory: url).score(reading: "ハシ", surface: "橋", now: later), log(4), accuracy: 1e-9)
    }

    func testClearEpochPreventsStaleWriterFromResurrectingPendingOrPersistedHistory() throws {
        let url = try directory()
        let first = CandidatePreferenceMemory(directory: url)
        for _ in 0..<3 { first.record(reading: "ハシ", surface: "橋", now: date) }
        first.flush()
        let stale = CandidatePreferenceMemory(directory: url)
        for _ in 0..<3 { stale.record(reading: "ネコ", surface: "猫", now: date) }
        let provisional = UUID()
        stale.stage(id: provisional, reading: "ハシ", surface: "橋", context: "", weight: 1, now: date)
        first.clear(); stale.flush()
        XCTAssertTrue(try rows(url).isEmpty)
        XCTAssertEqual(stale.score(reading: "ハシ", surface: "橋", now: date), 0)
        XCTAssertEqual(stale.score(reading: "ネコ", surface: "猫", now: date), 0)
        // Once reconciled, genuinely new feedback can be accepted in the new epoch.
        for _ in 0..<2 { stale.record(reading: "ネコ", surface: "猫", now: date) }
        stale.flush()
        let restored = CandidatePreferenceMemory(directory: url)
        XCTAssertEqual(restored.score(reading: "ハシ", surface: "橋", now: date), 0)
        XCTAssertEqual(restored.score(reading: "ネコ", surface: "猫", now: date), log(2), accuracy: 1e-9)
    }

    func testMultipleWritersMergeNextWordAndStyleWithoutPersistingProvisionalFeedback() throws {
        let url = try directory()
        let a = CandidatePreferenceMemory(directory: url), b = CandidatePreferenceMemory(directory: url)
        for _ in 0..<2 {
            a.recordNextWord("書く", context: "プログラムを", now: date)
            b.recordNextWord("書く", context: "プログラムを", now: date)
            a.record(reading: "カタカナ", surface: "カタカナ", scope: "style", now: date)
            b.record(reading: "カタカナ", surface: "カタカナ", scope: "style", now: date)
        }
        a.stage(id: UUID(), reading: "ヒミツ", surface: "秘密", context: "", weight: 1, now: date)
        a.flush(); b.flush()
        let restored = CandidatePreferenceMemory(directory: url)
        XCTAssertEqual(restored.rememberedNextWords(context: "プログラムを", now: date), ["書く"])
        XCTAssertEqual(restored.nextWordScore("書く", context: "昨日", now: date), 0)
        XCTAssertEqual(restored.score(reading: "カタカナ", surface: "カタカナ", scope: "style", now: date), log(4), accuracy: 1e-9)
        XCTAssertEqual(restored.score(reading: "ヒミツ", surface: "秘密", now: date), 0)
        for entry in try rows(url) { XCTAssertEqual(entry["confirmations"] as? Int, 4) }
    }

    func testConcurrentIndependentWritersPreserveAllEvents() async throws {
        let url = try directory()
        // Each memory is created and accessed exclusively on its own detached
        // task. A barrier ensures both instances start from the same empty file.
        let barrier = LearningWriterBarrier()
        let instant = date
        let a = Task.detached {
            let memory = CandidatePreferenceMemory(directory: url)
            await barrier.wait()
            for _ in 0..<8 { memory.record(reading: "ハシ", surface: "橋", now: instant); memory.flush() }
            return memory.persistenceError
        }
        let b = Task.detached {
            let memory = CandidatePreferenceMemory(directory: url)
            await barrier.wait()
            for _ in 0..<8 { memory.record(reading: "ハシ", surface: "橋", now: instant); memory.flush() }
            return memory.persistenceError
        }
        let firstError = await a.value, secondError = await b.value
        XCTAssertNil(firstError); XCTAssertNil(secondError)
        let entry = try XCTUnwrap(try rows(url).first)
        XCTAssertEqual(entry["confirmations"] as? Int, 16)
        XCTAssertEqual(try XCTUnwrap(entry["evidence"] as? Double), 16, accuracy: 1e-9)
    }

    func testFailedFlushRetainsEventsForRetryWithoutOverwritingCorruptArchive() throws {
        let url = try directory()
        let archive = url.appendingPathComponent("VimeSelectionFrequency.json")
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: archive)
        let memory = CandidatePreferenceMemory(directory: url)
        for _ in 0..<3 { memory.record(reading: "ハシ", surface: "橋", now: date) }
        memory.flush()
        XCTAssertNotNil(memory.persistenceError)
        XCTAssertEqual(try Data(contentsOf: archive), corrupt)
        try FileManager.default.removeItem(at: archive)
        memory.flush(); memory.flush()
        XCTAssertNil(memory.persistenceError)
        let entry = try XCTUnwrap(try rows(url).first)
        XCTAssertEqual(entry["confirmations"] as? Int, 3)
        XCTAssertEqual(try XCTUnwrap(entry["evidence"] as? Double), 3, accuracy: 1e-9)
    }

    func testFailedPersistenceCoalescesAndBoundsRetryEvidence() throws {
        let url = try directory()
        let archive = url.appendingPathComponent("VimeSelectionFrequency.json")
        let corrupt = Data("unreadable archive".utf8)
        try corrupt.write(to: archive)
        let memory = CandidatePreferenceMemory(directory: url)
        for _ in 0..<5000 { memory.record(reading: "ハシ", surface: "橋", now: date) }
        memory.flush()
        XCTAssertNotNil(memory.persistenceError)
        XCTAssertEqual(memory.pendingPersistenceEntryCount, 1)
        XCTAssertEqual(try Data(contentsOf: archive), corrupt)
        try FileManager.default.removeItem(at: archive)
        memory.flush(); memory.flush()
        let entry = try XCTUnwrap(try rows(url).first)
        // Saturation is the existing archive policy, not dropped confirmations
        // or counting the coalesced delta as a single selection.
        XCTAssertEqual(entry["confirmations"] as? Int, 1000)
        XCTAssertEqual(entry["evidence"] as? Double, 1000)
        XCTAssertEqual(memory.pendingPersistenceEntryCount, 0)
        try corrupt.write(to: archive)
        for i in 0..<(CandidatePreferenceMemory.Policy.maximumEntries + 100) {
            memory.record(reading: "テスト\(i)", surface: "語\(i)", now: date.addingTimeInterval(Double(i + 1)))
        }
        memory.flush()
        XCTAssertNotNil(memory.persistenceError)
        XCTAssertEqual(memory.pendingPersistenceEntryCount, CandidatePreferenceMemory.Policy.maximumEntries)
        XCTAssertEqual(try Data(contentsOf: archive), corrupt)
        try FileManager.default.removeItem(at: archive)
        memory.flush()
        XCTAssertNil(memory.persistenceError)
        let retained = try rows(url)
        XCTAssertEqual(retained.count, CandidatePreferenceMemory.Policy.maximumEntries)
        XCTAssertFalse(retained.contains { $0["surface"] as? String == "語0" })
        XCTAssertTrue(retained.contains { $0["surface"] as? String == "語2147" })
        XCTAssertTrue(retained.allSatisfy { $0["confirmations"] as? Int == 1 })
    }

    func testFullHistoryUpdatesAndEvictionKeepLiveIndexEquivalentToReload() throws {
        let url = try directory()
        let surfaces = (0..<CandidatePreferenceMemory.Policy.maximumEntries).map { "語\($0)" }.sorted()
        let initial = Dictionary(uniqueKeysWithValues: surfaces.map { surface in
            ("conversion\0テスト\0\0" + surface, ["scope": "conversion", "reading": "テスト", "context": "",
                "surface": surface, "evidence": 3.0, "confirmations": 3,
                "selectedAt": date.timeIntervalSince1970] as [String: Any])
        })
        try JSONSerialization.data(withJSONObject: ["version": 2, "entries": initial])
            .write(to: url.appendingPathComponent("VimeSelectionFrequency.json"))
        let memory = CandidatePreferenceMemory(directory: url)
        let instant = date.addingTimeInterval(1)
        let existing = try XCTUnwrap(surfaces.first)
        for _ in 0..<2 {
            memory.record(reading: "テスト", surface: existing, now: instant)
            for scope in ["conversion", "choice", "wordChoice"] {
                memory.record(reading: "ハシ", surface: "橋", context: "川を渡る", scope: scope, now: instant)
            }
            memory.recordNextWord("読む", context: "本を", now: instant)
        }
        let liveScore = memory.score(reading: "ハシ", surface: "橋", context: "川を渡る", now: instant)
        let liveChoice = memory.choicePreference(reading: "ハシ", surface: "橋", context: "川を渡る", now: instant)
        let liveWord = memory.choicePreference(reading: "ハシ", surface: "橋", context: "川を渡る", word: true, now: instant)
        let liveNext = memory.nextWordScore("読む", context: "本を", now: instant)
        XCTAssertGreaterThan(liveScore, 0)
        XCTAssertEqual(liveChoice.confidence, 1)
        XCTAssertGreaterThan(liveWord.bonus, 0)
        XCTAssertEqual(memory.rememberedNextWords(context: "本を", now: instant), ["読む"])
        XCTAssertGreaterThan(memory.score(reading: "テスト", surface: existing, now: instant), log(3))
        XCTAssertEqual(memory.score(reading: "テスト", surface: try XCTUnwrap(surfaces.last), now: instant), 0)

        memory.flush()
        XCTAssertNil(memory.persistenceError)
        let stored = try rows(url)
        XCTAssertEqual(stored.count, CandidatePreferenceMemory.Policy.maximumEntries)
        // Eleven new global/context entries replace the lexically last old keys
        // at a tied timestamp; refreshing an existing key must protect it.
        XCTAssertEqual(Set(stored.filter { $0["reading"] as? String == "テスト" }.compactMap { $0["surface"] as? String }),
                       Set(surfaces.dropLast(11)))
        let restored = CandidatePreferenceMemory(directory: url)
        XCTAssertEqual(restored.score(reading: "ハシ", surface: "橋", context: "川を渡る", now: instant), liveScore, accuracy: 1e-9)
        let restoredChoice = restored.choicePreference(reading: "ハシ", surface: "橋", context: "川を渡る", now: instant)
        XCTAssertEqual(restoredChoice.bonus, liveChoice.bonus, accuracy: 1e-9)
        XCTAssertEqual(restoredChoice.confidence, liveChoice.confidence, accuracy: 1e-9)
        XCTAssertEqual(restored.choicePreference(reading: "ハシ", surface: "橋", context: "川を渡る", word: true, now: instant).bonus,
                       liveWord.bonus, accuracy: 1e-9)
        XCTAssertEqual(restored.nextWordScore("読む", context: "本を", now: instant), liveNext, accuracy: 1e-9)
    }

    func testFailedClearRetriesWithNewEventsAndKeepsOldWriterInvalidated() throws {
        let url = try directory()
        let memory = CandidatePreferenceMemory(directory: url)
        for _ in 0..<3 { memory.record(reading: "ハシ", surface: "橋", now: date) }
        memory.flush()
        let stale = CandidatePreferenceMemory(directory: url)
        for _ in 0..<2 { stale.record(reading: "ハシ", surface: "橋", now: date) }
        let lock = url.appendingPathComponent("VimeSelectionFrequency.json.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        memory.clear()
        XCTAssertNotNil(memory.persistenceError)
        for _ in 0..<2 { memory.record(reading: "ネコ", surface: "猫", now: date) }
        try FileManager.default.removeItem(at: lock)
        memory.flush(); stale.flush()
        XCTAssertNil(memory.persistenceError); XCTAssertNil(stale.persistenceError)
        let restored = CandidatePreferenceMemory(directory: url)
        XCTAssertEqual(restored.score(reading: "ハシ", surface: "橋", now: date), 0)
        XCTAssertEqual(restored.score(reading: "ネコ", surface: "猫", now: date), log(2), accuracy: 1e-9)
    }
}
