import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

/// Locally authored development probes, not an independent accuracy benchmark.
/// Drives the production worker for every key. Untimed scoring is a separate
/// comparison and never counts as a result that reached the first publication.
@MainActor
final class KeyboardCandidateReplayTests: XCTestCase {
    private func query(_ raw: String) -> ComposingText {
        var query = ComposingText(); RomajiConverter.insert(raw, into: &query); return query
    }

    private func initial(_ worker: JapaneseCandidateWorker, query: ComposingText, context: String,
                         trace: CandidatePipelineTrace, ranking: CandidateRankingMode = .languageModel) async -> [CandidateSnapshot] {
        let ready = expectation(description: "initial candidate revision \(trace.revision)")
        var result: [CandidateSnapshot] = []
        worker.candidates(for: query, katakana: false, revision: trace.revision, leftContext: context,
            continuity: nil, ranking: ranking, trace: trace) { values, _, supplementary in
                guard !supplementary else { return }
                result = values; ready.fulfill()
            }
        await fulfillment(of: [ready], timeout: 5)
        return result
    }

    func testNativeOnlyAndSentenceInitialGatesRemainDistinctFromMissingRecall() async {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        for (revision, mode, gate) in [(1, CandidateRankingMode.engine, CandidatePipelineTrace.ModelGate.engineMode),
                                      (2, .languageModel, .noContext)] {
            let query = query("nihongo")
            let trace = CandidatePipelineTrace(revision: revision, references: ["日本語"], consumedInputCount: query.input.count)
            let values = await initial(worker, query: query, context: "", trace: trace, ranking: mode)
            let result = trace.snapshot()
            XCTAssertNotNil(result[.native]?.referenceRank)
            XCTAssertNotNil(result[.pooled]?.referenceRank)
            XCTAssertEqual(result[.initial]?.referenceRank, values.firstIndex { $0.text == "日本語" }.map { $0 + 1 })
            XCTAssertEqual(result.modelGate, gate)
            XCTAssertNil(result[.scored])
            XCTAssertFalse(result.modelUsed)
        }
        worker.releaseInactiveResources(); _ = await worker.resourceState()
    }

    func testBlockedModelRecordsDeadlineWithoutLosingRecallOrRepublishing() async {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        worker.allowLanguageModel()
        let query = query("hashi")
        _ = await initial(worker, query: query, context: "川を渡るための",
            trace: CandidatePipelineTrace(revision: 1, consumedInputCount: query.input.count))
        let warm = await worker.resourceState()
        XCTAssertTrue(warm.modelLoaded)
        worker.reset()
        let entered = expectation(description: "model executor held")
        let release = DispatchSemaphore(value: 0)
        JapaneseCandidateWorker.modelQueue.async {
            entered.fulfill(); _ = release.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [entered], timeout: 2)
        defer { release.signal() }
        let trace = CandidatePipelineTrace(revision: 2, references: ["橋"], consumedInputCount: query.input.count)
        let values = await initial(worker, query: query, context: "川を渡るための", trace: trace)
        let published = trace.snapshot()
        XCTAssertNotNil(published[.pooled]?.referenceRank)
        XCTAssertNotNil(published[.eligible]?.referenceRank)
        XCTAssertNotNil(published[.planned]?.referenceRank)
        XCTAssertEqual(published.modelGate, .deadlineExpired)
        XCTAssertFalse(published.modelUsed)
        XCTAssertNil(published[.scored])
        XCTAssertEqual(published[.initial]?.count, values.count)
        release.signal(); _ = await worker.resourceState()
        XCTAssertEqual(trace.snapshot()[.initial], published[.initial], "Late work must not republish")
        worker.releaseInactiveResources(); _ = await worker.resourceState()
        XCTAssertFalse(trace.snapshot().cancelledBeforePublication, "Normal reset after publication is not a cancelled input")
    }

    func testSupersededQueuedRequestCannotAddStagesToTheNextReplay() async {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        let entered = expectation(description: "candidate executor held")
        let release = DispatchSemaphore(value: 0)
        JapaneseCandidateWorker.candidateQueue.async {
            entered.fulfill(); _ = release.wait(timeout: .now() + 5)
        }
        await fulfillment(of: [entered], timeout: 2)
        defer { release.signal() }
        let stale = CandidatePipelineTrace(revision: 1, references: ["橋"], consumedInputCount: 5)
        var stalePublications = 0
        worker.candidates(for: query("hashi"), katakana: false, revision: 1, leftContext: "", continuity: nil,
            ranking: .engine, trace: stale) { _, _, _ in stalePublications += 1 }
        let currentQuery = query("nihongo")
        let current = CandidatePipelineTrace(revision: 2, references: ["日本語"], consumedInputCount: currentQuery.input.count)
        let ready = expectation(description: "replacement request published")
        worker.candidates(for: currentQuery, katakana: false, revision: 2, leftContext: "", continuity: nil,
            ranking: .engine, trace: current) { _, _, supplementary in
                if !supplementary { ready.fulfill() }
            }
        release.signal()
        await fulfillment(of: [ready], timeout: 5)
        _ = await worker.resourceState()
        XCTAssertEqual(stalePublications, 0)
        XCTAssertTrue(stale.snapshot().cancelledBeforePublication)
        XCTAssertTrue(stale.snapshot().stages.isEmpty)
        XCTAssertEqual(current.snapshot()[.initial]?.referenceRank, 1)
        XCTAssertFalse(current.snapshot().cancelledBeforePublication)
        worker.releaseInactiveResources(); _ = await worker.resourceState()
    }

