import XCTest
import CryptoKit
import KanaKanjiConverterModuleWithDefaultDictionary

/// Opt-in local corpus evaluation. Corpus text and derived results stay outside
/// the repository; the input path is supplied explicitly by the test runner.
@MainActor
final class KeyboardLocalEvaluationTests: XCTestCase {
    private struct Item: Decodable {
        let id: String
        let source_id: String
        let track: String
        let context: String
        let reading: String
        let reference: String
    }
    private struct Ranking: Encodable {
        let rank: Int?
        let first: String
        init(_ values: [CandidateSnapshot], reference: String) {
            rank = values.firstIndex { $0.fullConsumption && $0.text == reference }.map { $0 + 1 }
            first = values.first?.text ?? ""
        }
    }
    private struct Row: Encodable {
        let id: String
        let parent: String
        let track: String
        let reference: String
        let engine: Ranking
        let pureModel: Ranking
        let offlinePolicy: Ranking
        let production: Ranking
        let trace: CandidatePipelineTrace.Snapshot
        let pureSlots: Int
        let rejectedSlots: Int
        let incrementalKeys: Int
        let engineMs: Double
        let productionMs: Double
    }
    private func query(_ reading: String) -> ComposingText {
        var query = ComposingText()
        query.insertAtCursorPosition(reading, inputStyle: .direct)
        return query
    }
    private func dictionaryOrder(_ published: [CandidateSnapshot]) -> [CandidateSnapshot] {
        // The policy preserves every native score feature and writes its entire
        // adjustment into languageModel. Invert that adjustment on the actual
        // published pool; querying the native lattice again can alter N-best ties.
        let restored = published.map { original in
            var value = original; value.features.languageModel = 0; return value
        }
        return restored.sorted {
            if $0.features.total != $1.features.total { return $0.features.total > $1.features.total }
            if $0.engineRank != $1.engineRank { return $0.engineRank < $1.engineRank }
            if $0.text != $1.text { return $0.text < $1.text }
            if $0.consumedInputCount != $1.consumedInputCount { return $0.consumedInputCount > $1.consumedInputCount }
            return $0.source.rawValue < $1.source.rawValue
        }
    }
    private func initial(_ worker: JapaneseCandidateWorker, reading: String, context: String,
                         revision: Int, reference: String, reset: Bool = true) async throws -> ([CandidateSnapshot], CandidatePipelineTrace.Snapshot, Double) {
        if reset { worker.reset() }
        let input = query(reading)
        let trace = CandidatePipelineTrace(revision: revision, references: [reference], consumedInputCount: input.input.count)
        let ready = expectation(description: "local corpus revision \(revision)")
        var published: [CandidateSnapshot]?
        let start = ProcessInfo.processInfo.systemUptime
        var elapsed = 0.0
        worker.candidates(for: input, katakana: false, revision: revision, leftContext: context,
            continuity: nil, ranking: .languageModel, trace: trace) { values, _, supplementary in
                guard !supplementary, published == nil else { return }
                elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                published = values; ready.fulfill()
            }
        await fulfillment(of: [ready], timeout: 30)
        _ = await worker.resourceState()
        return (try XCTUnwrap(published), trace.snapshot(), elapsed)
    }

