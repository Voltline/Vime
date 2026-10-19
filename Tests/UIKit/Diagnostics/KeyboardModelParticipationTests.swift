import XCTest
import UIKit

/// Opt-in scheduling comparison, not a conversion accuracy benchmark. Both
/// arms use the same native/model pipeline and 40 ms first-publication budget.
@MainActor
final class KeyboardModelParticipationTests: XCTestCase {
    func testModelParticipationWithAndWithoutBackgroundMeasurement() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIME_RANKING_AUDIT"] == "1")
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "vime.model-participation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyboardPreferences(defaults: defaults)
        preferences.sound = false; preferences.hapticIntensity = 0
        preferences.phraseSuggestions = false; preferences.candidateRanking = .languageModel
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350),
            session: session, preferences: preferences)
        keyboard.hasFullAccess = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(keyboard)
        window.isHidden = false
        keyboard.layoutIfNeeded()
        let probe = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        probe.allowLanguageModel()
        keyboard.prepareForInput()
        _ = await probe.resourceState()
        await withCheckedContinuation { continuation in
            KeyboardCandidateTextMetrics.fontQueue.async { continuation.resume() }
        }
        var context = "川を渡るための"
        session.leftContextProvider = { context }
        let update = session.onCandidatesChange
        defer {
            session.onCandidatesChange = nil; keyboard.stopInteractions()
            session.releaseInactiveResources(); window.isHidden = true
            KeyboardPerformance.configure(enabled: false)
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        var pressID = 0
        func type(_ character: Character) async throws {
            let ready = expectation(description: "current initial candidate")
            var delivered = false
            session.onCandidatesChange = {
                update?(); keyboard.layoutIfNeeded()
                if session.candidatesAreCurrent, !delivered { delivered = true; ready.fulfill() }
            }
            let region = try XCTUnwrap(surface.regions.first {
                $0.key.accessibilityIdentifier == "vime.key." + String(character)
            })
            let point = CGPoint(x: region.body.midX, y: region.body.midY)
            XCTAssertTrue(surface.beginPress(id: pressID, at: point))
            surface.endPress(id: pressID, at: point); pressID += 1
            await fulfillment(of: [ready], timeout: 5)
            // Drain both executors before reading counts, including a model
            // prediction that was already in progress when the timer fired.
            _ = await probe.resourceState()
        }
        // Exclude cold model initialization from the paired warm-model rate.
        for character in "hashi" { try await type(character) }
        let warmed = await probe.resourceState()
        XCTAssertTrue(warmed.modelLoaded)
        let samples = [("hashi", "川を渡るための"), ("kami", "白い"), ("kisha", "新聞の"),
            ("kaigi", "明日の"), ("shiyou", "この機能を"), ("kaku", "手紙を"),
            ("ame", "今日は"), ("kouen", "日曜日に"), ("seikaku", "彼の"), ("nihongo", "勉強しているのは"),
            ("kikan", "契約の"), ("ishiki", "健康を"), ("koushou", "価格を"), ("kouka", "薬の"),
            ("shikou", "新しい法律を"), ("taishou", "調査の"), ("kanji", "名前の"),
            ("douki", "入社した"), ("shinsei", "休暇を"), ("kousei", "文章の")]
        let longContext = ProcessInfo.processInfo.environment["VIME_RANKING_LONG_CONTEXT"] == "1"
        let passes = longContext ? 6 : 12
        let prefixes = ["明日の予定について友人と相談していたところ、",
            "仕事が終わったら友人と待ち合わせをして週末の旅行についてゆっくり相談するので、",
            "来週の旅行に備えて必要な物を整理しながら現地で何をするか友人と相談していて、まだ決まっていない予定について詳しく話すために、"]
        var rows = [[String: Any]]()
        for pass in 0..<passes {
            let rowStart = rows.count
            for (sample, pair) in samples.enumerated() {
                // Alternate AB / BA to balance model, dictionary, font and
                // thermal warm-up. The second half also evicts the width cache.
                let modes = (pass + sample).isMultiple(of: 2) ? [false, true] : [true, false]
                for background in modes {
                    keyboard.resetComposition()
                    context = (longContext ? prefixes[sample % prefixes.count] : "") + pair.1
                    if pass >= passes / 2 {
                        for entry in 0..<256 {
                            _ = KeyboardCandidateTextMetrics.width(of: "evict-\(pass)-\(sample)-\(background)-\(entry)",
                                font: .systemFont(ofSize: 18))
                        }
                    }
                    session.setCandidatePresentationPreparation { value, first in
                        if background { KeyboardCandidateTextMetrics.prepare(value, first: first) }
                    }
                    for (key, character) in pair.0.enumerated() {
                        KeyboardPerformance.configure(enabled: true, reset: true)
                        try await type(character)
                        let timing = KeyboardPerformance.takeWindowReport()
                        KeyboardPerformance.configure(enabled: false)
                        func count(_ stage: String) -> Int { Int(timing[stage]?["windowCount"] ?? 0) }
                        let eligible = count("candidateModelEligible")
                        let used = count("candidateModelUsed")
                        XCTAssertLessThanOrEqual(used, eligible)
                        XCTAssertEqual(count("inputToCandidateInteractive"), 1)
                        rows.append(["pass": pass, "sample": sample, "key": key,
                            "final_key": key == pair.0.count - 1,
                            "cache": pass < passes / 2 ? "mixed_workload" : "evicted_each_word",
                            "context_chars": VimeLanguageModel.sentenceContext(context).count,
                            "background": background, "eligible": eligible,
                            "window_available": count("candidateModelWindowAvailable"),
                            "scoring_started": count("candidateModelScoringStarted"),
                            "refinements_ready": count("candidateModelRefinementReady"), "used": used,
                            "order_changed": count("candidateModelOrderChanged"),
                            "initial_preparation_expired": count("candidateModelInitialPreparationExpired"),
                            "refinement_preparation_expired": count("candidateModelRefinementPreparationExpired"),
                            "model_queue_wait_ms": timing["modelQueueWait"]?["maxMs"] ?? 0,
                            "candidate_queue_wait_ms": timing["candidateQueueWait"]?["maxMs"] ?? 0,
                            "compute_ms": timing["candidateCompute"]?["maxMs"] ?? 0,
                            "request_to_result_ms": timing["candidateRequestToResult"]?["maxMs"] ?? 0,
                            "refinement_ready_max_ms": timing["candidateModelRefinementReady"]?["maxMs"] ?? 0,
                            "scoring_calls": count("lmCandidateScoring"),
                            "preparation_max_ms": timing["candidatePresentationPreparation"]?["maxMs"] ?? 0,
                            "interactive_ms": timing["inputToCandidateInteractive"]?["maxMs"] ?? 0])
                    }
                    XCTAssertEqual(session.raw, pair.0)
                }
            }
            print("VIME_MODEL_PARTICIPATION_PROGRESS pass=\(pass + 1)/\(passes) rows=\(rows.count)")
            let checkpoint = try JSONSerialization.data(withJSONObject: ["pass": pass,
                "rows": Array(rows[rowStart...])], options: [.sortedKeys])
            print("VIME_MODEL_PARTICIPATION_PASS " + String(decoding: checkpoint, as: UTF8.self))
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "scope": "Release simulator, attached UIKit view, warm model, empty learning history; not gold accuracy",
            "long_context": longContext, "budget_ms": 40, "rows": rows], options: [.sortedKeys])
        print("VIME_MODEL_PARTICIPATION_AUDIT " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "model-participation-audit"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