    func testUnsupportedAlternativeHasItsOwnStageAndCompletedScoresRemainVisible() throws {
        let model = try VimeLanguageModel()
        let surfaces = ["買う", String(repeating: "東京", count: 200), "飲む"]
        let values = surfaces.enumerated().map { index, text in
            CandidateSnapshot(candidate: Candidate(text: text, value: -1, composingCount: .inputCount(3),
                lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false), revision: 1,
                source: .conversion, remainingComposition: .init(), originalInputCount: 3,
                consumedInputCount: 3, queryReading: "ノム", engineRank: index)
        }
        let trace = CandidatePipelineTrace(revision: 1, references: ["飲む"], consumedInputCount: 3)
        let result = model.rerank(values, context: "コーヒーを", katakana: false, trace: trace, cancelled: { false })
        let snapshot = trace.snapshot()
        XCTAssertEqual(snapshot[.validated]?.count, 3)
        XCTAssertEqual(snapshot[.supported]?.count, 2)
        XCTAssertEqual(snapshot[.scored]?.count, 2)
        XCTAssertEqual(snapshot[.scored]?.referenceRank, 2)
        XCTAssertEqual(snapshot[.modelRanked]?.referenceRank, 1)
        XCTAssertNil(snapshot[.initial], "Standalone scoring is not an initial UI publication")
        XCTAssertEqual(result.first?.text, "飲む")
        XCTAssertEqual(result[1].text, surfaces[1], "Unsupported slots keep their original position")
        let unsupported = CandidatePipelineTrace(revision: 1, references: [surfaces[1]], consumedInputCount: 3)
        _ = model.rerank(values, context: "コーヒーを", katakana: false, trace: unsupported, cancelled: { false })
        XCTAssertEqual(unsupported.snapshot()[.validated]?.referenceRank, 2)
        XCTAssertNil(unsupported.snapshot()[.supported]?.referenceRank,
            "Validation rejection differs from a supported candidate missing its scoring deadline")
    }

    func testTracingDoesNotChangeNativeCandidateOrderOrConsumption() {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = JapaneseCandidateEngine(memoryDirectoryURL: directory)
        let traced = JapaneseCandidateEngine(memoryDirectoryURL: directory)
        for (index, raw) in ["hashi", "nanim", "nihongowobenkyou", "ko-hi-"].enumerated() {
            let query = query(raw.replacingOccurrences(of: "-", with: "ー"))
            plain.reset(); traced.reset()
            let trace = CandidatePipelineTrace(revision: index, consumedInputCount: query.input.count)
            let expected = plain.candidates(for: query, revision: index, includeCorrections: false)
            let actual = traced.candidates(for: query, revision: index, includeCorrections: false, trace: trace)
            XCTAssertEqual(actual.map(\.presentation), expected.map(\.presentation), raw)
            XCTAssertEqual(actual.map(\.reading), expected.map(\.reading), raw)
            XCTAssertEqual(trace.snapshot()[.ranked]?.count, actual.count)
        }
    }

