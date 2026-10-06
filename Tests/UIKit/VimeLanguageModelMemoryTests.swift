import XCTest
import Foundation
import Darwin
import KanaKanjiConverterModuleWithDefaultDictionary

/// Fresh-process simulator audit. Opt in with TEST_RUNNER_VIME_MEMORY_SCENARIO.
/// Run only this method per process; measure optimized code with .cpuOnly.
private nonisolated final class VimeMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var maximum = 0.0
    private var count = 0
    static func snapshot() -> [String: Double] {
        var info = task_vm_info_data_t()
        var words = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(words)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &words)
            }
        }
        guard result == KERN_SUCCESS else { return ["measurement_failed": Double(result)] }
        let unit = 1_048_576.0
        return ["physical_mib": Double(info.phys_footprint) / unit,
                "process_lifetime_peak_mib": Double(info.ledger_phys_footprint_peak) / unit,
                "resident_mib": Double(info.resident_size) / unit]
    }
    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.Voltline.Vime.memoryAudit"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, let value = Self.snapshot()["physical_mib"] else { return }
            self.lock.lock(); self.maximum = max(self.maximum, value); self.count += 1; self.lock.unlock()
        }
        timer.resume()
    }
    func reset() { lock.lock(); maximum = 0; count = 0; lock.unlock() }
    func finish() -> [String: Double] {
        lock.lock(); let result = ["sampled_peak_mib": maximum, "samples": Double(count)]; lock.unlock()
        return result
    }
    func stop() { timer.cancel() }
    deinit { timer.cancel() }
}

@MainActor
final class VimeLanguageModelMemoryTests: XCTestCase {
    func testProcessMemoryProfile() async throws {
        let scenario = ProcessInfo.processInfo.environment["VIME_MEMORY_SCENARIO"] ?? ""
        try XCTSkipUnless(["direct", "reload", "engine", "lm", "lm_words"].contains(scenario))
        let sampler = VimeMemorySampler()
        defer { sampler.stop() }
        var stages = [[String: Any]]()
        func measure(_ label: String, _ work: () async throws -> Void) async rethrows {
            sampler.reset()
            let before = VimeMemorySampler.snapshot()
            let start = ProcessInfo.processInfo.systemUptime
            try await work()
            try? await Task.sleep(for: .milliseconds(30))
            let after = VimeMemorySampler.snapshot()
            stages.append(["stage": label, "before": before, "after": after,
                           "sampling": sampler.finish(), "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
        }
        let baseline = VimeMemorySampler.snapshot()
        var checkpoints = [[String: Any]]()
        var suggestionCycles = 0
        var completedCycles = 0
        if scenario == "direct" {
            var model: VimeLanguageModel?
            try await measure("load_model") { try autoreleasepool { model = try VimeLanguageModel() } }
            let lm = try XCTUnwrap(model)
            let content = try lm.tokenizer.encode("明日の会議までに、")
            let seed: [Int32] = [2] + content
            for length in [8, 64, 128] {
                let ids = Array(Array(repeating: seed, count: 32).joined().prefix(length))
                try await measure("predict_T\(length)_100") {
                    for i in 0..<100 {
                        try autoreleasepool { _ = try lm.predict(ids) }
                        if i == 19 || i == 49 || i == 99 { checkpoints.append(["stage": "T\(length)", "iteration": i+1, "memory": VimeMemorySampler.snapshot()]) }
                    }
                }
            }
            try await measure("score_candidates_100") {
                for i in 0..<100 {
                    _ = try lm.scores(context: "コーヒーを", candidates: ["飲む", "買う", "飲みたい"])
                    if i % 20 == 19 { checkpoints.append(["stage": "scores", "iteration": i+1, "memory": VimeMemorySampler.snapshot()]) }
                }
            }
            try await measure("next_words_100") {
                for i in 0..<100 {
                    _ = try lm.nextWords(prompt: "駅に")
                    if i % 20 == 19 { checkpoints.append(["stage": "next_words", "iteration": i+1, "memory": VimeMemorySampler.snapshot()]) }
                }
            }
            try await measure("beam_20") {
                for _ in 0..<20 { _ = try lm.suggestions(prompt: "明日の会議までに、") }
            }
        } else if scenario == "reload" {
            try await measure("load_predict_release_20") {
                for i in 0..<20 {
                    try autoreleasepool {
                        let lm = try VimeLanguageModel()
                        _ = try lm.predict([2, 4675])
                    }
                    try await Task.sleep(for: .milliseconds(30))
                    checkpoints.append(["iteration": i+1, "memory": VimeMemorySampler.snapshot()])
                }
            }
        } else {
            let directory = isolatedLearningDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
            session.candidateRanking = scenario == "engine" ? .engine : .languageModel
            session.phraseSuggestions = scenario == "lm_words"
            session.leftContextProvider = { "明日の" }
            let readings = ["ekini", "kisha", "hashi", "nihongo", "ashitanokaiginisankashimasu"]
            func cycle(_ index: Int) async throws {
                session.reset()
                let ready = expectation(description: "candidate \(index)")
                ready.assertForOverFulfill = false
                session.onCandidatesChange = {
                    if session.isComposing && session.candidatesAreCurrent { ready.fulfill() }
                }
                _ = session.type(readings[index % readings.count])
                await fulfillment(of: [ready], timeout: 5)
                session.onCandidatesChange = nil
                // Let secondary reranking/corrections finish; do not cancel them at the first publication.
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertFalse(session.candidates.isEmpty)
                let index = session.candidateSnapshots.firstIndex { $0.fullConsumption } ?? 0
                _ = session.choose(index)
                try await Task.sleep(for: .milliseconds(100))
                completedCycles += 1
                if !session.suggestions.isEmpty { suggestionCycles += 1 }
                session.reset()
            }
            try await measure("first_worker_cycle") { try await cycle(0) }
            for batch in 0..<4 {
                try await measure("worker_cycles_\(batch*20+1)_\((batch+1)*20)") {
                    for i in 0..<20 { try await cycle(batch*20+i) }
                }
                checkpoints.append(["cycles": (batch+1)*20, "memory": VimeMemorySampler.snapshot()])
            }
            // Rapid edits and backspaces exercise cancellation without retaining old outputs.
            try await measure("rapid_input_cancel_100") {
                for _ in 0..<100 { _ = session.type("a"); _ = session.backspace() }
                session.reset()
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        try await measure("idle_1s") { try await Task.sleep(for: .seconds(1)) }
        let report: [String: Any] = ["format": "vime_memory_audit_v1", "scenario": scenario,
            "scope": "optimized iOS Simulator test-host process; not physical keyboard extension",
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "baseline": baseline,
            "stages": stages, "checkpoints": checkpoints, "completed_worker_cycles": completedCycles,
            "cycles_with_published_suggestions": suggestionCycles, "final": VimeMemorySampler.snapshot()]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("VIME_MEMORY_AUDIT " + String(decoding: data, as: UTF8.self))
    }
}
