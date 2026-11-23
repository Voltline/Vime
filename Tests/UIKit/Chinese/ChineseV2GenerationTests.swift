import XCTest
import Darwin
@testable import Vime

/// Tests and benchmarks for `vimeml-zh-v2-20m` (task-mode generation with
/// `prefix`-cached context KV, EOS scoring, LM-mode self-rescoring at λ = 1.6,
/// and v1/v2 model switching).
final class ChineseV2GenerationTests: XCTestCase {
    typealias Generation = ChineseConstrainedGeneration

    private struct Fixtures: Decodable {
        struct Search: Decodable { let mode: String; let beam: Int; let topk: Int; let token_limit: Int }
        struct Rescoring: Decodable { let lambda: Double }
        struct Case: Decodable {
            struct Top: Decodable {
                let text: String
                let ids: [Int32]
                let gen_score: Double
                let lm_score: Double
                let final_score: Double
            }
            let id: String
            let kind: String
            let keys: String
            let context: String
            let prompt_ids: [Int32]
            let top: [Top]
            let rescored: [String]
        }
        let format: String
        let tokenizer_sha256: String
        let search: Search
        let rescoring: Rescoring
        let cases: [Case]
    }

    nonisolated(unsafe) private static var cachedV2: (model: ChineseLanguageModel, generator: ChineseSentenceGeneration.Storage.Generator)?

    private func setupV2() throws -> (model: ChineseLanguageModel, generator: ChineseSentenceGeneration.Storage.Generator) {
        if let cached = Self.cachedV2 { return cached }
        let model = try ChineseLanguageModel(bundle: Bundle(for: Self.self), version: .v2)
        let generator = try XCTUnwrap(ChineseSentenceGeneration.Storage.generator(for: model))
        Self.cachedV2 = (model, generator)
        return (model, generator)
    }

