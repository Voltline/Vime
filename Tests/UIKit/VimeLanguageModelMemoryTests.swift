import XCTest
import Foundation
import Darwin
import UIKit
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
    /// Complement the fixed-word soak with changing shapes, incremental input,
    /// dictionary coverage, and UIKit caches. Each scenario needs a fresh host.
    func testStepAttributionProfile() async throws {
        let scenario = ProcessInfo.processInfo.environment["VIME_STEP_SCENARIO"] ?? ""
        try XCTSkipUnless(["shapes", "dictionary", "incremental", "expanded", "context", "typing", "ui", "availability", "glyphs"].contains(scenario))
        executionTimeAllowance = 300
        let sampler = VimeMemorySampler()
        defer { sampler.stop() }
        let baseline = VimeMemorySampler.snapshot()
        var stages = [[String: Any]]()
        func measure(_ label: String, inputCount: Int = 0, _ work: () async throws -> Void) async rethrows {
            sampler.reset()
            let before = VimeMemorySampler.snapshot()
            let started = ProcessInfo.processInfo.systemUptime
            try await work()
            try? await Task.sleep(for: .milliseconds(30))
            let after = VimeMemorySampler.snapshot()
            stages.append(["stage": label, "input_count": inputCount, "before": before, "after": after,
                "sampling": sampler.finish(), "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000])
            let beforeMiB = before["physical_mib"] ?? -1, afterMiB = after["physical_mib"] ?? -1
            print("VIME_STEP_CHECKPOINT \(label) input_count=\(inputCount) before=\(beforeMiB) after=\(afterMiB)")
            if ProcessInfo.processInfo.environment["VIME_STEP_HEAP_STAGE"] == label {
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent("vime-step-heap-ready.json")
                if let data = try? JSONSerialization.data(withJSONObject: ["pid": getpid(), "scenario": scenario, "stage": label]) {
                    try? data.write(to: marker, options: .atomic)
                    try? await Task.sleep(for: .seconds(60))
                    try? FileManager.default.removeItem(at: marker)
                }
            }
        }
        if scenario == "shapes" {
            var model: VimeLanguageModel?
            try await measure("model_load") { try autoreleasepool { model = try VimeLanguageModel() } }
            for pass in 0..<2 {
                let lengths = pass == 0 ? Array(1...128) : Array((1...128).reversed())
                for length in lengths {
                    try await measure("shape_\(pass)_T\(length)", inputCount: length) {
                        try autoreleasepool {
                            let lm = try XCTUnwrap(model)
                            let logits = try lm.predict([2] + Array(repeating: 4675, count: length - 1))
                            let probabilities = try VimeLanguageModel.logProbabilities(logits, row: length - 1)
                            XCTAssertEqual(probabilities.count, VimeLanguageModel.vocabulary)
                            XCTAssertTrue(probabilities.allSatisfy(\.isFinite))
                        }
                    }
                }
            }
            try await measure("model_release") { autoreleasepool { model = nil } }
        } else if ["dictionary", "incremental", "expanded", "context"].contains(scenario) {
            let directory = isolatedLearningDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var engine: JapaneseCandidateEngine?
            var model: VimeLanguageModel?
            var revision = 0
            try await measure("engine_init") {
                autoreleasepool { engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: false) }
            }
            if scenario == "incremental" {
                try await measure("model_load") { try autoreleasepool { model = try VimeLanguageModel() } }
                let readings = ["chuugokujinnominasannkonnichiha",
                    "watashihaashitanokaiginisankashimasunodeyoroshikuonegaishimasu",
                    "tennanhantenntoukyounihongonyuuryokushisutemuwotesutoshiteimasu",
                    String(repeating: "ashitanokaiginisankashimasu", count: 5)]
                for (index, reading) in readings.enumerated() {
                    var query = ComposingText()
                    for (offset, character) in reading.enumerated() {
                        query.insertAtCursorPosition(String(character), inputStyle: .roman2kana)
                        revision += 1
                        try await measure("incremental_\(index)_\(offset + 1)", inputCount: query.convertTarget.count) {
                            try autoreleasepool {
                                let current = try XCTUnwrap(engine)
                                let base = current.candidates(for: query, revision: revision, includeCorrections: false)
                                XCTAssertFalse(base.isEmpty)
                                _ = try XCTUnwrap(model).rerank(base, context: "明日の会議について", katakana: false, cancelled: { false })
                            }
                        }
                    }
                    try await measure("corrections_\(index)", inputCount: query.convertTarget.count) {
                        try autoreleasepool {
                            let current = try XCTUnwrap(engine)
                            let base = current.candidates(for: query, revision: revision, includeCorrections: false)
                            _ = current.addingCorrections(to: base, for: query, katakana: false, revision: revision)
                        }
                    }
                    try await measure("expanded_\(index)", inputCount: query.convertTarget.count) {
                        try autoreleasepool {
                            let current = try XCTUnwrap(engine)
                            let base = current.candidates(for: query, revision: revision, includeCorrections: false)
                            let width = current.addingWidthCandidates(to: base, for: query, katakana: false, revision: revision, conversionLength: nil)
                            _ = current.addingPrefixCandidates(to: width, for: query, katakana: false, revision: revision)
                        }
                    }
                    try await measure("reset_\(index)") { engine?.reset(preservingContext: false) }
                }
            } else if scenario == "expanded" {
                for repetitions in [1, 3, 5, 8, 10] {
                    var query = ComposingText()
                    query.insertAtCursorPosition(String(repeating: "ashitanokaiginisankashimasu", count: repetitions), inputStyle: .roman2kana)
                    revision += 1
                    var base = [CandidateSnapshot]()
                    var formatted = [CandidateSnapshot]()
                    try await measure("ordinary_\(repetitions)", inputCount: query.convertTarget.count) {
                        autoreleasepool {
                            base = engine!.candidates(for: query, revision: revision, includeCorrections: false)
                            XCTAssertFalse(base.isEmpty)
                        }
                    }
                    try await measure("width_\(repetitions)", inputCount: query.input.count) {
                        autoreleasepool {
                            formatted = engine!.addingWidthCandidates(to: base, for: query, katakana: false, revision: revision)
                            XCTAssertTrue(formatted.contains { $0.widthVariant == .fullWidthAlphanumeric })
                            XCTAssertTrue(formatted.contains { $0.widthVariant == .halfWidthKatakana })
                        }
                    }
                    try await measure("prefix_\(repetitions)", inputCount: query.convertTarget.count) {
                        autoreleasepool {
                            let expanded = engine!.addingPrefixCandidates(to: formatted, for: query, katakana: false, revision: revision)
                            XCTAssertTrue(expanded.contains { !$0.fullConsumption })
                            print("VIME_STEP_PREFIX_COUNTS repetitions=\(repetitions) candidates=\(expanded.count) remainder_lengths=\(Set(expanded.map { $0.remainingComposition.input.count }).count) input_element_stride=\(MemoryLayout<ComposingText.InputElement>.stride)")
                        }
                    }
                    let prefixStage = try XCTUnwrap(stages.last)
                    let prefixBefore = try XCTUnwrap(prefixStage["before"] as? [String: Double])
                    let prefixAfter = try XCTUnwrap(prefixStage["after"] as? [String: Double])
                    XCTAssertLessThan(try XCTUnwrap(prefixAfter["physical_mib"]) - XCTUnwrap(prefixBefore["physical_mib"]), 6,
                        "Expanded prefix candidates must not retain tens of MiB of duplicated input suffixes")
                    try await measure("corrections_\(repetitions)", inputCount: query.convertTarget.count) {
                        autoreleasepool {
                            _ = engine!.addingCorrections(to: formatted, for: query, katakana: false, revision: revision)
                        }
                    }
                    try await measure("reset_\(repetitions)") {
                        autoreleasepool { base = []; formatted = []; engine?.reset(preservingContext: false) }
                    }
                }
            } else if scenario == "dictionary" {
                let readings = ["ai", "ikimono", "uchuu", "eigyou", "ongaku", "kaisha", "kisha", "kuukou", "keizai", "kousoku",
                    "sakura", "shinbun", "suugaku", "seiji", "sora", "tabemono", "chikyuu", "tsuushin", "tennanhantenn", "toukyou",
                    "natsu", "nihongo", "nuno", "neko", "nomimono", "hashi", "hikari", "fuku", "heiwa", "hon", "matsuri", "mirai",
                    "mukashi", "megane", "mori", "yakusoku", "yuuki", "yokohama", "rainen", "ryokou", "ruikei", "rekishi", "rouryoku", "watashi"]
                for pass in 0..<2 {
                    for (index, reading) in readings.enumerated() {
                        var query = ComposingText(); query.insertAtCursorPosition(reading, inputStyle: .roman2kana)
                        revision += 1
                        try await measure("dictionary_\(pass)_\(index)", inputCount: query.convertTarget.count) {
                            try autoreleasepool {
                                let current = try XCTUnwrap(engine)
                                current.reset(preservingContext: false)
                                XCTAssertFalse(current.candidates(for: query, revision: revision).isEmpty)
                            }
                        }
                    }
                }
            } else {
                try await measure("model_load") { try autoreleasepool { model = try VimeLanguageModel() } }
                let phrases = ["明日の会議では入力システムについて説明します", "中国の皆さんこんにちは日本語の変換を試しています",
                    "東京の駅から電車に乗って学校と会社へ向かいます", "経済と政治のニュースを読んで歴史と数学を勉強します",
                    "春の桜と夏の海と秋の祭りと冬の雪について話します"]
                var document = ""
                for index in 0..<40 {
                    document += phrases[index % phrases.count]
                    let left = document
                    try await measure("context_\(index)", inputCount: min(96, left.count)) {
                        try autoreleasepool {
                            let current = try XCTUnwrap(engine)
                            current.reconcileContext(left)
                            var query = ComposingText(); query.insertAtCursorPosition("hashi", inputStyle: .roman2kana)
                            revision += 1
                            let candidates = current.candidates(for: query, revision: revision)
                            XCTAssertFalse(candidates.isEmpty)
                            _ = try XCTUnwrap(model).rerank(candidates, context: VimeLanguageModel.sentenceContext(left), katakana: false, cancelled: { false })
                            _ = try XCTUnwrap(model).nextWords(prompt: VimeLanguageModel.sentenceContext(left))
                        }
                    }
                    try await measure("context_reset_\(index)") { engine?.reset(preservingContext: false) }
                }
            }
            try await measure("engine_model_release") { autoreleasepool { engine = nil; model = nil } }
        } else if scenario == "typing" {
            let directory = isolatedLearningDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
            session.updateIntelligence(ranking: .languageModel, suggestionsEnabled: true)
            var document = ""
            var keyboard: KeyboardView?
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = UIViewController(); window.makeKeyAndVisible()
            defer { keyboard?.stopInteractions(); session.releaseInactiveResources(); window.isHidden = true }
            try await measure("typing_keyboard_init") {
                keyboard = KeyboardView(frame: CGRect(x: 0, y: 240, width: 440, height: 350), session: session)
                keyboard?.leftContextProvider = { document }
                window.rootViewController?.view.addSubview(try XCTUnwrap(keyboard)); keyboard?.layoutIfNeeded()
            }
            let readings = ["chuugokujinnominasannkonnichiha",
                "watashihaashitanokaiginisankashimasunodeyoroshikuonegaishimasu",
                String(repeating: "ashitanokaiginisankashimasu", count: 5)]
            for pass in 0..<3 {
                for (index, reading) in readings.enumerated() {
                    try await measure("typing_\(pass)_\(index)", inputCount: reading.count) {
                        session.setExpandedCandidates(false)
                        for character in reading {
                            _ = session.type(String(character))
                            try await Task.sleep(for: .milliseconds(15))
                        }
                        let deadline = Date().addingTimeInterval(10)
                        while !session.candidatesAreCurrent && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                        XCTAssertTrue(session.candidatesAreCurrent)
                        XCTAssertFalse(session.candidateSnapshots.isEmpty)
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    try await measure("typing_expanded_\(pass)_\(index)", inputCount: session.raw.count) {
                        session.setExpandedCandidates(true)
                        let deadline = Date().addingTimeInterval(10)
                        while (!session.candidatesAreCurrent || !session.candidateSnapshots.contains { !$0.fullConsumption }) && Date() < deadline {
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        XCTAssertTrue(session.candidatesAreCurrent)
                        XCTAssertTrue(session.candidateSnapshots.contains { !$0.fullConsumption })
                        keyboard?.layoutIfNeeded()
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    try await measure("typing_commit_\(pass)_\(index)") {
                        let choice = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.fullConsumption })
                        let selected = session.candidateSnapshots[choice].text
                        XCTAssertEqual(session.choose(choice), [.insert(selected)])
                        document += selected
                        XCTAssertFalse(session.isComposing)
                        try await Task.sleep(for: .milliseconds(400))
                    }
                }
            }
            try await measure("typing_keyboard_release") {
                keyboard?.releaseInactiveResources(); keyboard?.stopInteractions(); keyboard?.removeFromSuperview(); keyboard = nil
                session.releaseInactiveResources()
                try await Task.sleep(for: .milliseconds(200))
            }
        } else if scenario == "availability" || scenario == "glyphs" {
            for (index, group) in KeyboardSymbolCatalog.emoji.groups.enumerated() {
                var items = [KeyboardSymbolCatalog.Item]()
                try await measure("availability_\(index)", inputCount: group.items.count) {
                    items = await withCheckedContinuation { continuation in
                        KeyboardEmojiAvailability.load(group) { continuation.resume(returning: $0) }
                    }
                    XCTAssertFalse(items.isEmpty)
                }
                if scenario == "glyphs" {
                    try await measure("glyphs_\(index)", inputCount: items.count) {
                        for item in items { autoreleasepool { _ = KeyboardSymbolPanel.EmojiGlyph.image(item.text) } }
                    }
                }
            }
            if scenario == "glyphs" {
                try await measure("raster_cache_clear") { KeyboardSymbolPanel.EmojiGlyph.cache.removeAllObjects() }
            }
        } else {
            let session = KeyboardSession()
            session.candidateRanking = .engine; session.phraseSuggestions = false
            var keyboard: KeyboardView?
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = UIViewController(); window.makeKeyAndVisible()
            defer { keyboard?.stopInteractions(); window.isHidden = true }
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            try await measure("keyboard_init") {
                keyboard = KeyboardView(frame: CGRect(x: 0, y: 240, width: 440, height: 350), session: session)
                window.rootViewController?.view.addSubview(try XCTUnwrap(keyboard)); keyboard?.layoutIfNeeded()
            }
            try await measure("feedback_500_simulator") {
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                for index in 0..<500 {
                    generator.impactOccurred(intensity: 0.6); generator.prepare()
                    if index.isMultiple(of: 20) { try await Task.sleep(for: .milliseconds(10)) }
                }
            }
            try await measure("emoji_open") {
                let current = try XCTUnwrap(keyboard)
                let button = try XCTUnwrap(descendants(current).first { $0.accessibilityLabel == "表情" } as? UIButton)
                button.sendActions(for: .touchUpInside); current.layoutIfNeeded()
            }
            do {
                let panel = try XCTUnwrap(descendants(try XCTUnwrap(keyboard)).compactMap { $0 as? KeyboardSymbolPanel }.first)
                let grid = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
                let categories = descendants(panel).compactMap { $0 as? UIButton }.filter { $0.accessibilityIdentifier?.hasPrefix("vime.symbols.category.") == true }
                XCTAssertGreaterThanOrEqual(categories.count, 10)
                for (index, category) in categories.enumerated() {
                    try await measure("emoji_category_\(index)") {
                        category.sendActions(for: .touchUpInside)
                        let deadline = Date().addingTimeInterval(5)
                        while grid.numberOfItems(inSection: 0) == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
                        let count = grid.numberOfItems(inSection: 0)
                        XCTAssertGreaterThan(count, 0)
                        for item in stride(from: 0, to: count, by: 20) {
                            grid.scrollToItem(at: IndexPath(item: item, section: 0), at: .top, animated: false)
                            grid.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(10))
                        }
                    }
                }
                try await measure("emoji_close") {
                    let close = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.close" } as? UIButton)
                    close.sendActions(for: .touchUpInside); keyboard?.layoutIfNeeded()
                }
            }
            try await measure("keyboard_release") {
                keyboard?.stopInteractions(); keyboard?.removeFromSuperview(); keyboard = nil
            }
        }
        try await measure("idle_1s") { try await Task.sleep(for: .seconds(1)) }
        let hold = min(60, max(0, Int(ProcessInfo.processInfo.environment["VIME_STEP_HOLD_SECONDS"] ?? "0") ?? 0))
        if hold > 0 {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("vime-step-heap-ready.json")
            let ready = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "scenario": scenario])
            try ready.write(to: marker, options: .atomic)
            print("VIME_STEP_HEAP_READY pid=\(getpid()) scenario=\(scenario)")
            try await Task.sleep(for: .seconds(hold))
            try? FileManager.default.removeItem(at: marker)
        }
        if scenario == "glyphs" {
            // Diagnostic control only: distinguish live caches from freed
            // allocator pages. This is not a production memory-pressure fix.
            try await measure("allocator_pressure_relief_control") {
                let released = malloc_zone_pressure_relief(nil, 0)
                print("VIME_STEP_ALLOCATOR_RELEASED bytes=\(released)")
            }
        }
        let report: [String: Any] = ["format": "vime_step_attribution_v1", "scenario": scenario,
            "scope": "optimized simulator test-host components; not physical-device extension",
            "baseline": baseline, "stages": stages, "final": VimeMemorySampler.snapshot()]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("VIME_STEP_AUDIT " + String(decoding: data, as: UTF8.self))
    }

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
            var before = "明日の"
            session.leftContextProvider = { before }
            let readings = ["ekini", "kisha", "hashi", "nihongo", "ashitanokaiginisankashimasu"]
            func cycle(_ index: Int) async throws {
                session.reset()
                before = "明日の"
                let ready = expectation(description: "candidate \(index)")
                var delivered = false
                session.onCandidatesChange = {
                    if session.isComposing && session.candidatesAreCurrent && !delivered { delivered = true; ready.fulfill() }
                }
                _ = session.type(readings[index % readings.count])
                await fulfillment(of: [ready], timeout: 5)
                session.onCandidatesChange = nil
                // Let secondary reranking/corrections finish; do not cancel them at the first publication.
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertFalse(session.candidates.isEmpty)
                let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.fullConsumption })
                let suggestion = session.phraseSuggestions ? expectation(description: "suggestions after real host acknowledgement") : nil
                var suggested = false
                session.onCandidatesChange = {
                    if !session.suggestions.isEmpty && !suggested { suggested = true; suggestion?.fulfill() }
                }
                let edits = session.choose(index)
                for edit in edits {
                    switch edit {
                    case .insert(let text): before += text
                    case .deleteBackward: if !before.isEmpty { before.removeLast() }
                    case .returnKey: before += "\n"
                    case .moveCursor, .deleteToLineStart, .undoLineDeletion:
                        throw NSError(domain: "VimeMemoryAudit.UnexpectedNonTextCommit", code: 1)
                    }
                }
                if let suggestion {
                    await fulfillment(of: [suggestion], timeout: 5)
                    _ = try XCTUnwrap(session.suggestions.first)
                }
                // Preserve the original observation window after publication too:
                // native suggestions can precede the secondary neural request.
                // This is a sampling window, not proof that beam search completed.
                try await Task.sleep(for: .milliseconds(100))
                session.onCandidatesChange = nil
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
            XCTAssertEqual(completedCycles, 81)
            if session.phraseSuggestions { XCTAssertEqual(suggestionCycles, completedCycles, "Every measured suggestion cycle must actually publish") }
            // Rapid edits and backspaces exercise cancellation without retaining old outputs.
            try await measure("rapid_input_cancel_100") {
                for _ in 0..<100 { _ = session.type("a"); _ = session.backspace() }
                session.reset()
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        try await measure("idle_1s") { try await Task.sleep(for: .seconds(1)) }
        #if targetEnvironment(simulator)
        let scope = "optimized iOS Simulator test-host process; separate from keyboard extension"
        #else
        let scope = "optimized physical iPhone test-host process; separate from keyboard extension"
        #endif
        let report: [String: Any] = ["format": "vime_memory_audit_v1", "scenario": scenario,
            "scope": scope, "model_version": "2.1-extend5-step40000-int8-b32-v1",
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "baseline": baseline,
            "stages": stages, "checkpoints": checkpoints, "completed_worker_cycles": completedCycles,
            "cycles_with_published_suggestions": suggestionCycles, "final": VimeMemorySampler.snapshot()]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("VIME_MEMORY_AUDIT " + String(decoding: data, as: UTF8.self))
    }
}
