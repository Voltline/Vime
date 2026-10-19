import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

/// Opt-in scheduling probes on authored examples, not a held-out accuracy set.
/// Keys arrive on a fixed cadence without draining worker queues between keys.
@MainActor
final class KeyboardRapidTypingTests: XCTestCase {
    private func query(_ raw: String) -> ComposingText {
        var value = ComposingText(); RomajiConverter.insert(raw, into: &value); return value
    }

    func testContinuousTypingKeepsLatestRevisionAndMeasuresFinalModelParticipation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_RAPID_TYPING_AUDIT"] == "1")
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        worker.allowLanguageModel()
        defer { worker.releaseInactiveResources() }
        let warm = expectation(description: "warm model independently of measured cases")
        worker.candidates(for: query("hashi"), katakana: false, revision: 0, leftContext: "川を渡るための", continuity: nil) { _, _, supplementary in
            if !supplementary { warm.fulfill() }
        }
        await fulfillment(of: [warm], timeout: 5)
        let warmed = await worker.resourceState()
        XCTAssertTrue(warmed.modelLoaded)
        struct Fixture {
            let id: String, raw: String, context: String
        }
        let fixtures = [
            Fixture(id: "bridge", raw: "hashi", context: "川を渡るための"),
            Fixture(id: "paper", raw: "kami", context: "プリンターに入れる白い"),
            Fixture(id: "meeting", raw: "kaigi", context: "明日の"),
            Fixture(id: "return", raw: "kaeru", context: "仕事が終わったので家に"),
            Fixture(id: "reporter", raw: "kisha", context: "新聞の"),
            Fixture(id: "negotiate", raw: "koushou", context: "価格を"),
            Fixture(id: "initial_bridge", raw: "hashi", context: ""),
            Fixture(id: "initial_japanese", raw: "nihongo", context: "")
        ]
        struct Row: Encodable {
            let id: String, modelGate: String?
            let pass: Int, intervalMs: Int, requests: Int, initialPublications: Int, cancellations: Int
            let stalePublications: Int, modelUsed: Bool, scored: Int
            let finalPublicationMs: Double
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var revision = 0, latest = 0
        for pass in 0..<3 {
            // Reverse cadence order on alternate passes to balance warm-up.
            for interval in pass.isMultiple(of: 2) ? [20, 40, 80] : [80, 40, 20] {
                for fixture in fixtures {
                    worker.reset()
                    var raw = "", stale = 0, elapsed = 0.0
                    var traces: [CandidatePipelineTrace] = []
                    var publications: [Int: Int] = [:]
                    let ready = expectation(description: "final \(fixture.id) at \(interval) ms")
                    let characters = Array(fixture.raw)
                    for (index, key) in characters.enumerated() {
                        raw.append(key); revision += 1; latest = revision
                        let current = revision, input = query(raw), isLast = index == characters.count - 1
                        let trace = CandidatePipelineTrace(revision: current, consumedInputCount: input.input.count)
                        traces.append(trace)
                        let start = ProcessInfo.processInfo.systemUptime
                        worker.candidates(for: input, katakana: false, revision: current, leftContext: fixture.context,
                            continuity: nil, trace: trace) { values, _, supplementary in
                                guard current == latest else { stale += 1; return }
                                XCTAssertTrue(values.allSatisfy { $0.revision == current })
                                guard !supplementary else { return }
                                publications[current, default: 0] += 1
                                XCTAssertEqual(publications[current], 1, "Only one initial list per revision")
                                if isLast, publications[current] == 1 {
                                    elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                    ready.fulfill()
                                }
                            }
                        if !isLast { try await Task.sleep(for: .milliseconds(interval)) }
                    }
                    await fulfillment(of: [ready], timeout: 5)
                    _ = await worker.resourceState()
                    let final = try XCTUnwrap(traces.last).snapshot()
                    XCTAssertEqual(stale, 0, "Obsolete requests must never reach the UI")
                    XCTAssertEqual(publications[latest], 1)
                    XCTAssertFalse(final.cancelledBeforePublication)
                    let row = Row(id: fixture.id, modelGate: final.modelGate?.rawValue, pass: pass, intervalMs: interval,
                        requests: traces.count, initialPublications: publications.values.reduce(0, +),
                        cancellations: traces.filter { $0.snapshot().cancelledBeforePublication }.count,
                        stalePublications: stale, modelUsed: final.modelUsed, scored: final[.scored]?.count ?? 0,
                        finalPublicationMs: elapsed)
                    print("RAPID_TYPING_ROW " + String(decoding: try encoder.encode(row), as: UTF8.self))
                }
            }
        }
    }
}
