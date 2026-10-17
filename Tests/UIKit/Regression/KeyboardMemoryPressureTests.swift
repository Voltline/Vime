import XCTest
import UIKit
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardMemoryPressureTests: XCTestCase {
    func testPressureStatusSurvivesReplacementAndIsShownUntilExplicitRetry() async throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        let wasSuspended = JapaneseCandidateWorker.isLanguageModelSuspendedForMemoryPressure
        gate.allowLanguageModel()
        defer {
            if wasSuspended { gate.handleMemoryPressure() }
            else { gate.allowLanguageModel() }
        }
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
        let suite = "vime.pressure.status.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyboardPreferences(defaults: defaults)
        preferences.candidateRanking = .languageModel
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session, preferences: preferences)
        let status = try XCTUnwrap(keyboard.subviews.flatMap(\.subviews).first { $0.accessibilityIdentifier == "vime.neural.status" } as? UILabel)
        XCTAssertTrue(status.isHidden)
        keyboard.handleMemoryPressure()
        XCTAssertTrue(session.neuralModeSuspendedForMemoryPressure)
        XCTAssertFalse(status.isHidden)
        keyboard.releaseInactiveResources()
        let replacement = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
        XCTAssertTrue(replacement.neuralModeSuspendedForMemoryPressure)
        preferences.candidateRanking = .engine
        keyboard.reloadPreferences()
        XCTAssertFalse(session.neuralModeSuspendedForMemoryPressure)
        XCTAssertTrue(status.isHidden)
        preferences.candidateRanking = .languageModel
        keyboard.reloadPreferences()
        XCTAssertFalse(session.neuralModeSuspendedForMemoryPressure)
        XCTAssertFalse(replacement.neuralModeSuspendedForMemoryPressure)
        XCTAssertTrue(status.isHidden)
        _ = await gate.resourceState()
    }

    func testPressurePreservesSelectionAndPartialComposition() throws {
        let session = KeyboardSession()
        _ = session.type("tennanhantenn")
        session.setExpandedCandidates(true)
        let first = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "天" })
        XCTAssertEqual(session.choose(first), [.insert("天")])
        XCTAssertEqual(session.composition, "あんはんてん")
        _ = session.space()
        let selected = try XCTUnwrap(session.selectedIndex)
        let mark = session.preedit
        let host = session.hostEpoch
        let revision = session.revision
        let presentations = session.candidatePresentations
        session.handleMemoryPressure()
        XCTAssertEqual(session.preedit, mark)
        XCTAssertEqual(session.selectedIndex, selected)
        XCTAssertEqual(session.hostEpoch, host)
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(session.candidatePresentations, presentations)
        _ = session.backspace()
        let second = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "安" })
        XCTAssertEqual(session.choose(second), [.insert("安")])
        XCTAssertEqual(session.composition, "はんてん")
        session.handleMemoryPressure()
        let last = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "飯店" })
        XCTAssertEqual(session.choose(last), [.insert("飯店")])
        XCTAssertFalse(session.isComposing)
    }

    func testPressureReissuesPendingRequestWithoutLosingSpaceOrUnfinishedRoman() async throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
        let ready = expectation(description: "Queued conversion survives memory pressure")
        var delivered = false
        session.onCandidatesChange = {
            if session.candidatesAreCurrent && session.selectedIndex != nil && !delivered {
                delivered = true; ready.fulfill()
            }
        }
        _ = session.type("tennanhantenn")
        _ = session.space()
        let raw = session.raw
        let host = session.hostEpoch
        session.handleMemoryPressure()
        XCTAssertEqual(session.raw, raw)
        XCTAssertEqual(session.hostEpoch, host)
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertTrue(session.candidatesAreCurrent)
        XCTAssertNotNil(session.selectedIndex)
        XCTAssertEqual(session.raw, raw)
        session.onCandidatesChange = nil
        session.reset()
        let suffixReady = expectation(description: "Unfinished Roman suffix still predicts in dictionary fallback")
        var suffixDelivered = false
        session.onCandidatesChange = {
            if session.candidatesAreCurrent && !suffixDelivered { suffixDelivered = true; suffixReady.fulfill() }
        }
        _ = session.type("nanim")
        session.handleMemoryPressure()
        XCTAssertEqual(session.preedit, "なにm")
        await fulfillment(of: [suffixReady], timeout: 10)
        XCTAssertTrue(session.candidates.contains("何も"))
        XCTAssertEqual(session.raw, "nanim")
        session.onCandidatesChange = nil
    }

    func testLoadedModelIsReleasedAndOrdinaryRequestsDoNotReloadIt() async throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        worker.allowLanguageModel()
        func request(_ input: String, revision: Int) async -> [CandidateSnapshot] {
            var composing = ComposingText(); RomajiConverter.insert(input, into: &composing)
            let ready = expectation(description: "Base candidates \(revision)")
            var snapshots: [CandidateSnapshot] = []
            worker.candidates(for: composing, katakana: false, revision: revision, leftContext: "川を渡るための", continuity: nil) { values, _, secondary in
                if !secondary { snapshots = values; ready.fulfill() }
            }
            await fulfillment(of: [ready], timeout: 10)
            return snapshots
        }
        let original = await request("hashi", revision: 1)
        XCTAssertGreaterThan(VimeLanguageModel.rerankingSlots(original, katakana: false).count, 1)
        // The base callback can reach MainActor before its supplementary block
        // is enqueued. Fence the base block before sampling the neural work
        _ = await worker.resourceState()
        let loaded = await worker.resourceState()
        XCTAssertTrue(loaded.modelLoaded, "The test must actually load the bundled model before asking it to release")
        worker.handleMemoryPressure()
        let trimmed = await worker.resourceState()
        XCTAssertTrue(trimmed.engineLoaded)
        XCTAssertFalse(trimmed.modelLoaded)
        XCTAssertTrue(trimmed.modelSuspendedForMemoryPressure)
        let fallback = await request("hashi", revision: 2)
        XCTAssertFalse(fallback.isEmpty)
        XCTAssertEqual(Set(fallback.map(\.text)), Set(original.map(\.text)))
        let stillTrimmed = await worker.resourceState()
        XCTAssertFalse(stillTrimmed.modelLoaded)
        XCTAssertTrue(stillTrimmed.modelSuspendedForMemoryPressure)
        worker.allowLanguageModel()
        _ = await request("hashi", revision: 3)
        _ = await worker.resourceState()
        let restored = await worker.resourceState()
        XCTAssertTrue(restored.modelLoaded)
        XCTAssertFalse(restored.modelSuspendedForMemoryPressure)
    }

    private func request(_ worker: JapaneseCandidateWorker, revision: Int) async -> [CandidateSnapshot] {
        var composing = ComposingText(); RomajiConverter.insert("hashi", into: &composing)
        let ready = expectation(description: "Dictionary candidates \(revision)")
        var snapshots: [CandidateSnapshot] = []
        worker.candidates(for: composing, katakana: false, revision: revision, leftContext: "川を渡るための", continuity: nil) { values, _, secondary in
            if !secondary { snapshots = values; ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 10)
        _ = await worker.resourceState()
        _ = await worker.resourceState()
        return snapshots
    }

    func testNewWorkerCannotReloadModelAfterAnotherWorkerReceivesPressure() async {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        first.allowLanguageModel()
        _ = await request(first, revision: 1)
        let before = await first.resourceState()
        XCTAssertTrue(before.modelLoaded)
        first.handleMemoryPressure()
        // The second controller can be created before the queued cleanup runs.
        let replacement = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        let candidates = await request(replacement, revision: 2)
        let fallback = await replacement.resourceState()
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertFalse(fallback.modelLoaded)
        XCTAssertTrue(fallback.modelSuspendedForMemoryPressure)
        XCTAssertEqual(fallback.modelLoadCount, before.modelLoadCount)
        replacement.allowLanguageModel()
        _ = await request(replacement, revision: 3)
        let restored = await replacement.resourceState()
        XCTAssertTrue(restored.modelLoaded)
        XCTAssertEqual(restored.modelLoadCount, before.modelLoadCount + 1)
        first.releaseInactiveResources(); replacement.releaseInactiveResources()
        _ = await replacement.resourceState()
    }

    func testThirtyRetainedWorkersReleaseDictionariesAndReuseOneModel() async {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        probe.disableLanguageModel()
        probe.allowLanguageModel()
        let initial = await probe.resourceState()
        // Keep every old worker alive to reproduce UIKit retaining controllers.
        var retained: [JapaneseCandidateWorker] = []
        var footprints: [Int] = []
        for cycle in 1...30 {
            let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
            retained.append(worker)
            let candidates = await request(worker, revision: cycle)
            XCTAssertTrue(candidates.contains { $0.text == "橋" })
            let active = await worker.resourceState()
            XCTAssertTrue(active.engineLoaded)
            XCTAssertTrue(active.modelLoaded)
            XCTAssertEqual(active.modelLoadCount, initial.modelLoadCount + 1)
            worker.releaseInactiveResources()
            let hidden = await worker.resourceState()
            XCTAssertFalse(hidden.engineLoaded, "Hidden worker \(cycle) must release dictionary/session resources even while retained")
            footprints.append(VimeLanguageModel.footprintMB())
        }
        // The same controller must still work after its resources were dropped.
        let reused = retained[0]
        let candidates = await request(reused, revision: 31)
        XCTAssertFalse(candidates.isEmpty)
        let reopened = await reused.resourceState()
        XCTAssertTrue(reopened.engineLoaded)
        XCTAssertEqual(reopened.modelLoadCount, initial.modelLoadCount + 1)
        reused.releaseInactiveResources()
        _ = await reused.resourceState()
        print("VIME_RETAINED_WORKER_LIFECYCLE cycles=30 hidden_footprint_mib=\(footprints)")
        XCTAssertEqual(retained.count, 30)
    }

    func testClosingWorkerCancelsQueuedPublication() async {
        let worker = JapaneseCandidateWorker()
        var composing = ComposingText(); RomajiConverter.insert("hashi", into: &composing)
        var published = false
        worker.candidates(for: composing, katakana: false, revision: 1, leftContext: "", continuity: nil) { _, _, _ in
            published = true
        }
        worker.releaseInactiveResources()
        _ = await worker.resourceState()
        await Task.yield()
        XCTAssertFalse(published)
        let hidden = await worker.resourceState()
        XCTAssertFalse(hidden.engineLoaded)
    }

    func testDeferredLearningFlushDoesNotRecreateHiddenEngine() async throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        let candidates = await request(worker, revision: 1)
        let choice = try XCTUnwrap(candidates.first { $0.learningEligible && $0.text == "橋" })
        // complete() queues persistence from inside its worker block. Closing
        // before that nested block runs must flush without lazily loading again.
        worker.complete(choice)
        worker.releaseInactiveResources()
        _ = await worker.resourceState()
        let hidden = await worker.resourceState()
        XCTAssertFalse(hidden.engineLoaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("VimeSelectionFrequency.json").path))
        let reopened = await request(worker, revision: 2)
        XCTAssertTrue(reopened.contains { $0.text == "橋" })
        worker.releaseInactiveResources()
        _ = await worker.resourceState()
    }

    func testPressureBeforeFirstRequestDoesNotInitializeResources() async {
        let worker = JapaneseCandidateWorker()
        worker.handleMemoryPressure()
        let state = await worker.resourceState()
        XCTAssertFalse(state.engineLoaded)
        XCTAssertFalse(state.modelLoaded)
        XCTAssertTrue(state.modelSuspendedForMemoryPressure)
    }
}
