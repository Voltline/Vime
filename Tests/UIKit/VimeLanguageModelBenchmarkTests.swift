import XCTest
import CoreML
import Darwin
import KanaKanjiConverterModuleWithDefaultDictionary

/// Device latency/memory report for the local LM. Skipped unless the runner sets
/// VIME_LM_BENCHMARK=1 (xcodebuild: TEST_RUNNER_VIME_LM_BENCHMARK=1). Run with an
/// optimized build; the report is printed as one `VIME_LM_BENCHMARK {json}` line.
@MainActor
final class VimeLanguageModelBenchmarkTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_LM_BENCHMARK"] == "1")
    }

    private static let rerankCases: [(String, String)] = [
        ("kisha", "明日の"), ("hashi", "川に"), ("kaku", "手紙を"), ("kami", "白い"), ("kikan", "研究"),
        ("shizuka", ""), ("nihongo", ""), ("kaigi", "明日の"), ("seikaku", "彼の"), ("kousei", "文章の"),
        ("shiyou", "この機能を"), ("kouen", "日曜日に"), ("kanjou", "お客様の"), ("shinkou", "計画の"),
        ("hajimete", "今日は"), ("ame", "今日は"), ("atsui", "夏は"), ("kaeru", "家に"),
        ("kyouhaamegafutteimasu", ""), ("ashitanokaiginisankashimasu", "")
    ]

    private func footprint() -> (current: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    private func milliseconds(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func summary(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        return ["n": Double(values.count), "p50": at(0.5), "p95": at(0.95), "max": sorted.last ?? 0]
    }

    func testDeviceLatencyAndMemory() throws {
        var report: [String: Any] = [:]
        report["footprint_before_mb"] = footprint().current
        var lm: VimeLanguageModel!
        // Hash verification reads every file into autoreleased Data; drain it before measuring.
        report["load_ms"] = try milliseconds { try autoreleasepool { lm = try VimeLanguageModel() } }
        report["footprint_after_load_mb"] = footprint().current
        let probe: [Int32] = [2] + (try lm.tokenizer.encode("明日の会議までに、"))
        report["first_predict_ms"] = try milliseconds { _ = try lm.predict(probe) }
        report["footprint_after_first_predict_mb"] = footprint().current
        for _ in 0..<50 { try autoreleasepool { _ = try lm.predict(Array((Array(repeating: probe, count: 20).joined()).prefix(64))) } }
        report["footprint_after_50_predicts_mb"] = footprint().current
        report["reload_ms"] = try milliseconds { try autoreleasepool { _ = try VimeLanguageModel() } }

        var predict: [String: [String: Double]] = [:]
        var softmax: [Double] = []
        for length in [1, 8, 16, 32, 64, 128] {
            let ids = Array((Array(repeating: probe, count: 20).joined()).prefix(length))
            _ = try lm.predict(ids)
            var times: [Double] = []
            for _ in 0..<10 {
                try autoreleasepool {
                    var logits: MLMultiArray!
                    times.append(try milliseconds { logits = try lm.predict(ids) })
                    softmax.append(try milliseconds { _ = try VimeLanguageModel.logProbabilities(logits, row: ids.count - 1) })
                }
            }
            predict["T\(length)"] = summary(times)
        }
        report["predict_cpu_ms"] = predict
        report["log_softmax_row_ms"] = summary(softmax)

        let engine = JapaneseCandidateEngine()
        var scoring: [Double] = []
        var engineTimes: [Double] = []
        var slots: [Double] = []
        var overBudget = 0
        for (romaji, context) in Self.rerankCases {
            var query = ComposingText()
            RomajiConverter.insert(romaji, into: &query)
            engine.reset(); engine.reconcileContext(context)
            var values: [CandidateSnapshot] = []
            engineTimes.append(milliseconds { values = engine.candidates(for: query, revision: 1, includeCorrections: false) })
            let texts = values.filter { $0.source == .conversion && $0.fullConsumption && $0.exactReading && $0.lexical }.map(\.text)
            guard texts.count > 1 else { continue }
            _ = try? lm.scores(context: context, candidates: texts)
            for _ in 0..<5 {
                let time = try milliseconds { _ = try lm.scores(context: context, candidates: texts) }
                scoring.append(time); slots.append(Double(texts.count))
                if time > 250 { overBudget += 1 }
            }
        }
        report["engine_candidates_ms"] = summary(engineTimes)
        report["rerank_scoring_ms"] = summary(scoring)
        report["rerank_slots"] = summary(slots)
        report["rerank_over_250ms"] = overBudget
        report["footprint_after_rerank_mb"] = footprint().current

        let prompts = ["今日は雨が降っているので、", "明日の会議までに、", "駅に着いたら、", "お腹が空いたので、", "本日はお忙しい中、",
                       "ご確認のほど、", "添付した資料を", "パスワードを入力して", "アプリを更新したら、", "旅行に出かける前に、"]
        _ = try lm.suggestions(prompt: prompts[0])
        var beam: [Double] = []
        for prompt in prompts {
            for _ in 0..<3 { beam.append(try milliseconds { _ = try lm.suggestions(prompt: prompt) }) }
        }
        report["suggestions_ms"] = summary(beam)
        var words: [Double] = []
        for prompt in prompts {
            for _ in 0..<3 { words.append(try milliseconds { _ = try lm.nextWords(prompt: prompt) }) }
        }
        report["next_words_ms"] = summary(words)
        report["footprint_after_suggestions_mb"] = footprint().current

        report["footprint_peak_mb"] = footprint().peak

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("VIME_LM_BENCHMARK " + String(decoding: data, as: UTF8.self))
    }

    /// One compute unit per process: the INT8 quantized gather can abort inside MPS.
    func testOtherComputeUnit() throws {
        let units: [String: MLComputeUnits] = ["all": .all, "cpuAndGPU": .cpuAndGPU, "cpuAndNeuralEngine": .cpuAndNeuralEngine]
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["VIME_LM_UNITS"])
        let unit = try XCTUnwrap(units[name])
        var model: VimeLanguageModel!
        var entry: [String: Double] = ["load_ms": try milliseconds { model = try VimeLanguageModel(computeUnits: unit) }]
        let probe: [Int32] = [2] + (try model.tokenizer.encode("明日の会議までに、"))
        for length in [16, 16, 64, 128, 8] {
            let ids = Array((Array(repeating: probe, count: 20).joined()).prefix(length))
            print("VIME_LM_UNITS_PROGRESS \(name) T\(length)")
            if entry["first_T\(length)_ms"] == nil {
                entry["first_T\(length)_ms"] = try milliseconds { _ = try model.predict(ids) }
            }
            var times: [Double] = []
            for _ in 0..<10 { try autoreleasepool { times.append(try milliseconds { _ = try model.predict(ids) }) } }
            entry["p50_T\(length)_ms"] = summary(times)["p50"]
        }
        let data = try JSONSerialization.data(withJSONObject: [name: entry], options: [.sortedKeys])
        print("VIME_LM_UNITS " + String(decoding: data, as: UTF8.self))
    }
}
