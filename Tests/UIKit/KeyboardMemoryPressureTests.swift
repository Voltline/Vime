import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardMemoryPressureTests: XCTestCase {
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
        func request(_ input: String, revision: Int) async -> [CandidateSnapshot] {
            var composing = ComposingText(); RomajiConverter.insert(input, into: &composing)
            let ready = expectation(description: "Base candidates \(revision)")
            var snapshots: [CandidateSnapshot] = []
            worker.candidates(for: composing, katakana: false, revision: revision, leftContext: "", continuity: nil) { values, _, secondary in
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

    func testPressureBeforeFirstRequestDoesNotInitializeResources() async {
        let worker = JapaneseCandidateWorker()
        worker.handleMemoryPressure()
        let state = await worker.resourceState()
        XCTAssertFalse(state.engineLoaded)
        XCTAssertFalse(state.modelLoaded)
        XCTAssertTrue(state.modelSuspendedForMemoryPressure)
    }
}
