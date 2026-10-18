import XCTest
import UIKit
import KanaKanjiConverterModuleWithDefaultDictionary

/// Opt-in latency comparison of the actual candidate view and asynchronous
/// session. These prompts exercise behavior, not conversion accuracy.
@MainActor
final class KeyboardContextPerformanceTests: XCTestCase {
    func testCandidateWidthColdPaths() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_INPUT_AUDIT"] == "1")
        KeyboardCandidateTextMetrics.prepareFonts()
        await withCheckedContinuation { continuation in
            KeyboardCandidateTextMetrics.fontQueue.async { continuation.resume() }
        }
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory); KeyboardPerformance.configure(enabled: false) }
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory)
        let words = ["nihongo", "shizuka", "shitsuka", "desu", "dedu", "yo-roppa", "be-to-ben", "tennanhantenn",
            "watashihanihongowobenkyoushiteimasu", "arigatou", "gakkou", "konpyu-ta"]
        var revision = 0
        for word in words {
            engine.reset()
            var query = ComposingText()
            for character in word {
                RomajiConverter.insert(String(character), into: &query); revision += 1
                let values = engine.candidates(for: query, revision: revision, includeCorrections: false)
                for (index, value) in values.enumerated() {
                    let presentation = value.presentation
                    for (text, font) in [(presentation.text, UIFont.systemFont(ofSize: 18, weight: index == 0 ? .medium : .regular)),
                        (presentation.annotation ?? "", UIFont.systemFont(ofSize: 10))] where !text.isEmpty {
                        KeyboardPerformance.configure(enabled: true, reset: true)
                        let start = ProcessInfo.processInfo.systemUptime
                        _ = KeyboardCandidateTextMetrics.width(of: text, font: font)
                        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        if ms > 2 {
                            // Fixed synthetic prompts only; production timings never include host text.
                            print("VIME_WIDTH_COLD_PATH \(word) \(text) \(font.pointSize) \(ms) \(KeyboardPerformance.report())")
                        }
                        KeyboardPerformance.configure(enabled: false)
                    }
                }
            }
        }
    }

    func testContextualInputLatency() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_INPUT_AUDIT"] == "1")
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        probe.disableLanguageModel(); probe.allowLanguageModel()
        _ = await probe.resourceState()
        let suite = "vime.context-performance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyboardPreferences(defaults: defaults)
        preferences.sound = false; preferences.hapticIntensity = 0
        preferences.phraseSuggestions = false
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350),
            session: session, preferences: preferences)
        keyboard.hasFullAccess = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(keyboard)
        window.isHidden = false
        keyboard.layoutIfNeeded()
        keyboard.prepareForInput()
        // An appearing keyboard can prepare while UIKit performs its show
        // transition. Fence preparation without loading the language model.
        let prepared = expectation(description: "visible keyboard resources prepared")
        JapaneseCandidateWorker.candidateQueue.async { prepared.fulfill() }
        await fulfillment(of: [prepared], timeout: 5)
        await withCheckedContinuation { continuation in
            KeyboardCandidateTextMetrics.fontQueue.async { continuation.resume() }
        }
        var context = ""
        session.leftContextProvider = { context }
        let update = session.onCandidatesChange
        defer {
            session.onCandidatesChange = nil; keyboard.stopInteractions()
            session.releaseInactiveResources(); window.isHidden = true
            KeyboardPerformance.configure(enabled: false)
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        let samples = [("hashi", "川を渡るための"), ("kami", "白い"), ("kisha", "新聞の"),
            ("kaigi", "明日の"), ("shiyou", "この機能を"), ("kaku", "手紙を"),
            ("ame", "今日は"), ("kouen", "日曜日に"), ("seikaku", "彼の"), ("nihongo", "勉強しているのは")]
        var reports = [[String: Any]]()
        var pressID = 0
        for (name, ranking, useContext, passes) in [
            ("first_context_word", CandidateRankingMode.languageModel, true, 1),
            ("warm_context", .languageModel, true, 3),
            ("warm_no_context", .languageModel, false, 3),
            ("engine_context", .engine, true, 3),
            ("long_context", .languageModel, true, 1)
        ] {
            preferences.candidateRanking = ranking
            keyboard.reloadPreferences()
            probe.allowLanguageModel()
            KeyboardPerformance.configure(enabled: true, reset: true)
            var inputCount = 0
            var completedWords = 0
            var publicationCount = 0
            var firstOrders = [[String]]()
            let started = ProcessInfo.processInfo.systemUptime
            let cases = name == "first_context_word" ? Array(samples.prefix(1)) : name == "long_context" ? [
                ("watashihanihongowobenkyoushiteimasu", "今の勉強について、"),
                ("ashitanokaigidesetsumeisurutameniwatashihanihongonosiryouwojunbishiteimasu", "仕事の予定は、")
            ] : samples
            for _ in 0..<passes {
                for (word, left) in cases {
                    keyboard.resetComposition()
                    context = useContext ? left : ""
                    for character in word {
                        let ready = expectation(description: "\(name) current candidate")
                        var delivered = false
                        session.onCandidatesChange = {
                            update?()
                            keyboard.layoutIfNeeded()
                            if session.candidatesAreCurrent, !delivered {
                                delivered = true; publicationCount += 1; ready.fulfill()
                            }
                        }
                        let region = try XCTUnwrap(surface.regions.first {
                            $0.key.accessibilityIdentifier == "vime.key." + String(character)
                        })
                        let point = CGPoint(x: region.body.midX, y: region.body.midY)
                        XCTAssertTrue(surface.beginPress(id: pressID, at: point))
                        surface.endPress(id: pressID, at: point)
                        pressID += 1; inputCount += 1
                        await fulfillment(of: [ready], timeout: 5)
                    }
                    XCTAssertEqual(session.raw, word)
                    XCTAssertFalse(session.candidates.isEmpty)
                    firstOrders.append(Array(session.candidates.prefix(3)))
                    completedWords += 1
                }
            }
            XCTAssertEqual(publicationCount, inputCount)
            let timing = KeyboardPerformance.takeWindowReport()
            XCTAssertEqual(timing["inputToCandidateInteractive"]?["windowCount"], Double(inputCount))
            reports.append(["scenario": name, "input_count": inputCount, "completed_words": completedWords,
                "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                "timing": timing, "first_orders": firstOrders,
                "footprint_mib": VimeLanguageModel.footprintMB()])
        }
        let data = try JSONSerialization.data(withJSONObject: ["scope": "Release simulator, attached UIKit view; excludes screen scan-out",
            "scenarios": reports], options: [.sortedKeys])
        print("VIME_CONTEXT_INPUT_AUDIT " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "context-input-audit"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testEmptyHistoryContextScoringOverhead() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_INPUT_AUDIT"] == "1")
        let words = ["hashi", "kami", "kisha", "kaigi", "shiyou", "kaku", "ame", "kouen", "seikaku", "nihongo"]
        var reports = [[String: Any]]()
        for learning in [false, true] {
            let directory = isolatedLearningDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: learning)
            var times = [Double]()
            var revision = 0
            for pass in 0..<4 {
                for word in words {
                    engine.reset(); engine.reconcileContext("川を渡るための")
                    var query = ComposingText()
                    for character in word {
                        RomajiConverter.insert(String(character), into: &query)
                        revision += 1
                        let start = ProcessInfo.processInfo.systemUptime
                        let values = engine.candidates(for: query, revision: revision, includeCorrections: false)
                        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                        if pass > 0 { times.append(ms) }
                        XCTAssertFalse(values.isEmpty)
                    }
                }
            }
            let sorted = times.sorted()
            reports.append(["learning_enabled": learning, "count": times.count,
                "mean_ms": times.reduce(0, +) / Double(times.count),
                "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)], "max_ms": sorted.last!])
        }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys])
        print("VIME_EMPTY_HISTORY_SCORING_AUDIT " + String(decoding: data, as: UTF8.self))
    }
}
