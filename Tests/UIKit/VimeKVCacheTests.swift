import XCTest
import CoreML
import Darwin

@MainActor
final class VimeKVCacheTests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Score: Decodable { let context: String; let candidates: [String]; let sums: [Double] }
        struct Phrase: Decodable { let prompt: String; let firstIDs: [Int32]; let firstText: String }
        let scoring: [Score]
        let phrases: [Phrase]
    }
    private func fixtures() throws -> Fixtures {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "VimeLMFixturesV21", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }
    func testSameINT8ScoresRetokenizationBranchesAndCancellationReset() throws {
        let cached = try VimeLanguageModel(resourceVersion: .v21KV)
        let baseline = try VimeLanguageModel(resourceVersion: .v21)
        let cases = try fixtures().scoring
        for item in cases {
            for candidates in [item.candidates, Array(item.candidates.reversed()), item.candidates] {
                let a = try cached.scores(context: item.context, candidates: candidates)
                let b = try baseline.scores(context: item.context, candidates: candidates)
                for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 0.002) }
            }
        }
        var checks = 0
        XCTAssertThrowsError(try cached.scores(context: "明日の会議までに、", candidates: ["資料を送る", "準備をする"],
            cancelled: { checks += 1; return checks >= 2 }))
        // Context changes and deletions start a new request; no old prefix state.
        for context in ["明日の会議までに、", "明日", "", "ファイル", "明日"] {
            let a = try cached.scores(context: context, candidates: ["名", "名前", "を開く"])
            let b = try baseline.scores(context: context, candidates: ["名", "名前", "を開く"])
            for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 0.002) }
        }
    }
    func testNextWordsAndBeamBranchesMatchBaselineAfterCancellation() throws {
        let cached = try VimeLanguageModel(resourceVersion: .v21KV)
        let baseline = try VimeLanguageModel(resourceVersion: .v21)
        let prompts = try fixtures().phrases.map(\.prompt)
        for prompt in prompts {
            XCTAssertEqual(try cached.nextWords(prompt: prompt), try baseline.nextWords(prompt: prompt), prompt)
            let a = try cached.suggestions(prompt: prompt)
            let b = try baseline.suggestions(prompt: prompt)
            XCTAssertEqual(a.map(\.tokenIDs), b.map(\.tokenIDs), prompt)
            XCTAssertEqual(a.map(\.text), b.map(\.text), prompt)
            for (x, y) in zip(a, b) { XCTAssertEqual(x.logProbabilitySum, y.logProbabilitySum, accuracy: 0.005) }
        }
        var checks = 0
        XCTAssertThrowsError(try cached.nextWords(prompt: "明日の会議までに、", cancelled: { checks += 1; return checks >= 3 }))
        XCTAssertEqual(try cached.nextWords(prompt: prompts[0]), try baseline.nextWords(prompt: prompts[0]))
    }
    func testFreshPredictionMatchesBaselineAtCapacityAndAfterDeletion() throws {
        let cached = try VimeLanguageModel(resourceVersion: .v21KV)
        let baseline = try VimeLanguageModel(resourceVersion: .v21)
        for length in [1, 7, 16, 128, 3, 16] {
            let ids = [Int32(2)] + (1..<length).map { Int32(($0 * 97) % 16000 + 4) }
            let a = try cached.predict(ids)
            let b = try baseline.predict(ids)
            for row in [0, length-1] {
                let x = try VimeLanguageModel.logProbabilities(a, row: row)
                let y = try VimeLanguageModel.logProbabilities(b, row: row)
                XCTAssertLessThan(zip(x,y).map { abs($0-$1) }.max()!, 0.0003)
            }
        }
        XCTAssertThrowsError(try cached.predict([]))
        XCTAssertThrowsError(try cached.predict([16384]))
        XCTAssertThrowsError(try cached.predict(Array(repeating: 2, count: 129)))
    }
    /// One backend per test-host launch so the other model cannot inflate footprint.
    func testBackendBenchmark() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["VIME_KV_BENCHMARK"] == "1")
        let backend = try XCTUnwrap(env["VIME_KV_BACKEND"])
        XCTAssertTrue(["kv", "baseline"].contains(backend))
        func memory() -> [String: Double] {
            var info = task_vm_info_data_t()
            var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let capacity = Int(n)
            let status = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: integer_t.self, capacity: capacity) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) }
            }
            guard status == KERN_SUCCESS else { return [:] }
            return ["physical_mib": Double(info.phys_footprint)/1_048_576,
                    "lifetime_peak_mib": Double(info.ledger_phys_footprint_peak)/1_048_576]
        }
        func milliseconds(_ work: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try work()
            return Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
        }
        func summary(_ values: [Double]) -> [String: Double] {
            let v = values.sorted()
            return ["n": Double(v.count), "p50": v[v.count/2], "p95": v[Int(Double(v.count-1)*0.95)], "max": v.last!]
        }
        var report: [String: Any] = ["backend": backend, "pid": ProcessInfo.processInfo.processIdentifier, "before": memory()]
        #if targetEnvironment(simulator)
        report["scope"] = "optimized iOS Simulator test host on Mac; not physical keyboard extension"
        #else
        report["scope"] = "optimized physical iPhone test host; not keyboard extension"
        #endif
        var lm: VimeLanguageModel!
        report["load_ms"] = try milliseconds { try autoreleasepool { lm = try VimeLanguageModel(resourceVersion: backend == "kv" ? .v21KV : .v21) } }
        report["model_version"] = lm.modelVersion
        report["after_load"] = memory()
        var scores = [Double](), words = [Double](), beam = [Double]()
        for _ in 0..<3 {
            _ = try lm.scores(context: "明日の会議までに、", candidates: ["資料を送る", "準備をする", "確認する", "連絡する"])
            _ = try lm.nextWords(prompt: "明日の会議までに、")
        }
        for item in try fixtures().scoring {
            for _ in 0..<20 { scores.append(try autoreleasepool { try milliseconds { _ = try lm.scores(context: item.context, candidates: item.candidates) } }) }
        }
        var longScores = [Double]()
        let context = "明日の会議までに、添付した資料を確認して、必要な修正を済ませたら、"
        let candidates = ["資料を送る", "準備をする", "確認する", "連絡する"]
        _ = try lm.scores(context: context, candidates: candidates)
        for _ in 0..<30 {
            longScores.append(try autoreleasepool { try milliseconds { _ = try lm.scores(context: context, candidates: candidates) } })
        }
        for prompt in try fixtures().phrases.map(\.prompt) {
            for _ in 0..<3 {
                words.append(try autoreleasepool { try milliseconds { _ = try lm.nextWords(prompt: prompt) } })
                beam.append(try autoreleasepool { try milliseconds { _ = try lm.suggestions(prompt: prompt) } })
            }
        }
        report["scoring_ms"] = summary(scores)
        report["long_context_scoring_ms"] = summary(longScores)
        report["long_context_tokens"] = try lm.tokenizer.encode(context).count + 1
        report["next_words_ms"] = summary(words)
        report["beam_ms"] = summary(beam)
        report["after_workload"] = memory()
        for _ in 0..<50 { try autoreleasepool { _ = try lm.nextWords(prompt: "明日の会議までに、") } }
        report["after_50_requests"] = memory()
        report["load_policy"] = "First model load in process; OS/Core ML caches may be warm. Separate backend launch; simulator system memory limits differ from device."
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("VIME_KV_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }
}
