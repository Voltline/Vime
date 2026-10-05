import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardIntelligentCandidateTests: XCTestCase {
    private func query(_ raw: String) -> ComposingText {
        var value = ComposingText()
        RomajiConverter.insert(raw.replacingOccurrences(of: "-", with: "ー"), into: &value)
        return value
    }

    private func save<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name + ".json"))
    }

    func testRegressionCorpusAndRawToFinalDiagnostics() throws {
        struct Record: Codable {
            let input: String
            let raw: [CandidateDiagnostic]
            let final: [CandidateDiagnostic]
        }
        let engine = JapaneseCandidateEngine(learningEnabled: false); engine.diagnosticsEnabled = true
        let corpus = [("yo-r", "ヨーロッパ"), ("yo-roppa", "ヨーロッパ"), ("yo-roppajin", "ヨーロッパ人"),
            ("be-to-ben", "ベートーベン"), ("be-to-benn", "ベートーベン"),
            ("ko-hi-", "コーヒー"), ("konpyu-ta-", "コンピューター"), ("piano", "ピアノ"),
            ("kamera", "カメラ"), ("nihongo", "日本語"), ("gakkou", "学校"),
            ("shizuka", "静か"), ("arigatou", "ありがとう"), ("ohayou", "おはよう")]
        var records: [Record] = []
        for (raw, expected) in corpus {
            engine.reset()
            let values = engine.candidates(for: query(raw), revision: 1, includeCorrections: false)
            print("INTELLIGENT_CORPUS \(raw) \(values.prefix(8).map { "\($0.text):\($0.source.rawValue):\($0.features.total)" })")
            XCTAssertEqual(values.first?.text, expected, raw)
            if raw == "yo-roppa" {
                let lexical = try XCTUnwrap(values.first)
                XCTAssertEqual(lexical.source, .conversion)
                XCTAssertTrue(lexical.lexical && lexical.exactReading && lexical.fullConsumption && lexical.learningEligible)
                XCTAssertEqual(values.filter { $0.text == expected }.count, 1)
            }
            records.append(.init(input: raw, raw: engine.rawDiagnostics, final: engine.finalDiagnostics))
        }
        let typo = engine.candidates(for: query("shitsuka"), revision: 2)
        let correction = try XCTUnwrap(typo.first { $0.text == "静か" && $0.source == .typoCorrection })
        XCTAssertEqual(correction.correction?.originalInput, "shitsuka")
        XCTAssertEqual(correction.correction?.correctedReading, "しずか")
        XCTAssertTrue(correction.fullConsumption)
        XCTAssertFalse(correction.exactReading)
        records.append(.init(input: "shitsuka", raw: engine.rawDiagnostics, final: engine.finalDiagnostics))
        XCTAssertFalse(engine.candidates(for: query("shizuka"), revision: 3).contains { $0.correction != nil })
        try save(records, name: "intelligent-candidates-after")
    }

    func testProgressiveInputContinuityAndCompleteWordExtension() throws {
        let engine = JapaneseCandidateEngine(learningEnabled: false)
        var value = ComposingText()
        for (revision, c) in "yo-roppa".enumerated() {
            RomajiConverter.insert(String(c).replacingOccurrences(of: "-", with: "ー"), into: &value)
            let candidates = engine.candidates(for: value, revision: revision, includeCorrections: false)
            if revision == 3 || revision == 7 { XCTAssertEqual(candidates.first?.text, "ヨーロッパ") }
        }
        let exact = engine.candidates(for: value, revision: 9, includeCorrections: false)
        let index = try XCTUnwrap(exact.firstIndex { $0.text == "ヨーロッパ人" })
        XCTAssertGreaterThan(index, 0)
        RomajiConverter.insert("jin", into: &value)
        XCTAssertEqual(engine.candidates(for: value, revision: 10, includeCorrections: false).first?.text, "ヨーロッパ人")
    }

    func testScriptPolicyDeduplicationAndContinuityCannotFreezeWrongResult() throws {
        func snapshot(_ surface: String, ruby: String, rank: Int = 0) -> CandidateSnapshot {
            let c = Candidate(text: surface, value: -10, composingCount: .inputCount(8), lastMid: MIDData.一般.mid,
                data: [.init(word: surface, ruby: ruby, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: -10)])
            return .init(candidate: c, revision: 1, source: .conversion, remainingComposition: ComposingText(),
                originalInputCount: 8, consumedInputCount: 8, queryReading: ruby, engineRank: rank)
        }
        let mixed = snapshot("べートーベン", ruby: "ベートーベン")
        let lexical = snapshot("ベートーベン", ruby: "ベートーベン", rank: 1)
        let ranked = CandidateReranker().rank([mixed, lexical], input: "be-to-benn", katakana: false, previous: nil)
        XCTAssertEqual(ranked.first?.text, lexical.text)
        XCTAssertLessThan(try XCTUnwrap(ranked.last?.features.script), 0)
        for surface in ["カタカナ語", "日本語を", "おニュー"] {
            let ranked = CandidateReranker().rank([snapshot(surface, ruby: "ニホンゴ")], input: "nihongo", katakana: false, previous: nil)
            XCTAssertEqual(ranked.first?.features.script, 0)
        }
        let differentReading = CandidateReranker().rank([
            snapshot("おニュー", ruby: "オニュウ"), snapshot("オニュー", ruby: "オニュー")
        ], input: "onyuu", katakana: false, previous: nil)
        XCTAssertEqual(differentReading.first { $0.text == "おニュー" }?.features.script, 0,
            "An attested katakana surface with another reading cannot penalize a lexical spelling")
        let previous = CandidateContinuity(surface: mixed.text, reading: mixed.reading, input: "be-to-")
        XCTAssertEqual(CandidateReranker().rank([mixed, lexical], input: "be-to-benn", katakana: false, previous: previous).first?.text, lexical.text)
    }

    func testLearningConfirmationPersistenceAndClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = KeyboardSession(memoryDirectoryURL: directory)
        _ = session.type("hashi")
        let eligible = session.candidateSnapshots.enumerated().filter { $0.element.learningEligible && $0.element.exactReading }
        let choice = try XCTUnwrap(eligible.dropFirst(2).first)
        let target = choice.element.text
        let initial = choice.offset
        var ranks = [initial]
        for _ in 0..<8 {
            let index = try XCTUnwrap(session.candidates.firstIndex(of: target))
            XCTAssertEqual(session.choose(index), [.insert(target)])
            session.reset(); _ = session.type("hashi")
            ranks.append(try XCTUnwrap(session.candidates.firstIndex(of: target)))
        }
        let reloaded = KeyboardSession(memoryDirectoryURL: directory)
        _ = reloaded.type("hashi")
        let persisted = try XCTUnwrap(reloaded.candidates.firstIndex(of: target))
        print("INTELLIGENT_LEARNING target=\(target) ranks=\(ranks) reloaded=\(persisted)")
        XCTAssertLessThan(try XCTUnwrap(ranks.last), initial)
        XCTAssertLessThan(persisted, initial)
        XCTAssertTrue(reloaded.candidateSnapshots[persisted].hasLearningEvidence)
        reloaded.clearLearning(); _ = reloaded.type("hashi")
        XCTAssertFalse(reloaded.candidateSnapshots.contains { $0.hasLearningEvidence })
        let cleared = KeyboardSession(memoryDirectoryURL: directory)
        _ = cleared.type("hashi")
        XCTAssertFalse(cleared.candidateSnapshots.contains { $0.hasLearningEvidence })
        struct LearningRecord: Codable { let initial: Int; let ranks: [Int]; let persisted: Int }
        try save(LearningRecord(initial: initial, ranks: ranks, persisted: persisted), name: "intelligent-learning")
    }

    func testWorkerLearningAndSupersededContextRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let worker = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        func request(_ worker: JapaneseCandidateWorker, revision: Int) async -> [CandidateSnapshot] {
            await withCheckedContinuation { continuation in
                worker.candidates(for: query("hashi"), katakana: false, revision: revision,
                    leftContext: nil, continuity: nil) { values, _, supplementary in
                    if !supplementary { continuation.resume(returning: values) }
                }
            }
        }
        let initial = await request(worker, revision: 1)
        let choice = try XCTUnwrap(initial.enumerated().filter { $0.element.learningEligible && $0.element.exactReading }.dropFirst(2).first)
        worker.complete(choice.element); worker.reset()
        let learned = await request(worker, revision: 2)
        XCTAssertLessThan(try XCTUnwrap(learned.firstIndex { $0.text == choice.element.text }), choice.offset)
        let rebuilt = JapaneseCandidateWorker(memoryDirectoryURL: directory)
        let persisted = await request(rebuilt, revision: 3)
        XCTAssertTrue(persisted.contains { $0.text == choice.element.text && $0.hasLearningEvidence })

        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
        var left: String? = "昨日"
        session.leftContextProvider = { left }
        _ = session.type("hashi")
        let previousRevision = session.revision
        session.reset() // External caret/document change invalidates old context and revision.
        left = "プログラムを"
        let current = expectation(description: "Only reconciled context is published")
        session.onCandidatesChange = {
            XCTAssertGreaterThan(session.revision, previousRevision)
            XCTAssertTrue(session.candidateSnapshots.allSatisfy { $0.revision == session.revision })
            current.fulfill()
        }
        _ = session.type("kaku")
        await fulfillment(of: [current], timeout: 10)
        session.onCandidatesChange = nil; session.reset()
    }

    func testHostContextDifferencesAndReconciliation() throws {
        struct Record: Codable { let context: String; let input: String; let candidates: [CandidateDiagnostic] }
        let engine = JapaneseCandidateEngine(learningEnabled: false); engine.diagnosticsEnabled = true
        var records: [Record] = []
        var changed = false
        for reading in ["hashi", "kaku", "kami", "kikan", "shizuka"] {
            var orders: [[String]] = []
            for context in ["昨日", "プログラムを", "ヨーロッパで"] {
                engine.reset(); engine.reconcileContext(context)
                let values = engine.candidates(for: query(reading), revision: 1, includeCorrections: false)
                orders.append(values.map(\.text))
                print("INTELLIGENT_CONTEXT \(context) \(reading) \(values.prefix(5).map { "\($0.text):\($0.features.context)" })")
                records.append(.init(context: context, input: reading, candidates: engine.finalDiagnostics))
            }
            changed = changed || Set(orders).count > 1
        }
        XCTAssertTrue(changed, "Dictionary connection context must produce an actual ranking difference")
        engine.reconcileContext(nil)
        let cleared = engine.candidates(for: query("hashi"), revision: 2, includeCorrections: false)
        XCTAssertTrue(cleared.allSatisfy { $0.features.context == 0 })
        let fresh = JapaneseCandidateEngine(learningEnabled: false).candidates(for: query("hashi"), revision: 2, includeCorrections: false)
        XCTAssertEqual(cleared.map(\.text), fresh.map(\.text))
        try save(records, name: "intelligent-context")
    }

    func testWarmConversionRerankingTypoAndContextProfile() throws {
        let engine = JapaneseCandidateEngine(learningEnabled: false)
        let words = ["yo-r", "yo-roppa", "yo-roppajin", "be-to-ben", "shizuka", "shitsuka", "nihongo", "kikoro", "noboru"]
        defer { KeyboardPerformance.configure(enabled: false) }
        for pass in 0..<4 {
            if pass == 1 { KeyboardPerformance.configure(enabled: true, reset: true) }
            for word in words {
                engine.reset()
                engine.reconcileContext("プログラムを")
                let values = engine.candidates(for: query(word), revision: pass)
                XCTAssertFalse(values.isEmpty)
            }
        }
        let report = KeyboardPerformance.report()
        for stage in ["baseConversion", "candidateReranking", "classicTypo", "contextEvaluation"] {
            XCTAssertNotNil(report[stage])
        }
        try save(report, name: "intelligent-candidates-performance")
        print("INTELLIGENT_PERFORMANCE \(report)")
    }
}
