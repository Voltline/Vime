import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

/// Authored contrast probes for personal-memory interference, not a blind benchmark.
@MainActor
final class KeyboardPersonalizationReplayTests: XCTestCase {
    struct Probe {
        let id: String
        let raw: String
        let reading: String
        let context: String
        let target: String
        let habitContext: String
        let habit: String
    }
    private let probes: [Probe] = [
        .init(id: "bridge", raw: "hashi", reading: "ハシ", context: "川を渡るための", target: "橋", habitContext: "食事に使う", habit: "箸"),
        .init(id: "chopsticks", raw: "hashi", reading: "ハシ", context: "食事に使う", target: "箸", habitContext: "川を渡るための", habit: "橋"),
        .init(id: "paper", raw: "kami", reading: "カミ", context: "プリンターに入れる白い", target: "紙", habitContext: "美容院で切った", habit: "髪"),
        .init(id: "hair", raw: "kami", reading: "カミ", context: "美容院で切った", target: "髪", habitContext: "プリンターに入れる白い", habit: "紙")
    ]

    func testContextContrastAfterLearningAnOppositeHabit() throws {
        let model = try VimeLanguageModel()
        var baselineHits = 0, learnedHits = 0, frozen = 0
        for probe in probes {
            let directory = isolatedLearningDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var input = ComposingText(); RomajiConverter.insert(probe.raw, into: &input)
            let baselineEngine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: false)
            baselineEngine.reconcileContext(probe.context)
            let baseline = model.rerank(baselineEngine.candidates(for: input, revision: 1, includeCorrections: false),
                context: probe.context, katakana: false, cancelled: { false })
            if baseline.first?.text == probe.target { baselineHits += 1 }
            let memory = CandidatePreferenceMemory(directory: directory)
            let now = Date()
            for index in 0..<20 {
                for scope in ["choice", "conversion", "wordChoice"] {
                    memory.record(reading: probe.reading, surface: probe.habit, context: probe.habitContext,
                        scope: scope, now: now.addingTimeInterval(Double(index) * 0.01))
                }
            }
            memory.flush()
            let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
            engine.reconcileContext(probe.context)
            let values = engine.candidates(for: input, revision: 2, includeCorrections: false)
            let plan = CandidateCompetitionPolicy.plan(values, katakana: false)
            XCTAssertEqual(values.first?.text, probe.habit, "The learned dictionary fallback is retained")
            XCTAssertFalse(try XCTUnwrap(values.first).personalPreferenceProtectsOrder)
            XCTAssertEqual(values.first?.modelPreferenceScoreLimit, CandidatePreferenceMemory.Policy.maximumBackoffModelScore)
            XCTAssertFalse(plan.slots.isEmpty)
            if plan.slots.isEmpty { frozen += 1 }
            let ranked = model.rerank(values, context: probe.context, katakana: false, cancelled: { false })
            if ranked.first?.text == probe.target { learnedHits += 1 }
            let likelihood = try model.scores(context: probe.context, candidates: [probe.target, probe.habit])
            print("PERSONAL_CONTEXT_PROBE id=\(probe.id) baselineHit=\(baseline.first?.text == probe.target) learnedHit=\(ranked.first?.text == probe.target) planned=\(plan.slots.count) leaderBonus=\(values.first?.userPreferenceScore ?? 0) leaderConfidence=\(values.first?.userPreferenceConfidence ?? 0) modelMargin=\(likelihood[0] - likelihood[1])")
            XCTAssertEqual(ranked.first?.text, probe.target, probe.id)
            // Two verified choices establish this context without erasing the
            // independently confirmed opposite spelling in its original context.
            for revision in 3...4 {
                engine.reset(); engine.reconcileContext(probe.context)
                let current = engine.candidates(for: input, revision: revision, includeCorrections: false)
                let index = try XCTUnwrap(current.firstIndex { $0.text == probe.target })
                let event = CandidateLearningFeedback(id: UUID(), kind: .explicitCandidate, rank: index,
                    context: probe.context, selectedAt: now.addingTimeInterval(Double(revision)))
                engine.stageSelection(current[index], event: event); engine.resolveFeedback(event.id, accepted: true)
            }
            let restored = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: true)
            for (context, expected) in [(probe.context, probe.target), (probe.habitContext, probe.habit)] {
                restored.reset(); restored.reconcileContext(context)
                let local = restored.candidates(for: input, revision: 5, includeCorrections: false)
                XCTAssertEqual(local.first?.text, expected)
                XCTAssertTrue(try XCTUnwrap(local.first).personalPreferenceProtectsOrder)
                XCTAssertTrue(CandidateCompetitionPolicy.plan(local, katakana: false).slots.isEmpty)
            }
        }
        print("PERSONAL_CONTEXT_SUMMARY probes=\(probes.count) baselineHits=\(baselineHits) learnedHits=\(learnedHits) frozen=\(frozen)")
        XCTAssertEqual(baselineHits, 4)
        XCTAssertEqual(learnedHits, 4)
        XCTAssertEqual(frozen, 0)
    }

    func testProductionWorkerUsesContextModelAfterEachKeyDespiteGlobalHabit() async throws {
        let probe = probes[0], directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = CandidatePreferenceMemory(directory: directory)
        for _ in 0..<20 {
            for scope in ["conversion", "choice", "wordChoice"] {
                memory.record(reading: probe.reading, surface: probe.habit, context: probe.habitContext, scope: scope)
            }
        }
        memory.flush()
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        worker.allowLanguageModel()
        func initial(_ raw: String, revision: Int) async -> ([CandidateSnapshot], CandidatePipelineTrace) {
            var input = ComposingText(); RomajiConverter.insert(raw, into: &input)
            let trace = CandidatePipelineTrace(revision: revision, references: [probe.target], consumedInputCount: input.input.count)
            let ready = expectation(description: "worker revision \(revision)")
            var result: [CandidateSnapshot] = []
            worker.candidates(for: input, katakana: false, revision: revision, leftContext: probe.context,
                continuity: nil, ranking: .languageModel, trace: trace) { values, _, supplementary in
                    guard !supplementary else { return }
                    result = values; ready.fulfill()
                }
            await fulfillment(of: [ready], timeout: 5)
            return (result, trace)
        }
        _ = await initial(probe.raw, revision: 1)
        let state = await worker.resourceState()
        XCTAssertTrue(state.modelLoaded)
        worker.reset()
        for (index, raw) in ["h", "ha", "has", "hash", "hashi"].enumerated() {
            let (values, trace) = await initial(raw, revision: index + 2)
            if raw == probe.raw {
                XCTAssertEqual(values.first?.text, probe.target)
                let published = trace.snapshot()
                XCTAssertTrue(published.modelUsed)
                XCTAssertEqual(published.modelGate, .ready)
                XCTAssertEqual(published[.initial]?.referenceRank, 1)
                _ = await worker.resourceState()
                XCTAssertEqual(trace.snapshot()[.initial], published[.initial])
            }
        }
        worker.releaseInactiveResources(); _ = await worker.resourceState()
    }
}
