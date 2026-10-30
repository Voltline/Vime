import XCTest
import Darwin

/// Latency and memory budgets checked on every run. A local Debug simulator run
/// on 2026-10-30 measured key to candidates p50 21 ms and p95 58 ms, memory flat
/// over 120 cycles and a 1,024-entry import in 185 ms; the slowest CI runner seen
/// took up to five times as long. The limits leave room for that runner, while a
/// change that makes typing several times slower or keeps memory growing fails. Each check prints a VIME_BUDGET line, which
/// Scripts/test.sh and the CI job summary list.
@MainActor
final class KeyboardBudgetTests: XCTestCase {
    private static let words = ["nihongo", "kaigi", "ashita", "benkyou", "arigatou", "konnichiha"]

    func testWarmTypingLatency() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        defer { session.onCandidatesChange = nil; session.reset() }
        var keyCosts = [Double](), candidateWaits = [Double]()
        // The first pass loads the dictionary and model; the next two are measured.
        for pass in 0..<3 {
            for word in Self.words {
                session.reset()
                for character in word {
                    let ready = expectation(description: "\(word) \(character)")
                    var delivered = false
                    session.onCandidatesChange = {
                        if session.candidatesAreCurrent, !delivered { delivered = true; ready.fulfill() }
                    }
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = session.type(String(character))
                    let typed = ProcessInfo.processInfo.systemUptime
                    await fulfillment(of: [ready], timeout: 10)
                    if pass > 0 {
                        keyCosts.append((typed - start) * 1000)
                        candidateWaits.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    }
                }
            }
        }
        // The key itself runs on the main thread, so it bounds how fast typing feels.
        // Local runs take 0.1 ms and the CI runner 3.3 ms, so this limit is wider.
        budget("type_main_thread_p95", percentile(keyCosts, 0.95), below: 20, unit: "ms")
        budget("key_to_candidates_p50", percentile(candidateWaits, 0.5), below: 150, unit: "ms")
        budget("key_to_candidates_p95", percentile(candidateWaits, 0.95), below: 300, unit: "ms")
    }

    func testSustainedTypingKeepsMemoryFlat() async throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
        defer { session.onCandidatesChange = nil; session.reset() }
        func cycle(_ index: Int) async throws {
            session.reset()
            let ready = expectation(description: "cycle \(index)")
            var delivered = false
            session.onCandidatesChange = {
                if session.candidatesAreCurrent, !delivered { delivered = true; ready.fulfill() }
            }
            _ = session.type(Self.words[index % Self.words.count])
            await fulfillment(of: [ready], timeout: 10)
            session.onCandidatesChange = nil
            let full = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.fullConsumption })
            _ = session.choose(full)
        }
        // Warm caches and learning first, so later growth would be retained work.
        for index in 0..<30 { try await cycle(index) }
        try await Task.sleep(for: .milliseconds(300))
        let before = try physicalFootprintMiB()
        for index in 30..<150 { try await cycle(index) }
        try await Task.sleep(for: .milliseconds(300))
        budget("memory_growth_120_cycles", try physicalFootprintMiB() - before, below: 16, unit: "MiB")
    }

    func testFullDictionaryImportAndExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = JapaneseUserDictionaryStore(directory: directory, defaults: defaults)
        // A Microsoft IME export at the entry limit: UTF-16 with a header.
        let kana = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわ")
        let lines = (0..<JapaneseUserDictionaryStore.maximumEntries).map { index in
            "\(kana[index % kana.count])\(kana[index / kana.count % kana.count])\(kana[index / 1_000 % kana.count])\t語彙\(index)\t名詞\t"
        }
        var data = Data([0xFF, 0xFE])
        data.append(("!Microsoft IME Dictionary Tool\n" + lines.joined(separator: "\n")).data(using: .utf16LittleEndian)!)
        var start = ProcessInfo.processInfo.systemUptime
        let result = try store.importFile(data)
        let imported = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(result.added, JapaneseUserDictionaryStore.maximumEntries)
        start = ProcessInfo.processInfo.systemUptime
        _ = try store.exportData()
        _ = JapaneseUserDictionaryInterchange.mozcText(try store.entries())
        let exported = (ProcessInfo.processInfo.systemUptime - start) * 1000
        budget("dictionary_import_1024", imported, below: 2000, unit: "ms")
        budget("dictionary_export_1024", exported, below: 50, unit: "ms")
    }

    private func budget(_ name: String, _ value: Double, below limit: Double, unit: String) {
        print(String(format: "VIME_BUDGET %@ %.1f / %.0f %@", name, value, limit, unit))
        XCTAssertLessThan(value, limit, "\(name) is over budget")
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private func physicalFootprintMiB() throws -> Double {
        var info = task_vm_info_data_t()
        var words = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(words)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &words)
            }
        }
        guard result == KERN_SUCCESS else { throw XCTSkip("task_info failed: \(result)") }
        return Double(info.phys_footprint) / 1_048_576
    }
}