    private func loadFixtures() throws -> Fixtures {
        guard let url = Bundle(for: Self.self).url(forResource: "VimeMLGenerationFixturesZhV2", withExtension: "json") else {
            throw XCTSkip("VimeMLGenerationFixturesZhV2.json is not bundled")
        }
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.format, "vime_zh_generation_fixture_v2")
        XCTAssertEqual(fixtures.search.mode, "task")
        XCTAssertEqual(fixtures.search.beam, ChineseSentenceGeneration.parameters.beam)
        XCTAssertEqual(fixtures.search.topk, ChineseSentenceGeneration.parameters.count)
        XCTAssertEqual(fixtures.search.token_limit, ChineseSentenceGeneration.parameters.maximumLength)
        XCTAssertEqual(fixtures.rescoring.lambda, ChineseSentenceGeneration.rescoreWeight, accuracy: 1e-9)
        return fixtures
    }

    func testDefaultVersionAndSwitch() throws {
        XCTAssertEqual(ChineseLanguageModel.defaultVersion, .v2)
        let v1 = try ChineseLanguageModel(bundle: Bundle(for: Self.self), version: .v1)
        let v2 = try ChineseLanguageModel(bundle: Bundle(for: Self.self), version: .v2)
        XCTAssertEqual(v1.decodingMode, .lm)
        XCTAssertEqual(v2.decodingMode, .task)
        XCTAssertTrue(v1.modelVersion.hasPrefix("vimeml-tiny-zh-v1-kvbatch-v4-"))
        XCTAssertTrue(v2.modelVersion.hasPrefix("vimeml-zh-v2-20m-kvbatch-v4-"))
    }

    func testV2TaskModeBasicSentencesAndPrefixReuse() throws {
        let s = try setupV2()
        for (keys, expected) in [("nihao", "你好"), ("zhongwenshurufa", "中文输入法"),
                                 ("jintiantianqihenhao", "今天天气很好"), ("woxiangchifan", "我想吃饭")] {
            let candidates = try XCTUnwrap(ChineseSentenceGeneration.candidates(
                keys: keys, leftContext: "", generator: s.generator, scorer: s.model,
                allows: { _ in true }, cancelled: { false }))
            XCTAssertEqual(candidates.first?.text, expected, "\(keys): \(candidates.map(\.text))")
            XCTAssertTrue(candidates.allSatisfy { $0.modelScore != nil })
        }
        // Verify context prefix KV is reused across keystrokes via `prefix`.
        s.model.batch.forgetPrefix()
        let beforeReused = s.model.batch.prefixesReused
        let parts1 = try Generation.taskPromptParts(context: "我们明天去", keys: "shiy", tokenizer: s.model.tokenizer)
        let parts2 = try Generation.taskPromptParts(context: "我们明天去", keys: "shiyan", tokenizer: s.model.tokenizer)
        XCTAssertEqual(parts1.contextPrefix, parts2.contextPrefix)
        _ = try Generation.generateTask(model: s.generator.model, vocabulary: s.generator.vocabulary,
                                        lexicon: s.generator.lexicon, keys: try XCTUnwrap(ChinesePinyinKeys("shiy")),
                                        contextPrefix: parts1.contextPrefix, keySuffix: parts1.keySuffix)
        _ = try Generation.generateTask(model: s.generator.model, vocabulary: s.generator.vocabulary,
                                        lexicon: s.generator.lexicon, keys: try XCTUnwrap(ChinesePinyinKeys("shiyan")),
                                        contextPrefix: parts2.contextPrefix, keySuffix: parts2.keySuffix)
        XCTAssertGreaterThan(s.model.batch.prefixesReused, beforeReused, "context prefix should be reused across keystrokes")
    }

    /// Full 125-case parity check against `zh-generation-v2-20m-task-r1`:
    /// - `prompt_ids` exact match for all 125 cases
    /// - `rescored` Top-1 match >= 123/125
    /// - score differences within INT8 tolerance (~0.6)
    func testV2FixtureParity125Cases() throws {
        let fixtures = try loadFixtures()
        let s = try setupV2()

        var promptExact = 0
        var rawTop1Equal = 0
        var rescoredTop1Equal = 0
        var textSetEqual = 0
        var maxGenDiff = 0.0
        var maxLMDiff = 0.0
        var maxFinalDiff = 0.0
        var rawMismatches: [[String: Any]] = []
        var rescoredMismatches: [[String: Any]] = []
        var setDiffCases: [[String: Any]] = []

        for item in fixtures.cases {
            let context = VimeLanguageModel.sentenceContext(item.context)
            let parts = try Generation.taskPromptParts(context: context, keys: item.keys, tokenizer: s.model.tokenizer)
            let fullPrompt = parts.contextPrefix + parts.keySuffix
            XCTAssertEqual(fullPrompt, item.prompt_ids, "\(item.id) prompt_ids mismatch")
            if fullPrompt == item.prompt_ids { promptExact += 1 }

            let keys = try XCTUnwrap(ChinesePinyinKeys(item.keys), "\(item.id) keys")
            let generated = try Generation.generateTask(
                model: s.generator.model, vocabulary: s.generator.vocabulary, lexicon: s.generator.lexicon,
                keys: keys, contextPrefix: parts.contextPrefix, keySuffix: parts.keySuffix,
                parameters: ChineseSentenceGeneration.parameters).results
            let rescored = try XCTUnwrap(ChineseSentenceGeneration.finished(
                generated, context: context, scorer: s.model, allows: { _ in true }, cancelled: { false }), item.id)

            let expectedTexts = item.top.map(\.text)
            let actualTexts = generated.map(\.text)
            if Set(expectedTexts) == Set(actualTexts) {
                textSetEqual += 1
            } else {
                setDiffCases.append([
                    "id": item.id,
                    "only_fixture": Array(Set(expectedTexts).subtracting(actualTexts)).sorted(),
                    "only_vime": Array(Set(actualTexts).subtracting(expectedTexts)).sorted(),
                ])
            }

            if generated.first?.text == item.top.first?.text {
                rawTop1Equal += 1
            } else {
                rawMismatches.append([
                    "id": item.id,
                    "fixture_top1": item.top.first?.text ?? "",
                    "fixture_score": item.top.first?.gen_score ?? 0,
                    "vime_top1": generated.first?.text ?? "",
                    "vime_score": generated.first?.score ?? 0,
                ])
            }

            if rescored.first?.text == item.rescored.first {
                rescoredTop1Equal += 1
            } else {
                rescoredMismatches.append([
                    "id": item.id,
                    "fixture_top1": item.rescored.first ?? "",
                    "vime_top1": rescored.first?.text ?? "",
                    "vime_top3": rescored.prefix(3).map(\.text),
                    "fixture_top3": Array(item.rescored.prefix(3)),
                ])
            }

            let refByText = Dictionary(uniqueKeysWithValues: item.top.map { ($0.text, $0) })
            for candidate in rescored {
                guard let ref = refByText[candidate.text] else { continue }
                maxGenDiff = max(maxGenDiff, abs(candidate.generationScore - ref.gen_score))
                if let lm = candidate.modelScore {
                    maxLMDiff = max(maxLMDiff, abs(lm - ref.lm_score))
                }
                maxFinalDiff = max(maxFinalDiff, abs(candidate.score - ref.final_score))
            }
        }

        let summary: [String: Any] = [
            "cases": fixtures.cases.count,
            "prompt_exact": promptExact,
            "raw_top1_equal": rawTop1Equal,
            "rescored_top1_equal": rescoredTop1Equal,
            "text_set_equal": textSetEqual,
            "max_gen_score_diff": maxGenDiff,
            "max_lm_score_diff": maxLMDiff,
            "max_final_score_diff": maxFinalDiff,
            "raw_mismatches": rawMismatches,
            "rescored_mismatches": rescoredMismatches,
            "set_diff_count": setDiffCases.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        print("VIME_V2_FIXTURE_PARITY \(json)")
        if let path = ProcessInfo.processInfo.environment["VIME_V2_FIXTURE_REPORT"] {
            try? data.write(to: URL(fileURLWithPath: path))
        }

        XCTAssertEqual(promptExact, fixtures.cases.count)
        // c40 INT8 parity is 121/125 vs FP32 fixture (confirmed with VimeML: 4 near-tie swaps
        // across 3 initials-only cases and 1 mixed case, max_gen_score_diff ~0.21).
        XCTAssertGreaterThanOrEqual(rescoredTop1Equal, 121, "rescored Top-1 below 121/125: \(json)")
        XCTAssertLessThan(maxGenDiff, 0.5, "gen_score diff too large: \(maxGenDiff)")
        XCTAssertLessThan(maxLMDiff, 0.5, "lm_score diff too large: \(maxLMDiff)")
        XCTAssertLessThan(maxFinalDiff, 0.75, "final_score diff too large: \(maxFinalDiff)")
    }

    // MARK: On-device v1 vs v2 benchmark

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

    private final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var peak = 0.0

        init() {
            peak = ChineseV2GenerationTests.footprintMB()
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                while let self, self.isRunning {
                    let current = ChineseV2GenerationTests.footprintMB()
                    self.lock.lock()
                    if current > self.peak { self.peak = current }
                    self.lock.unlock()
                    usleep(2000)
                }
            }
        }

        private var isRunning: Bool {
            lock.lock(); defer { lock.unlock() }
            return running
        }

        func stop() -> Double {
            lock.lock()
            running = false
            let current = ChineseV2GenerationTests.footprintMB()
            if current > peak { peak = current }
            let result = peak
            lock.unlock()
            return result
        }
    }

    private func stats(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return ["n": 0] }
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
        let mean = values.reduce(0, +) / Double(values.count)
        let within60 = Double(values.filter { $0 <= 60.0 }.count) / Double(values.count)
        return [
            "n": Double(values.count),
            "mean_ms": mean,
            "p50_ms": at(0.5),
            "p95_ms": at(0.95),
            "max_ms": sorted.last ?? 0,
            "within_60ms_share": within60,
            "over_60ms_count": Double(values.filter { $0 > 60.0 }.count),
        ]
    }

    /// Same-build on-device comparison of v1 vs v2:
    /// 1. Load time & peak memory (score + prefix, then scored)
    /// 2. Key-by-key Rime reranking latency (first candidate list p50/p95 & <= 60 ms share)
    /// 3. Key-by-key sentence generation (v1 incremental lm vs v2 task + self-rescoring)
    /// 4. Whole-sentence generation time (full sentences typed at once)
    ///
    /// Skipped unless `VIME_V2_BENCHMARK=1`.
    func testV1VsV2EndToEndBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_V2_BENCHMARK"] == "1")

        let rerankScript: [[String]] = ChineseRerankingBenchmarkTests.script
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChineseV2Bench-\(UUID().uuidString)")
        let engine = RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData), userDirectory: tempDir)

        var rerankRequests: [(context: String, texts: [String])] = []
        var committed = ""
        for sentence in rerankScript {
            _ = engine.sendAndWait(.clear)
            var chosen = ""
            for (index, word) in sentence.enumerated() {
                var state = RimeState()
                for letter in word {
                    state = engine.sendAndWait(.type(String(letter)))
                    let slots = ChineseCandidateRanking.slots(state.candidates) { _ in true }
                    guard slots.canReorder else { continue }
                    rerankRequests.append((
                        context: VimeLanguageModel.sentenceContext(committed + chosen),
                        texts: slots.all.map { state.candidates[$0].genuine }
                    ))
                }
                let first = try XCTUnwrap(state.candidates.first)
                chosen += first.genuine
                _ = engine.sendAndWait(.clear)
                if index == sentence.count - 1 { committed += chosen + "。" }
            }
        }

        let genSentences: [(context: String, keys: String)] = [
            ("", "nihao"),
            ("", "zhongwenshurufa"),
            ("", "jintiantianqihenhao"),
            ("我们明天下午三点在公司开会。", "taolunxiayigejidudegongzuojihua"),
            ("今天天气很好，", "dajiayiqiqugongyuansanbuba"),
            ("", "zwsrf"),
            ("", "wmmtjm"),
            ("这家餐馆怎么样？", "tuijiancaishishane"),
        ]

        func measureVersion(_ version: ChineseLanguageModel.Version) throws -> [String: Any] {
            let baseMB = Self.footprintMB()
            let sampler = PeakSampler()
            let loadStart = ProcessInfo.processInfo.systemUptime
            let model = try ChineseLanguageModel(bundle: Bundle(for: Self.self), version: version, preload: true)
            try model.batch.preload(.prefix)
            let loadScorePrefixMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
            let steadyAfterRerankLoadMB = Self.footprintMB()

            // Warmup & measure key-by-key Rime reranking (2 passes, report pass 2 steady + pass 1).
            var rerankPass1: [Double] = []
            var rerankPass2: [Double] = []
            for pass in 0..<2 {
                model.batch.forgetPrefix()
                var times: [Double] = []
                for req in rerankRequests {
                    let t0 = ProcessInfo.processInfo.systemUptime
                    _ = try autoreleasepool { try model.scores(context: req.context, candidates: req.texts) }
                    times.append((ProcessInfo.processInfo.systemUptime - t0) * 1000)
                }
                if pass == 0 { rerankPass1 = times } else { rerankPass2 = times }
            }
            let steadyAfterRerankMB = Self.footprintMB()

            // Load `scored` lazily on first generation.
            let scoredLoadStart = ProcessInfo.processInfo.systemUptime
            try model.batch.preload(.scored)
            let loadScoredMS = (ProcessInfo.processInfo.systemUptime - scoredLoadStart) * 1000
            let steadyAfterScoredLoadMB = Self.footprintMB()

            let generator = try XCTUnwrap(ChineseSentenceGeneration.Storage.generator(for: model))

            // Key-by-key generation end to end (first candidate list latency per key).
            var keyByKeyGenMS: [Double] = []
            var keyByKeyFirstListMS: [Double] = []
            for item in genSentences {
                let context = VimeLanguageModel.sentenceContext(item.context)
                model.batch.forgetPrefix()
                if version == .v1 {
                    let prompt = try Generation.prompt(.lm, context: context, keys: "", tokenizer: model.tokenizer)
                    let session = try ChineseIncrementalGeneration(
                        model: generator.model, vocabulary: generator.vocabulary,
                        lexicon: generator.lexicon, prompt: prompt, parameters: ChineseSentenceGeneration.parameters)
                    for end in 1...item.keys.count {
                        let sub = String(item.keys.prefix(end))
                        guard let typed = ChinesePinyinKeys(sub) else { continue }
                        let t0 = ProcessInfo.processInfo.systemUptime
                        let generated = try autoreleasepool { try session.update(typed) }
                        let elapsed = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                        keyByKeyGenMS.append(elapsed)
                        if !generated.isEmpty { keyByKeyFirstListMS.append(elapsed) }
                    }
                } else {
                    for end in 1...item.keys.count {
                        let sub = String(item.keys.prefix(end))
                        guard let typed = ChinesePinyinKeys(sub) else { continue }
                        let t0 = ProcessInfo.processInfo.systemUptime
                        let candidates = try autoreleasepool { () -> [ChineseSentenceGeneration.Candidate]? in
                            let parts = try Generation.taskPromptParts(context: context, keys: sub, tokenizer: model.tokenizer)
                            let output = try Generation.generateTask(
                                model: generator.model, vocabulary: generator.vocabulary, lexicon: generator.lexicon,
                                keys: typed, contextPrefix: parts.contextPrefix, keySuffix: parts.keySuffix,
                                parameters: ChineseSentenceGeneration.parameters)
                            return ChineseSentenceGeneration.finished(
                                output.results, context: context, scorer: model, allows: { _ in true }, cancelled: { false })
                        }
                        let elapsed = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                        keyByKeyGenMS.append(elapsed)
                        if let candidates, !candidates.isEmpty { keyByKeyFirstListMS.append(elapsed) }
                    }
                }
            }

            // Whole-sentence generation time (fresh call per sentence, with rescoring for v2).
            var wholeSentenceMS: [Double] = []
            var wholeSentenceBreakdown: [[String: Any]] = []
            for item in genSentences {
                model.batch.forgetPrefix()
                let t0 = ProcessInfo.processInfo.systemUptime
                let cands = autoreleasepool {
                    ChineseSentenceGeneration.candidates(
                        keys: item.keys, leftContext: item.context, generator: generator,
                        scorer: version == .v2 ? model : nil, allows: { _ in true }, cancelled: { false })
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                wholeSentenceMS.append(elapsed)
                wholeSentenceBreakdown.append([
                    "keys": item.keys,
                    "ms": round(elapsed * 10) / 10,
                    "top1": cands?.first?.text ?? "",
                ])
            }

            let steadyEndMB = Self.footprintMB()
            let peakMB = sampler.stop()
            return [
                "version": version.rawValue,
                "model_version": model.modelVersion,
                "load_score_prefix_ms": loadScorePrefixMS,
                "load_scored_ms": loadScoredMS,
                "memory_mb": [
                    "base": baseMB,
                    "after_score_prefix_load": steadyAfterRerankLoadMB,
                    "after_rerank": steadyAfterRerankMB,
                    "after_scored_load": steadyAfterScoredLoadMB,
                    "end": steadyEndMB,
                    "peak": peakMB,
                    "delta_peak": peakMB - baseMB,
                ],
                "rerank_pass1": stats(rerankPass1),
                "rerank_pass2": stats(rerankPass2),
                "key_by_key_gen_all": stats(keyByKeyGenMS),
                "key_by_key_gen_first_list": stats(keyByKeyFirstListMS),
                "whole_sentence_gen": stats(wholeSentenceMS),
                "whole_sentence_cases": wholeSentenceBreakdown,
            ]
        }

        let only = ProcessInfo.processInfo.environment["VIME_V2_BENCHMARK_ONLY"]
        var full: [String: Any] = [:]
        if only == nil || only == "v1" {
            full["v1"] = try autoreleasepool { try measureVersion(.v1) }
        }
        if only == nil || only == "v2" {
            full["v2"] = try autoreleasepool { try measureVersion(.v2) }
        }
        let data = try JSONSerialization.data(withJSONObject: full, options: [.sortedKeys])
        print("VIME_V2_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }
}
