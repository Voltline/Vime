import XCTest
import CoreML
import Darwin

/// Chinese reranking cost per key, as the keyboard pays it: real Rime
/// candidates, key by key, for a few sentences typed one after another
/// (each committed sentence joins the context of the next), scored with
/// `ChineseLanguageModel.scores` as `ChineseCandidateRanking` calls it.
/// Every configuration replays the same keys on its own model instance.
///
/// Skipped unless VIME_ZH_BENCHMARK=1 (xcodebuild: TEST_RUNNER_VIME_ZH_BENCHMARK=1).
/// The report is one `VIME_ZH_BENCHMARK {json}` line. Use an optimized build
/// for absolute numbers; simulator numbers only compare configurations.
final class ChineseRerankingBenchmarkTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_ZH_BENCHMARK"] == "1")
    }

    /// Pinyin typed in order; each sentence is committed with Rime's first
    /// candidate and stays in the context of the next.
    static let script: [[String]] = [
        ["women", "mingtian", "xiawu", "sandian", "zai", "gongsi", "kaihui"],
        ["taolun", "xiayige", "jidu", "de", "gongzuo", "jihua"],
        ["jintian", "tianqi", "henhao", "dajia", "yiqi", "qu", "gongyuan", "sanbu", "ba"],
        ["zhege", "shurufa", "de", "zhinengpaixu", "feichang", "haoyong"],
        ["wanshang", "qichidian", "zai", "laodifang", "jian"],
    ]

    /// What one key asks of the model.
    struct Request { let context: String; let texts: [String] }

    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChineseRerankingBenchmark-\(UUID().uuidString)")

    /// The requests the script makes, in order: one per key that leaves
    /// more than one candidate to reorder.
    private func requests() throws -> [Request] {
        let engine = RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData), userDirectory: Self.user)
        var requests: [Request] = []
        var committed = ""
        for sentence in Self.script {
            _ = engine.sendAndWait(.clear)
            var chosen = ""
            for (index, word) in sentence.enumerated() {
                var state = RimeState()
                for letter in word {
                    state = engine.sendAndWait(.type(String(letter)))
                    let slots = ChineseCandidateRanking.slots(state.candidates) { _ in true }
                    guard slots.canReorder else { continue }
                    requests.append(Request(context: VimeLanguageModel.sentenceContext(committed + chosen),
                                            texts: slots.all.map { state.candidates[$0].genuine }))
                }
                // Commit word by word so the composition stays short, as it often is.
                let first = try XCTUnwrap(state.candidates.first, "no candidate for \(word)")
                chosen += first.genuine
                _ = engine.sendAndWait(.clear)
                if index == sentence.count - 1 { committed += chosen + "。" }
            }
        }
        return requests
    }

    private struct Configuration {
        let name: String
        let reuse: Bool
        let hints: MLOptimizationHints
    }

    private static var configurations: [Configuration] {
        var frequent = MLOptimizationHints(); frequent.reshapeFrequency = .frequent
        var infrequent = MLOptimizationHints(); infrequent.reshapeFrequency = .infrequent
        var fast = MLOptimizationHints(); fast.specializationStrategy = .fastPrediction
        var fastFrequent = MLOptimizationHints(); fastFrequent.specializationStrategy = .fastPrediction
        fastFrequent.reshapeFrequency = .frequent
        let all = [
            Configuration(name: "baseline", reuse: false, hints: MLOptimizationHints()),
            Configuration(name: "reuse", reuse: true, hints: MLOptimizationHints()),
            Configuration(name: "reuse+frequent", reuse: true, hints: frequent),
            Configuration(name: "reuse+infrequent", reuse: true, hints: infrequent),
            Configuration(name: "reuse+fast", reuse: true, hints: fast),
            Configuration(name: "reuse+fast+frequent", reuse: true, hints: fastFrequent),
        ]
        guard let only = ProcessInfo.processInfo.environment["VIME_ZH_BENCHMARK_ONLY"] else { return all }
        let names = Set(only.split(separator: ",").map(String.init))
        return all.filter { names.contains($0.name) }
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private func summary(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        let mean = values.reduce(0, +) / Double(max(1, values.count))
        return ["n": Double(values.count), "mean": mean, "p50": at(0.5), "p90": at(0.9), "p95": at(0.95),
                "max": sorted.last ?? 0, "over60": Double(values.filter { $0 > 60 }.count)]
    }

    func testRerankingCostPerKey() throws {
        let requests = try requests()
        XCTAssertGreaterThan(requests.count, 20)
        let passes = Int(ProcessInfo.processInfo.environment["VIME_ZH_BENCHMARK_PASSES"] ?? "2") ?? 2
        var report: [String: Any] = [
            "requests": requests.count,
            "mean_candidates": Double(requests.map(\.texts.count).reduce(0, +)) / Double(requests.count),
            "mean_context_chars": Double(requests.map(\.context.count).reduce(0, +)) / Double(requests.count),
            "passes": passes,
        ]
        #if targetEnvironment(simulator)
        report["scope"] = "iOS Simulator"
        #else
        report["scope"] = "device"
        #endif
        var reference: [[Double]]?
        var results: [String: Any] = [:]
        for configuration in Self.configurations {
            try autoreleasepool {
                let model = try ChineseLanguageModel(bundle: Bundle(for: Self.self))
                model.batch.reusesPrefixes = configuration.reuse
                model.batch.optimizationHints = configuration.hints
                let loadStart = ProcessInfo.processInfo.systemUptime
                try model.batch.preload(.score)
                try model.batch.preload(.scored)
                let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
                var entry: [String: Any] = ["load_ms": loadMS]
                var worstDifference = 0.0
                for pass in 0..<passes {
                    model.batch.forgetPrefix()
                    let before = (model.batch.prefixSeconds, model.batch.scoreSeconds, model.batch.predictions,
                                  model.batch.prefixTokensRun, model.batch.prefixesReused,
                                  model.batch.scoreTokensRun, model.batch.scoreTokensUsed)
                    var times: [Double] = []
                    var scores: [[Double]] = []
                    for request in requests {
                        let start = ProcessInfo.processInfo.systemUptime
                        let values = try autoreleasepool { try model.scores(context: request.context, candidates: request.texts) }
                        times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                        scores.append(values)
                    }
                    if let reference {
                        for (a, b) in zip(scores, reference) {
                            for (x, y) in zip(a, b) { worstDifference = max(worstDifference, abs(x - y)) }
                        }
                    } else { reference = scores }
                    entry["pass\(pass)"] = [
                        "per_key_ms": summary(times),
                        "prefix_ms": (model.batch.prefixSeconds - before.0) * 1000,
                        "score_ms": (model.batch.scoreSeconds - before.1) * 1000,
                        "predictions": model.batch.predictions - before.2,
                        "prefix_tokens_run": model.batch.prefixTokensRun - before.3,
                        "prefixes_reused": model.batch.prefixesReused - before.4,
                        "score_tokens_run": model.batch.scoreTokensRun - before.5,
                        "score_tokens_used": model.batch.scoreTokensUsed - before.6,
                    ] as [String: Any]
                }
                entry["max_score_difference_vs_first"] = worstDifference
                entry["footprint_mb"] = footprintMB()
                results[configuration.name] = entry
            }
        }
        report["configurations"] = results
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("VIME_ZH_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }
}
