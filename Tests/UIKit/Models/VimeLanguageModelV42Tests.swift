import XCTest
import CoreML

/// Opt-in V4.2 resource set checked against VimeML Mac Core ML INT8 fixtures.
/// The shipped default stays V2.1; these tests construct `.v42` explicitly.
@MainActor
final class VimeLanguageModelV42Tests: XCTestCase {
    private struct Fixtures: Decodable {
        struct Token: Decodable { let text: String; let ids: [Int32]; let decoded: String }
        struct Score: Decodable { let context: String; let candidates: [String]; let sums: [Double] }
        struct Phrase: Decodable { let prompt: String; let firstText: String; let firstIDs: [Int32]; let firstSum: Double }
        let format: String
        let tokenization: [Token]
        let scoring: [Score]
        let phrases: [Phrase]
    }
    private func fixtures() throws -> Fixtures {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "VimeLMFixturesV42", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }

    func testRuntimePrefersV42AndKeepsV21Fallback() throws {
        XCTAssertEqual(VimeLanguageModel.Variant.runtimePreference, [.v42, .v21])
        XCTAssertEqual(try VimeLanguageModel().variant, .v42)
        XCTAssertEqual(try VimeLanguageModel.runtime().variant, .v42)
        var failed: [VimeLanguageModel.Variant] = []
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try VimeLanguageModel.runtime(bundle: try XCTUnwrap(Bundle(path: empty.path))) { variant, _ in failed.append(variant) })
        XCTAssertEqual(failed, [.v42, .v21], "Every variant is tried in order before dictionary fallback")
    }

    func testLoadsV42IdentityAndExplicitV21() throws {
        let v42 = try VimeLanguageModel(variant: .v42)
        XCTAssertEqual(v42.variant, .v42)
        XCTAssertEqual(v42.vocabularySize, 8192)
        XCTAssertEqual(v42.modelVersion, "4.2-epoch20-step1081942-int8-b32-v1")
        let logits = try v42.predict([2] + (try v42.tokenizer.encode("明日の会議")))
        XCTAssertEqual(logits.shape.map(\.intValue).last, 8192)
        XCTAssertEqual(try VimeLanguageModel.logProbabilities(logits, row: 0).count, 8192)
        XCTAssertThrowsError(try v42.predict([2, 8192]))
        let v21 = try VimeLanguageModel(variant: .v21)
        XCTAssertEqual(v21.variant, .v21)
        XCTAssertEqual(v21.vocabularySize, VimeLanguageModel.vocabulary)
    }

    func testNativeSentencePieceMatchesFrozenV4Corpus() throws {
        let lm = try VimeLanguageModel(variant: .v42)
        let data = try fixtures()
        XCTAssertEqual(data.format, "vime_client_fixtures_v4")
        XCTAssertGreaterThan(data.tokenization.count, 1000)
        for item in data.tokenization {
            XCTAssertEqual(try lm.tokenizer.encode(item.text), item.ids, item.text)
            XCTAssertEqual(try lm.tokenizer.decode(item.ids), item.decoded, item.text)
        }
    }

    func testJointSuffixScoresMatchMacV42INT8() throws {
        let lm = try VimeLanguageModel(variant: .v42)
        let corpus = try fixtures().scoring
        XCTAssertFalse(corpus.isEmpty)
        for item in corpus {
            let actual = try lm.scores(context: item.context, candidates: item.candidates)
            XCTAssertEqual(actual.count, item.sums.count)
            for (value, reference) in zip(actual, item.sums) { XCTAssertEqual(value, reference, accuracy: 0.002, item.context) }
            let cached = try lm.scores(context: item.context, candidates: item.candidates,
                                       conversionCache: VimeLanguageModel.ConversionScoreCache())
            for (value, reference) in zip(cached, item.sums) { XCTAssertEqual(value, reference, accuracy: 0.002) }
        }
    }

    func testNativeBeamMatchesTwentyMacV42INT8Prefixes() throws {
        let lm = try VimeLanguageModel(variant: .v42)
        let corpus = try fixtures().phrases
        XCTAssertEqual(corpus.count, 20)
        for phrase in corpus {
            let first = try XCTUnwrap(try lm.suggestions(prompt: phrase.prompt).first, phrase.prompt)
            XCTAssertEqual(first.tokenIDs, phrase.firstIDs, phrase.prompt)
            XCTAssertEqual(first.text, phrase.firstText, phrase.prompt)
            XCTAssertEqual(first.logProbabilitySum, phrase.firstSum, accuracy: 0.005, phrase.prompt)
        }
    }

    func testReservedConversionMarkersAreNeverInputOrOutput() throws {
        let lm = try VimeLanguageModel(variant: .v42)
        let marker = try lm.tokenizer.decode([4])
        if !marker.isEmpty, try lm.tokenizer.encode("今日は" + marker).contains(4) {
            XCTAssertThrowsError(try lm.scores(context: "今日は" + marker, candidates: ["雨", "晴れ"]))
        }
        for prompt in ["今日は雨が降っているので、", "明日の会議までに、"] {
            for suggestion in try lm.suggestions(prompt: prompt) {
                XCTAssertFalse(suggestion.tokenIDs.contains { [0, 1, 2, 4, 5, 6].contains($0) }, prompt)
            }
            XCTAssertFalse(try lm.nextWords(prompt: prompt).isEmpty, prompt)
        }
    }
}
