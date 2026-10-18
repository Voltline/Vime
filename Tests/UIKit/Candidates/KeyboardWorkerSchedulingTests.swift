import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardWorkerSchedulingTests: XCTestCase {
    func testNewInputCancelsBackgroundPresentationBeforeOldCandidatesReachUI() async {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        let entered = expectation(description: "presentation preparation runs off-main")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); worker.releaseInactiveResources() }
        worker.prepareCandidatePresentation = { _, first in
            XCTAssertFalse(Thread.isMainThread)
            if first {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            } else {
                XCTFail("Cancelled preparation must stop before the next candidate")
            }
        }
        var stalePublications = 0
        worker.candidates(for: query("nihongo"), katakana: false, revision: 1, leftContext: "", continuity: nil,
            ranking: .engine) { _, _, _ in stalePublications += 1 }
        await fulfillment(of: [entered], timeout: 3)
        worker.prepareCandidatePresentation = nil
        let ready = expectation(description: "new input still converts after cancelling presentation")
        worker.candidates(for: query("hashi"), katakana: false, revision: 2, leftContext: "", continuity: nil,
            ranking: .engine) { values, _, supplementary in
            if !supplementary { XCTAssertFalse(values.isEmpty); ready.fulfill() }
        }
        release.signal()
        await fulfillment(of: [ready], timeout: 3)
        _ = await worker.resourceState()
        XCTAssertEqual(stalePublications, 0)
    }

    func testVisiblePreparationLoadsOnlyDictionaryAndIsReleasedWhenHidden() async throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        worker.disableLanguageModel(); worker.allowLanguageModel()
        let unused = await worker.resourceState()
        XCTAssertFalse(unused.engineLoaded)
        XCTAssertFalse(unused.modelLoaded)
        let entered = expectation(description: "prepare waits while host resets composition")
        let release = DispatchSemaphore(value: 0)
        JapaneseCandidateWorker.candidateQueue.async {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [entered], timeout: 2)
        defer { release.signal() }
        worker.prepareForInput(); worker.prepareForInput()
        worker.reset() // Host text/selection callbacks do not hide the keyboard.
        release.signal()
        let prepared = await worker.resourceState()
        XCTAssertTrue(prepared.engineLoaded)
        XCTAssertFalse(prepared.modelLoaded)
        XCTAssertEqual(prepared.modelLoadCount, unused.modelLoadCount)
        let fresh = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
        fresh.reconcileContext("川を渡るための")
        let expected = fresh.candidates(for: query("hashi"), revision: 1, includeCorrections: false).map(\.text)
        let ready = expectation(description: "prepared dictionary has unchanged candidates")
        worker.candidates(for: query("hashi"), katakana: false, revision: 1, leftContext: "川を渡るための", continuity: nil,
            ranking: .engine) { values, _, supplementary in
            guard !supplementary else { return }
            XCTAssertEqual(values.map(\.text), expected)
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 3)
        worker.releaseInactiveResources()
        let hidden = await worker.resourceState()
        XCTAssertFalse(hidden.engineLoaded)
        worker.prepareForInput()
        let reopened = await worker.resourceState()
        XCTAssertTrue(reopened.engineLoaded)
        XCTAssertEqual(reopened.modelLoadCount, unused.modelLoadCount)
        worker.releaseInactiveResources()
        _ = await worker.resourceState()
    }

    func testClosingOrPressureCancelsQueuedPreparationBeforeItCreatesResources() async {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        worker.disableLanguageModel(); worker.allowLanguageModel()
        let unloaded = await worker.resourceState()
        let entered = expectation(description: "converter queue occupied before preparation")
        let release = DispatchSemaphore(value: 0)
        JapaneseCandidateWorker.candidateQueue.async {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [entered], timeout: 2)
        defer { release.signal(); worker.allowLanguageModel() }
        worker.prepareForInput()
        worker.releaseInactiveResources()
        worker.prepareForInput()
        worker.handleMemoryPressure()
        release.signal()
        let cancelled = await worker.resourceState()
        XCTAssertFalse(cancelled.engineLoaded)
        XCTAssertFalse(cancelled.modelLoaded)
        XCTAssertEqual(cancelled.modelLoadCount, unloaded.modelLoadCount)
    }

    private func query(_ raw: String) -> ComposingText {
        var value = ComposingText(); RomajiConverter.insert(raw, into: &value); return value
    }

    /// Hold only the model executor. Tests must finish dictionary work before
    /// releasing it, rather than relying on the duration of a real prediction.
    private func holdModelQueue() async -> DispatchSemaphore {
        let entered = expectation(description: "model executor occupied")
        let release = DispatchSemaphore(value: 0)
        JapaneseCandidateWorker.modelQueue.async {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        await fulfillment(of: [entered], timeout: 2)
        return release
    }

    func testQueueWaitConsumesRankingBudgetInsteadOfStartingAnotherWindow() async {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        worker.allowLanguageModel()
        let warm = expectation(description: "warm the shared model")
        worker.candidates(for: query("hashi"), katakana: false, revision: 1, leftContext: "川を渡る", continuity: nil) { _, _, supplementary in
            if !supplementary { warm.fulfill() }
        }
        await fulfillment(of: [warm], timeout: 5)
        let loaded = await worker.resourceState()
        XCTAssertTrue(loaded.modelLoaded)
        worker.reset()
        let entered = expectation(description: "converter queue occupied")
        let release = DispatchSemaphore(value: 0)
        JapaneseCandidateWorker.candidateQueue.async {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [entered], timeout: 2)
        defer { release.signal(); worker.reset(); KeyboardPerformance.configure(enabled: false) }
        KeyboardPerformance.configure(enabled: true, reset: true)
        let ready = expectation(description: "expired request publishes dictionary candidates")
        worker.candidates(for: query("hashi"), katakana: false, revision: 2, leftContext: "川を渡る", continuity: nil) { values, _, supplementary in
            guard !supplementary else { return }
            XCTAssertGreaterThan(CandidateCompetitionPolicy.plan(values, katakana: false).slots.count, 1)
            ready.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + JapaneseCandidateWorker.initialRankingWindow + 0.020) { release.signal() }
        await fulfillment(of: [ready], timeout: 3)
        _ = await worker.resourceState()
        XCTAssertNil(KeyboardPerformance.report()["lmCandidateScoring"], "Queue time must consume the model's publication budget")
    }

    func testBusyModelDoesNotBlockFallbackCorrectionsOrNewInput() async throws {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        worker.disableLanguageModel(); worker.allowLanguageModel()
        let unloaded = await worker.resourceState()
        XCTAssertFalse(unloaded.modelLoaded)
        let release = await holdModelQueue()
        defer { release.signal(); worker.reset() }
        let initial = expectation(description: "dictionary fallback while model remains busy")
        let corrected = expectation(description: "corrections follow first display while model remains busy")
        var initialCount = 0
        var correctionDelivered = false
        worker.candidates(for: query("shitsuka"), katakana: false, revision: 1, leftContext: "今日は", continuity: nil) { values, _, supplementary in
            if !supplementary {
                initialCount += 1
                XCTAssertGreaterThan(CandidateCompetitionPolicy.plan(values, katakana: false).slots.count, 1,
                    "Exercise an actual neural ranking request")
                initial.fulfill()
            } else if values.contains(where: { $0.text == "静か" && $0.correction != nil }), !correctionDelivered {
                XCTAssertEqual(initialCount, 1, "A supplement must never precede the initial list")
                correctionDelivered = true; corrected.fulfill()
            }
        }
        await fulfillment(of: [initial, corrected], timeout: 2, enforceOrder: true)
        let next = expectation(description: "new input converts before model executor is released")
        let started = ProcessInfo.processInfo.systemUptime
        worker.candidates(for: query("nihongo"), katakana: false, revision: 2, leftContext: "", continuity: nil,
            ranking: .engine) { values, _, supplementary in
            guard !supplementary else { return }
            XCTAssertEqual(values.first?.text, "日本語")
            print("MODEL_BUSY_NEW_INPUT_MS \((ProcessInfo.processInfo.systemUptime - started) * 1000)")
            next.fulfill()
        }
        await fulfillment(of: [next], timeout: 2)
        release.signal()
        let drained = await worker.resourceState()
        XCTAssertEqual(initialCount, 1, "The late model task cannot republish the old initial list")
        XCTAssertEqual(drained.modelLoadCount, unloaded.modelLoadCount, "Cancelled queued work must not cold-load the model")
    }

    func testNativeSuggestionsAndTypingContinueWhileModelIsBusy() async {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        worker.allowLanguageModel()
        let release = await holdModelQueue()
        defer { release.signal(); worker.reset() }
        let native = expectation(description: "native suggestions bypass busy model executor")
        var suggestionPublications = 0
        worker.suggestions(prompt: "駅に", leftContext: "駅に", useLanguageModel: true) { values in
            suggestionPublications += 1
            XCTAssertTrue(values.contains { $0.nativePrediction != nil })
            native.fulfill()
        }
        await fulfillment(of: [native], timeout: 2)
        let typed = expectation(description: "typing cancels queued neural suggestions")
        worker.candidates(for: query("nanim"), katakana: false, revision: 1, leftContext: "", continuity: nil,
            ranking: .engine) { values, _, supplementary in
            guard !supplementary else { return }
            XCTAssertTrue(values.contains { $0.text == "何も" })
            typed.fulfill()
        }
        await fulfillment(of: [typed], timeout: 2)
        release.signal()
        _ = await worker.resourceState()
        XCTAssertEqual(suggestionPublications, 1, "Cancelled neural suggestions must not overwrite new composition")
    }

    func testPressureAllowsDictionaryFallbackBeforeBusyModelCanBeReleased() async {
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        let wasSuspended = JapaneseCandidateWorker.isLanguageModelSuspendedForMemoryPressure
        worker.allowLanguageModel()
        defer {
            worker.reset()
            if wasSuspended { worker.handleMemoryPressure() } else { worker.allowLanguageModel() }
        }
        let warm = expectation(description: "load the shared model before pressure")
        worker.candidates(for: query("hashi"), katakana: false, revision: 1, leftContext: "川を渡る", continuity: nil) { _, _, supplementary in
            if !supplementary { warm.fulfill() }
        }
        await fulfillment(of: [warm], timeout: 2)
        let loaded = await worker.resourceState()
        XCTAssertTrue(loaded.modelLoaded)
        let release = await holdModelQueue()
        defer { release.signal() }
        worker.handleMemoryPressure()
        XCTAssertTrue(JapaneseCandidateWorker.isLanguageModelSuspendedForMemoryPressure)
        let replacement = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        defer { replacement.releaseInactiveResources() }
        let fallback = expectation(description: "replacement keyboard works before model cleanup can run")
        replacement.candidates(for: query("hashi"), katakana: false, revision: 2, leftContext: "川を渡る", continuity: nil) { values, _, supplementary in
            guard !supplementary else { return }
            XCTAssertTrue(values.contains { $0.text == "橋" })
            fallback.fulfill()
        }
        await fulfillment(of: [fallback], timeout: 2)
        release.signal()
        let trimmed = await replacement.resourceState()
        XCTAssertFalse(trimmed.modelLoaded)
        XCTAssertTrue(trimmed.modelSuspendedForMemoryPressure)
        XCTAssertEqual(trimmed.modelLoadCount, loaded.modelLoadCount)
    }
}
