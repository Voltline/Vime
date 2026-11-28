import XCTest
import Darwin
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import Vime

/// Tests and on-device benchmarks for `vimeml-ja-v6-20m`:
/// - V6/V4.2 version switch & resource integrity
/// - 125-case fixture parity (`VimeMLGenerationFixturesJaV6.json`):
///   `prompt_ids`, `gen_prompt_ids`, `gen_output_ids`, `lm_ids`, `lm_from`,
///   `scores` Top-1 (>= 123/125), and `pipeline` Top-1 (>= 123/125)
/// - Side-by-side V4.2 vs V6 on-device benchmark (`VIME_JA_V6_BENCHMARK=1`).
final class JapaneseV6GenerationTests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Search: Decodable { let mode: String; let beam: Int; let topk: Int; let token_limit: String }
        struct Rescoring: Decodable { let lambda: Double }
        struct Case: Decodable {
            struct Top: Decodable {
                let text: String
                let ids: [Int32]
                let beam_score: Double
                let gen_score: Double
                let lm_score: Double?
                let final_score: Double?
            }
            struct Merged: Decodable {
                let text: String
                let azookey_rank: Int?
                let gen_rank: Int?
                let gen_score: Double?
                let lm_score: Double?
                let final_score: Double?
                let gen_prompt_ids: [Int32]?
                let gen_output_ids: [Int32]?
                let lm_ids: [Int32]?
                let lm_from: Int?
            }
            let id: String
            let stratum: String?
            let reading: String
            let context: String
            let prompt_ids: [Int32]
            let azookey: [String]
            let top: [Top]
            let rescored: [String]
            let merged: [Merged]
            let shown: [String]
        }
        let format: String
        let search: Search
        let rescoring: Rescoring
        let cases: [Case]
    }

    nonisolated(unsafe) private static var cachedV6: JapaneseLanguageModelV6?

    private func setupV6() throws -> JapaneseLanguageModelV6 {
        if let cached = Self.cachedV6 { return cached }
        let model = try JapaneseLanguageModelV6(bundle: Bundle(for: Self.self), preload: true)
        Self.cachedV6 = model
        return model
    }

    private func loadFixtures() throws -> Fixtures {
        guard let url = Bundle(for: Self.self).url(forResource: "VimeMLGenerationFixturesJaV6", withExtension: "json") else {
            throw XCTSkip("VimeMLGenerationFixturesJaV6.json is not bundled")
        }
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.search.beam, JapaneseLanguageModelV6.defaultBeam)
        XCTAssertEqual(fixtures.search.topk, JapaneseLanguageModelV6.defaultTopK)
        XCTAssertEqual(fixtures.rescoring.lambda, JapaneseLanguageModelV6.rescoreWeight, accuracy: 1e-9)
        return fixtures
    }

    func testDefaultVersionAndSwitch() throws {
        XCTAssertEqual(JapaneseLanguageModelV6.defaultVersion, .v6)
        let v6 = try setupV6()
        XCTAssertTrue(v6.modelVersion.hasPrefix("vimeml-ja-v6-20m-kvbatch-v4-"))
        let v42 = try VimeLanguageModel(bundle: .main)
        XCTAssertFalse(v42.modelVersion.isEmpty)
    }

    /// Full 125-case fixture parity gate from `mac-ja-v6-20m.md`:
    /// - `prompt_ids` 125/125 exact
    /// - `merged` `gen_prompt_ids`, `gen_output_ids`, `lm_ids`, `lm_from` 100% exact
    /// - `scores` display Top-1 >= 123/125
    /// - `pipeline` display Top-1 >= 123/125
    func testV6FixtureParity125Cases() throws {
        try skipSlowTestUnlessFullRun()
        let fixtures = try loadFixtures()
        let model = try setupV6()

        var promptExact = 0
        var mergedTokenIDsExact = 0
        var mergedCandidatesTotal = 0
        var scoresTop1Equal = 0
        var scoresExact = 0
        var pipelineTop1Equal = 0
        var pipelineRescoredTop1Equal = 0
        var genTop1Equal = 0
        var maxGenDiff = 0.0
        var maxLMDiff = 0.0
        var maxFinalDiff = 0.0
        var scoresDiffCases: [[String: Any]] = []
        var pipelineDiffCases: [[String: Any]] = []
        var genDiffCases: [[String: Any]] = []

        for item in fixtures.cases {
            let hira = JapaneseLanguageModelV6.toHiragana(item.reading)
            let prompt = try model.promptIDs(reading: hira, context: item.context)
            XCTAssertEqual(prompt, item.prompt_ids, "\(item.id) prompt_ids mismatch")
            if prompt == item.prompt_ids { promptExact += 1 }

            let unionTexts = item.merged.map(\.text)
            let taskInputs = try model.taskScoreInputs(reading: hira, context: item.context, candidates: unionTexts)
            let lmInputs = try model.lmScoreInputs(context: item.context, candidates: unionTexts)
            for (i, ref) in item.merged.enumerated() {
                mergedCandidatesTotal += 1
                let ti = taskInputs[i]
                let li = lmInputs[i]
                let taskMatch = (ti?.promptIDs == ref.gen_prompt_ids) && (ti?.outputIDs == ref.gen_output_ids)
                let lmMatch = (li?.ids == ref.lm_ids) && (li?.from == ref.lm_from)
                XCTAssertTrue(taskMatch, "\(item.id)[\(i)] gen token ids mismatch for \(ref.text)")
                XCTAssertTrue(lmMatch, "\(item.id)[\(i)] lm token ids mismatch for \(ref.text)")
                if taskMatch && lmMatch { mergedTokenIDsExact += 1 }
            }

            // Scores check on fixture's merged list.
            let genScores = try model.scoreRows(taskInputs.map { $0.map { ($0.promptIDs, $0.outputIDs) } })
            let lmScores = try model.scoreRows(lmInputs.map { $0.map { (Array($0.ids[..<$0.from]), Array($0.ids[$0.from...])) } })
            let fixtureGen = item.merged
                .filter { $0.gen_rank != nil }
                .sorted { ($0.gen_rank ?? 0) < ($1.gen_rank ?? 0) }
                .map(\.text)
            let shownScores = JapaneseLanguageModelV6.mergeAndRank(
                azookey: item.azookey, generated: fixtureGen, genScores: genScores, lmScores: lmScores
            )
            if shownScores.first == item.shown.first {
                scoresTop1Equal += 1
            } else {
                scoresDiffCases.append([
                    "id": item.id,
                    "fixture_top1": item.shown.first ?? "",
                    "vime_top1": shownScores.first ?? "",
                ])
            }
            if shownScores == item.shown { scoresExact += 1 }

            for (i, ref) in item.merged.enumerated() {
                if let g = genScores[i], let rg = ref.gen_score {
                    maxGenDiff = max(maxGenDiff, abs(g - rg))
                }
                if let l = lmScores[i], let rl = ref.lm_score {
                    maxLMDiff = max(maxLMDiff, abs(l - rl))
                }
                if let g = genScores[i], let l = lmScores[i], let rf = ref.final_score {
                    maxFinalDiff = max(maxFinalDiff, abs((g + JapaneseLanguageModelV6.rescoreWeight * l) - rf))
                }
            }

            // Full pipeline check (device's own generation + fixture AzooKey list).
            let pipeline = try model.generateAndMerge(reading: hira, context: item.context, azookey: item.azookey)
            if pipeline.generated.first?.text == item.top.first?.text {
                genTop1Equal += 1
            } else {
                genDiffCases.append([
                    "id": item.id,
                    "fixture_top1": item.top.first?.text ?? "",
                    "vime_top1": pipeline.generated.first?.text ?? "",
                ])
            }
            if pipeline.shown.first == item.shown.first {
                pipelineTop1Equal += 1
            } else {
                pipelineDiffCases.append([
                    "id": item.id,
                    "fixture_top1": item.shown.first ?? "",
                    "vime_top1": pipeline.shown.first ?? "",
                ])
            }
            if pipeline.rescored.first == item.rescored.first {
                pipelineRescoredTop1Equal += 1
            }
        }

        let summary: [String: Any] = [
            "cases": fixtures.cases.count,
            "prompt_exact": promptExact,
            "merged_token_ids_exact": mergedTokenIDsExact,
            "merged_candidates_total": mergedCandidatesTotal,
            "generation_top1_equal": genTop1Equal,
            "scores_shown_top1_equal": scoresTop1Equal,
            "scores_shown_exact": scoresExact,
            "pipeline_shown_top1_equal": pipelineTop1Equal,
            "pipeline_rescored_top1_equal": pipelineRescoredTop1Equal,
            "max_gen_diff": maxGenDiff,
            "max_lm_diff": maxLMDiff,
            "max_final_diff": maxFinalDiff,
            "generation_diff_cases": genDiffCases,
            "scores_diff_cases": scoresDiffCases,
            "pipeline_diff_cases": pipelineDiffCases,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        print("VIME_JA_V6_FIXTURE_PARITY \(json)")

        XCTAssertEqual(promptExact, fixtures.cases.count)
        XCTAssertEqual(mergedTokenIDsExact, mergedCandidatesTotal)
        XCTAssertGreaterThanOrEqual(scoresTop1Equal, 123, "scores shown top1 below 123/125: \(json)")
        XCTAssertGreaterThanOrEqual(pipelineTop1Equal, 123, "pipeline shown top1 below 123/125: \(json)")
    }

    // MARK: - On-Device V4.2 vs V6 Benchmark

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func availableMemoryMB() -> Double {
        Double(os_proc_available_memory()) / 1_048_576
    }

    private final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var peak = 0.0
        private var minAvailable = Double.greatestFiniteMagnitude

        init() {
            peak = JapaneseV6GenerationTests.footprintMB()
            minAvailable = JapaneseV6GenerationTests.availableMemoryMB()
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                while let self, self.isRunning {
                    let current = JapaneseV6GenerationTests.footprintMB()
                    let avail = JapaneseV6GenerationTests.availableMemoryMB()
                    self.lock.lock()
                    if current > self.peak { self.peak = current }
                    if avail < self.minAvailable { self.minAvailable = avail }
                    self.lock.unlock()
                    usleep(2000)
                }
            }
        }

        private var isRunning: Bool {
            lock.lock(); defer { lock.unlock() }
            return running
        }

        func stop() -> (peakMB: Double, minAvailableMB: Double) {
            lock.lock()
            running = false
            let current = JapaneseV6GenerationTests.footprintMB()
            let avail = JapaneseV6GenerationTests.availableMemoryMB()
            if current > peak { peak = current }
            if avail < minAvailable { minAvailable = avail }
            let result = (peak, minAvailable)
            lock.unlock()
            return result
        }
    }

    private func stats(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return ["n": 0] }
        func pct(_ q: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
        }
        let within60 = values.filter { $0 <= 60.0 }.count
        return [
            "n": values.count,
            "p50_ms": (pct(0.50) * 100).rounded() / 100,
            "p95_ms": (pct(0.95) * 100).rounded() / 100,
            "mean_ms": ((values.reduce(0, +) / Double(values.count)) * 100).rounded() / 100,
            "max_ms": (sorted.last! * 100).rounded() / 100,
            "within_60ms_count": within60,
            "within_60ms_pct": ((Double(within60) * 100.0 / Double(values.count)) * 10).rounded() / 10,
        ]
    }

    /// Side-by-side V4.2 vs V6 benchmark on real AzooKey candidate pools,
    /// gated by `VIME_JA_V6_BENCHMARK=1` (run on physical device in Release `-O`).
    func testV6VsV42DeviceBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_JA_V6_BENCHMARK"] == "1")
        let bundle = Bundle(for: Self.self)
        let sentences: [(context: String, reading: String)] = [
            ("", "きょうはいいてんきですね"),
            ("さっき", "えきまであるいていきました"),
            ("あしたの", "かいぎはじゅうじからです"),
            ("", "おつかれさまでしたまたあした"),
            ("それ", "ほんとうにおもしろいよね"),
            ("らいしゅう", "ともだちとえいがをみにいきます"),
            ("このしりょうを", "かくにんしていただけますか"),
            ("ごごから", "あめがふるかもしれません"),
        ]

        // Precompute AzooKey candidate pools for every keystroke prefix (>= 2 kana) and full sentence.
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: nil, learningEnabled: false)
        struct Step {
            let context: String
            let reading: String
            let snapshots: [CandidateSnapshot]
            let azookeyTexts: [String]
            let isPauseFinal: Bool
        }
        var steps: [Step] = []
        for (si, item) in sentences.enumerated() {
            let chars = Array(item.reading)
            for len in 2...chars.count {
                let sub = String(chars[0..<len])
                var composing = ComposingText()
                composing.insertAtCursorPosition(sub, inputStyle: .direct)
                engine.reconcileContext(item.context)
                let snaps = engine.candidates(for: composing, katakana: false, revision: si * 100 + len,
                                              includeCorrections: false, conversionLength: nil)
                var texts: [String] = []
                var seen: Set<String> = []
                for s in snaps where s.fullConsumption && !s.text.isEmpty && seen.insert(s.text).inserted {
                    texts.append(s.text)
                    if texts.count == JapaneseLanguageModelV6.azookeyLimit { break }
                }
                guard texts.count > 1 else { continue }
                steps.append(Step(context: item.context, reading: sub, snapshots: snaps,
                                  azookeyTexts: texts, isPauseFinal: len == chars.count))
            }
        }
        XCTAssertGreaterThan(steps.count, 40)

        let only = ProcessInfo.processInfo.environment["VIME_JA_V6_BENCHMARK_ONLY"]
        var report: [String: Any] = [
            "keystrokes": steps.count,
            "sentences": sentences.count,
        ]

        if only == nil || only == "v42" {
            let baselineMB = Self.footprintMB()
            let sampler = PeakSampler()
            let loadStart = ProcessInfo.processInfo.systemUptime
            let v42 = try VimeLanguageModel(bundle: .main)
            let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            let afterLoadMB = Self.footprintMB()

            var rerankTimes: [Double] = []
            for step in steps {
                let t0 = ProcessInfo.processInfo.systemUptime
                _ = autoreleasepool {
                    v42.rerank(step.snapshots, context: step.context, katakana: false,
                               maximumCandidates: JapaneseCandidateWorker.initialRankingCandidateLimit,
                               cancelled: { false })
                }
                rerankTimes.append((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
            let sampled = sampler.stop()
            report["v42"] = [
                "model_version": v42.modelVersion,
                "load_ms": (loadMS * 10).rounded() / 10,
                "baseline_mb": (baselineMB * 10).rounded() / 10,
                "after_load_mb": (afterLoadMB * 10).rounded() / 10,
                "peak_mb": (sampled.peakMB * 10).rounded() / 10,
                "min_available_mb": (sampled.minAvailableMB * 10).rounded() / 10,
                "rerank_per_key": stats(rerankTimes),
            ]
        }

        if only == nil || only == "v6" {
            let baselineMB = Self.footprintMB()
            let sampler = PeakSampler()
            let loadStart = ProcessInfo.processInfo.systemUptime
            let v6 = try JapaneseLanguageModelV6(bundle: bundle, preload: true)
            let loadScorePrefixMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            let afterScorePrefixMB = Self.footprintMB()

            // Step 1: AzooKey top-20 rerank per keystroke (before loading `scored`).
            var rerankTimes: [Double] = []
            for step in steps {
                let t0 = ProcessInfo.processInfo.systemUptime
                _ = try autoreleasepool {
                    try v6.rerankAzooKey(reading: step.reading, context: step.context, candidates: step.azookeyTexts)
                }
                rerankTimes.append((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            }
            let afterRerankMB = Self.footprintMB()

            // Step 2: Load `scored` and measure full pipeline (per-key and pause-final).
            let scoredStart = ProcessInfo.processInfo.systemUptime
            try v6.batch.preload(.scored)
            let loadScoredMS = (ProcessInfo.processInfo.systemUptime - scoredStart) * 1000
            let afterScoredMB = Self.footprintMB()

            var fullPerKeyTimes: [Double] = []
            var fullPauseTimes: [Double] = []
            for step in steps {
                let t0 = ProcessInfo.processInfo.systemUptime
                _ = try autoreleasepool {
                    try v6.generateAndMerge(reading: step.reading, context: step.context, azookey: step.azookeyTexts)
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                fullPerKeyTimes.append(elapsed)
                if step.isPauseFinal { fullPauseTimes.append(elapsed) }
            }
            let sampled = sampler.stop()
            report["v6"] = [
                "model_version": v6.modelVersion,
                "load_score_prefix_ms": (loadScorePrefixMS * 10).rounded() / 10,
                "load_scored_ms": (loadScoredMS * 10).rounded() / 10,
                "baseline_mb": (baselineMB * 10).rounded() / 10,
                "after_score_prefix_mb": (afterScorePrefixMB * 10).rounded() / 10,
                "after_rerank_mb": (afterRerankMB * 10).rounded() / 10,
                "after_scored_mb": (afterScoredMB * 10).rounded() / 10,
                "peak_mb": (sampled.peakMB * 10).rounded() / 10,
                "min_available_mb": (sampled.minAvailableMB * 10).rounded() / 10,
                "rerank_per_key": stats(rerankTimes),
                "full_per_key": stats(fullPerKeyTimes),
                "full_pause_once": stats(fullPauseTimes),
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("VIME_JA_V6_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }
}