    func testExplicitLocalCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["VIME_LOCAL_EVALUATION_PATH"] else {
            throw XCTSkip("Supply VIME_LOCAL_EVALUATION_PATH to evaluate a local corpus")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertLessThanOrEqual(data.count, 4 * 1024 * 1024)
        let allItems = try JSONDecoder().decode([Item].self, from: data)
        let incremental = environment["VIME_LOCAL_EVALUATION_INCREMENTAL"] == "1"
        let items = incremental ? allItems.filter { !$0.context.isEmpty } : allItems
        guard !items.isEmpty, items.count <= 2000, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ !$0.reading.isEmpty && !$0.reference.isEmpty && $0.reading.count <= 256 }) else {
            XCTFail("Expected 1...2000 nonempty, uniquely identified local cases"); return
        }
        XCTAssertTrue(try JapaneseUserDictionaryStore().entries().isEmpty, "Evaluation requires an empty user dictionary")
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory.appendingPathComponent("worker"))
        worker.allowLanguageModel()
        _ = try await initial(worker, reading: "はし", context: "川を渡るための", revision: 0, reference: "橋")
        let state = await worker.resourceState()
        XCTAssertTrue(state.modelLoaded)
        let model = try VimeLanguageModel()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print("LOCAL_EVALUATION_MANIFEST cases=\(items.count) sha256=\(digest) model=\(model.modelVersion) input=\(incremental ? "incremental_direct_reading" : "complete_direct_reading") learning=empty publicationWindowMs=\(JapaneseCandidateWorker.initialRankingWindow * 1000)")
        defer { worker.releaseInactiveResources() }
        var revision = 0
        for (offset, item) in items.enumerated() {
            // Measure the production path before separate offline scoring so it
            // receives neither this case's warmed logits nor untimed refinements.
            let publication: ([CandidateSnapshot], CandidatePipelineTrace.Snapshot, Double)
            if incremental {
                worker.reset()
                var prefix = ""
                var final: ([CandidateSnapshot], CandidatePipelineTrace.Snapshot, Double)?
                for key in item.reading {
                    prefix.append(key); revision += 1
                    final = try await initial(worker, reading: prefix, context: item.context,
                        revision: revision, reference: item.reference, reset: false)
                }
                publication = try XCTUnwrap(final)
            } else {
                revision += 1
                publication = try await initial(worker, reading: item.reading,
                    context: item.context, revision: revision, reference: item.reference)
            }
            let (published, trace, productionMs) = publication
            // Repeated native queries can change tied N-best entries even in
            // batch mode. Compare every arm on this actual publication's pool.
            let values = dictionaryOrder(published)
            let engineMs = try XCTUnwrap(trace[.ranked]).elapsedMs
            XCTAssertEqual(Ranking(values, reference: item.reference).rank, trace[.ranked]?.referenceRank,
                "Restored native order must match this request's pre-model trace: \(item.id)")
            XCTAssertEqual(values.count, trace[.ranked]?.count)
            let context = VimeLanguageModel.sentenceContext(item.context)
            let eligible = VimeLanguageModel.rerankingSlots(values, katakana: false)
            var supported: [Int] = []
            for slot in eligible {
                let text = context + values[slot].text
                let ids = try model.tokenizer.encode(text)
                if !ids.isEmpty, ids.count <= VimeLanguageModel.contextLength,
                   try model.tokenizer.decode(ids).utf8.elementsEqual(text.utf8) { supported.append(slot) }
            }
            var pure = values, offline = values
            if supported.count > 1 {
                let sums = try autoreleasepool { try model.scores(context: context, candidates: supported.map { values[$0].text }) }
                let order = sums.indices.sorted { sums[$0] == sums[$1] ? $0 < $1 : sums[$0] > sums[$1] }
                for (slot, index) in zip(supported, order) { pure[slot] = values[supported[index]] }
                if !context.isEmpty {
                    let plan = CandidateCompetitionPolicy.plan(values, katakana: false).slots.filter { supported.contains($0) }
                    if plan.count > 1 {
                        let plannedSums = plan.map { sums[supported.firstIndex(of: $0)!] }
                        offline = CandidateCompetitionPolicy.applying(plannedSums, slots: plan, to: values)
                    }
                }
            }
            let row = Row(id: item.id, parent: item.source_id, track: item.track, reference: item.reference,
                engine: Ranking(values, reference: item.reference), pureModel: Ranking(pure, reference: item.reference),
                offlinePolicy: Ranking(offline, reference: item.reference), production: Ranking(published, reference: item.reference),
                trace: trace, pureSlots: supported.count, rejectedSlots: eligible.count - supported.count,
                incrementalKeys: incremental ? item.reading.count : 0,
                engineMs: engineMs, productionMs: productionMs)
            print("LOCAL_EVALUATION_ROW " + String(decoding: try encoder.encode(row), as: UTF8.self))
            if (offset + 1).isMultiple(of: 25) { print("LOCAL_EVALUATION_PROGRESS \(offset + 1)/\(items.count)") }
            await Task.yield()
        }
    }
}
