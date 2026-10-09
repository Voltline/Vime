import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

/// Generated labels are intended readings, not an instruction to override a
/// valid literal interpretation. Generation and dictionary admission are audited separately.
@MainActor
final class KeyboardMixedSoundCorpusTests: XCTestCase {
    private struct Fixture: Decodable {
        let version: Int
        let seedReadings: [String]
        let cases: [Case]
        let normalReadings: [String]
        struct Case: Decodable {
            let id: String
            let input: String
            let expectedReading: String
            let positions: [Int]
            let families: [String]
        }
    }
    private struct Suggestion: Codable {
        let surface: String
        let reading: String
        let rank: Int
        let editCount: Int
        let method: String
    }
    private struct Row: Codable {
        let id: String
        let input: String
        let expectedReading: String
        let positions: [Int]
        let families: [String]
        let normal: Bool
        let pairedRecall: Bool
        let anyCorrectionRecall: Bool
        let outcome: String
        let queries: Int
        let elapsedMs: Double
        let suggestions: [Suggestion]
        let expectedQueries: [CorrectionQueryDiagnostic]
    }
    private struct Report: Encodable {
        let fixtureVersion: Int
        let inputStyle = "directKana"
        let environment = "iOS Simulator, Debug; single pass, no learning or LM"
        let positiveCount: Int
        let pairedRecallCount: Int
        let anyCorrectionRecallCount: Int
        let normalCount: Int
        let normalPairedSuggestionCount: Int
        let normalAnySuggestionCount: Int
        let outcomes: [String: Int]
        let cases: [Row]
    }
    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "MixedSoundCorpus", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.version, 1)
        return fixture
    }
    private func query(_ reading: String) -> ComposingText {
        var query = ComposingText()
        query.insertAtCursorPosition(reading, inputStyle: .direct)
        return query
    }

    func testGeneratedPairsCoverAllSoundFamiliesAndPreserveMetadata() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.cases.count, 108)
        XCTAssertEqual(Set(fixture.seedReadings).count, 24)
        XCTAssertEqual(Set(fixture.cases.map(\.id)).count, fixture.cases.count)
        XCTAssertEqual(Set(fixture.cases.flatMap(\.families)), ["voicing", "affricate", "hbp", "smallKana", "gemination"])
        for example in fixture.cases {
            let original = Array(example.input), expected = Array(example.expectedReading)
            XCTAssertEqual(original.count, expected.count, example.id)
            let differences = original.indices.filter { original[$0] != expected[$0] }
            XCTAssertEqual(differences, example.positions, example.id)
            XCTAssertEqual(differences.count, 2, example.id)
            let pairs = KeyboardCorrectionVariants.phoneticPairs(for: query(example.input), priority: { $0.suggestion.errorCost })
            let value = try XCTUnwrap(pairs.first { $0.reading == example.expectedReading }, example.id)
            XCTAssertEqual(value.suggestion.originalReading, example.input)
            XCTAssertEqual(value.suggestion.originalInput, example.input)
            XCTAssertEqual(value.suggestion.editCount, 2)
            XCTAssertEqual(value.suggestion.rangeUnit, .kanaReading)
            XCTAssertEqual(value.suggestion.soundEdits.map(\.offset), example.positions)
            for edit in value.suggestion.soundEdits {
                XCTAssertEqual(edit.original, String(original[edit.offset]))
                XCTAssertEqual(edit.replacement, String(expected[edit.offset]))
            }
            XCTAssertLessThanOrEqual(pairs.count, KeyboardCorrectionVariants.maximumPhoneticPairs)
        }
        // Cancellation after some exploration must remain bounded and stop expanding.
        var checks = 0
        let stopped = KeyboardCorrectionVariants.phoneticPairs(for: query("でづつぎ"), priority: { $0.suggestion.errorCost },
            cancelled: { checks += 1; return checks > 4 })
        XCTAssertEqual(checks, 5)
        XCTAssertLessThanOrEqual(stopped.count, 4)
    }

    func testDictionaryCorpusAuditAndNormalInputProtection() throws {
        let fixture = try fixture()
        let engine = JapaneseCandidateEngine(learningEnabled: false)
        engine.diagnosticsEnabled = true
        var rows: [Row] = []
        func evaluate(id: String, input: String, expected: String, positions: [Int], families: [String], normal: Bool) -> Row {
            engine.reset()
            let composition = query(input)
            let revision = rows.count + 1
            let base = engine.candidates(for: composition, revision: revision, includeCorrections: false)
            let values = engine.addingCorrections(to: base, for: composition, katakana: false, revision: revision)
            let suggestions = values.enumerated().compactMap { index, value -> Suggestion? in
                guard let correction = value.correction else { return nil }
                XCTAssertEqual(value.revision, revision, id)
                XCTAssertTrue(value.fullConsumption, id)
                XCTAssertEqual(value.consumedInputCount, composition.input.count, id)
                XCTAssertTrue(value.lexical, id)
                if correction.editCount == 2 {
                    XCTAssertEqual(correction.soundEdits.count, 2, id)
                    XCTAssertEqual(Set(correction.soundEdits.map(\.offset)).count, 2, id)
                }
                return Suggestion(surface: value.text, reading: correction.correctedReading,
                    rank: index + 1, editCount: correction.editCount, method: correction.method)
            }
            let queries = engine.correctionQueryDiagnostics.filter { $0.reading == expected }
            let pairHit = suggestions.contains { $0.reading == expected && $0.editCount == 2 }
            let anyHit = suggestions.contains { $0.reading == expected }
            let outcome: String
            if normal { outcome = suggestions.isEmpty ? "normalUnchanged" : "normalSuggestion" }
            else if pairHit { outcome = "pairedRecall" }
            else if queries.contains(where: \.admitted) { outcome = "admittedButNotDisplayed" }
            else if !queries.isEmpty { outcome = "expectedQueriedButRejected" }
            else if engine.lastCorrectionMetrics.budgetExhausted { outcome = "budgetOrQueryLimitBeforeExpected" }
            else { outcome = "notQueried" }
            XCTAssertLessThanOrEqual(engine.lastCorrectionMetrics.queries, JapaneseCandidateEngine.maximumCorrectionQueries, id)
            XCTAssertLessThanOrEqual(engine.lastCorrectionMetrics.variants, KeyboardCorrectionVariants.maximumSearchVariants, id)
            // Keep the actual literal lexical evidence; don't require every noisy
            // input to be corrected merely because the fixture has an intended word.
            if let literal = base.first(where: { $0.learningEligible && $0.exactReading && $0.fullConsumption }) {
                XCTAssertTrue(values.contains { $0.text == literal.text && $0.exactReading && $0.correction == nil }, id)
            }
            return Row(id: id, input: input, expectedReading: expected, positions: positions, families: families,
                normal: normal, pairedRecall: pairHit, anyCorrectionRecall: anyHit, outcome: outcome,
                queries: engine.lastCorrectionMetrics.queries, elapsedMs: engine.lastCorrectionMetrics.elapsedMs,
                suggestions: suggestions, expectedQueries: queries)
        }
        for example in fixture.cases {
            rows.append(evaluate(id: example.id, input: example.input, expected: example.expectedReading,
                positions: example.positions, families: example.families, normal: false))
        }
        for reading in fixture.normalReadings {
            rows.append(evaluate(id: "normal:" + reading, input: reading, expected: reading,
                positions: [], families: [], normal: true))
        }
        let positive = rows.filter { !$0.normal }, normal = rows.filter(\.normal)
        let report = Report(fixtureVersion: fixture.version, positiveCount: positive.count,
            pairedRecallCount: positive.filter(\.pairedRecall).count,
            anyCorrectionRecallCount: positive.filter(\.anyCorrectionRecall).count,
            normalCount: normal.count,
            normalPairedSuggestionCount: normal.filter { $0.suggestions.contains { $0.editCount == 2 } }.count,
            normalAnySuggestionCount: normal.filter { !$0.suggestions.isEmpty }.count,
            outcomes: Dictionary(grouping: positive, by: \.outcome).mapValues(\.count), cases: rows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "mixed-sound-corpus-report"; attachment.lifetime = .keepAlways; add(attachment)
        try data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mixed-sound-corpus-report.json"))
        print("MIXED_SOUND_CORPUS pairs=\(report.pairedRecallCount)/\(report.positiveCount) any=\(report.anyCorrectionRecallCount) normalPairs=\(report.normalPairedSuggestionCount)/\(report.normalCount) normalAny=\(report.normalAnySuggestionCount) outcomes=\(report.outcomes)")
        // Known dictionary anchors remain assertions. Broad corpus recall is a
        // measured result, not a pass threshold fitted after observing this run.
        XCTAssertTrue(positive.contains { $0.input == "がぞぐ" && $0.pairedRecall })
        XCTAssertTrue(positive.contains { $0.input == "だなばだ" && $0.pairedRecall })
        XCTAssertEqual(report.normalPairedSuggestionCount, 0)
    }
}