    func testReplayCandidateFunnelOnDevelopmentFixtures() async throws {
        struct Fixture: Decodable {
            let id: String, raw: String, context: String, references: Set<String>
        }
        struct Row: Codable {
            let id: String
            let keys: Int
            let published: CandidatePipelineTrace.Snapshot
            let untimed: CandidatePipelineTrace.Snapshot
        }
        struct Report: Codable {
            let scope: String
            let modelVersion: String
            let summary: [String: Double]
            let rows: [Row]
            let performance: [String: [String: Double]]
        }
        var fixtures = [
            Fixture(id: "bridge", raw: "hashi", context: "川を渡るための", references: ["橋"]),
            Fixture(id: "chopsticks", raw: "hashi", context: "食事に使う", references: ["箸"]),
            Fixture(id: "paper", raw: "kami", context: "プリンターに入れる白い", references: ["紙"]),
            Fixture(id: "hair", raw: "kami", context: "美容院で切った", references: ["髪"]),
            Fixture(id: "meeting", raw: "kaigi", context: "明日の", references: ["会議"]),
            Fixture(id: "return", raw: "kaeru", context: "仕事が終わったので家に", references: ["帰る"])
        ]
        // Optional larger LOCAL corpus, supplied explicitly by the test runner.
        // It is not copied into the repository or into the report attachment.
        let fixturePath = ProcessInfo.processInfo.environment["VIME_CANDIDATE_REPLAY_PATH"]
        if let fixturePath {
            let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
            guard data.count <= 4 * 1024 * 1024 else { XCTFail("Local fixture file exceeds 4 MiB"); return }
            fixtures = try JSONDecoder().decode([Fixture].self, from: data)
            guard (1...2000).contains(fixtures.count), Set(fixtures.map(\.id)).count == fixtures.count,
                  fixtures.allSatisfy({ !$0.raw.isEmpty && $0.raw.count <= 128 && !$0.references.isEmpty }) else {
                XCTFail("Supply 1...2000 fixtures with unique IDs, 1...128 input characters and reference surfaces"); return
            }
        }
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        worker.allowLanguageModel()
        _ = await initial(worker, query: query("hashi"), context: "川を渡るための",
            trace: CandidatePipelineTrace(revision: 0, consumedInputCount: 5))
        let warmed = await worker.resourceState()
        XCTAssertTrue(warmed.modelLoaded)
        // Separate untimed reference arm: quality comparison only. This test
        // host owns another model and must not be used as an extension RAM test.
        let model = try VimeLanguageModel()
        let engine = JapaneseCandidateEngine(memoryDirectoryURL: directory)
        var rows: [Row] = []
        var revision = 0
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false); worker.releaseInactiveResources() }
        for fixture in fixtures {
            worker.reset()
            var query = ComposingText()
            var final: CandidatePipelineTrace?
            for key in fixture.raw {
                revision += 1
                RomajiConverter.insert(String(key), into: &query)
                let trace = CandidatePipelineTrace(revision: revision,
                    references: query.input.count == fixture.raw.count ? fixture.references : [],
                    consumedInputCount: query.input.count)
                let values = await initial(worker, query: query, context: fixture.context, trace: trace)
                XCTAssertFalse(values.isEmpty, fixture.id)
                final = trace
            }
            _ = await worker.resourceState()
            KeyboardPerformance.configure(enabled: false)
            engine.reset(); engine.reconcileContext(fixture.context)
            let untimed = CandidatePipelineTrace(revision: revision, references: fixture.references,
                consumedInputCount: query.input.count)
            let base = engine.candidates(for: query, revision: revision, includeCorrections: false, trace: untimed)
            untimed.record(.eligible, values: VimeLanguageModel.rerankingSlots(base, katakana: false).map { base[$0] })
            untimed.record(.planned, values: CandidateCompetitionPolicy.plan(base, katakana: false).slots.map { base[$0] })
            _ = model.rerank(base, context: fixture.context, katakana: false, trace: untimed, cancelled: { false })
            KeyboardPerformance.configure(enabled: true)
            let published = try XCTUnwrap(final).snapshot()
            XCTAssertNotNil(published[.native], fixture.id)
            XCTAssertNotNil(published[.pooled], fixture.id)
            XCTAssertNotNil(published[.ranked], fixture.id)
            XCTAssertNotNil(published[.initial], fixture.id)
            rows.append(Row(id: fixture.id, keys: fixture.raw.count, published: published, untimed: untimed.snapshot()))
        }
        let performance = KeyboardPerformance.report()
        KeyboardPerformance.configure(enabled: false)
        worker.releaseInactiveResources(); _ = await worker.resourceState()
        let stageCoverage: [CandidatePipelineTrace.Stage] = [.native, .pooled, .ranked, .eligible, .planned, .validated, .supported, .scored]
        var summary = Dictionary(uniqueKeysWithValues: stageCoverage.map { stage in
            (stage.rawValue + "ReferenceFound", Double(rows.filter { $0.published[stage]?.referenceRank != nil }.count))
        })
        summary["cases"] = Double(rows.count)
        summary["initialTop1"] = Double(rows.filter { $0.published[.initial]?.referenceRank == 1 }.count)
        summary["initialMRR"] = rows.reduce(0) { $0 + ($1.published[.initial]?.referenceRank.map { 1 / Double($0) } ?? 0) } / Double(rows.count)
        summary["untimedTop1"] = Double(rows.filter { ($0.untimed[.modelRanked] ?? $0.untimed[.ranked])?.referenceRank == 1 }.count)
        summary["modelUsed"] = Double(rows.filter { $0.published.modelUsed }.count)
        summary["top1Improved"] = Double(rows.filter { $0.published.top1Improved }.count)
        summary["top1Regressed"] = Double(rows.filter { $0.published.top1Regressed }.count)
        let report = Report(scope: fixturePath == nil
            ? "six authored development fixtures; production worker per key; untimed arm is separate; not a blind accuracy benchmark"
            : "explicit local fixtures; production worker per key; corpus independence not verified; untimed arm is separate",
            modelVersion: model.modelVersion, summary: summary, rows: rows, performance: performance)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        print("CANDIDATE_FUNNEL_REPLAY " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "candidate-funnel-replay"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
