import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class CandidatePipelineTraceTests: XCTestCase {
    private func value(_ text: String, revision: Int = 1, consumed: Int = 5,
                       reading: String = "ハシ", remaining: ComposingText = .init()) -> CandidateSnapshot {
        CandidateSnapshot(candidate: Candidate(text: text, value: -1, composingCount: .inputCount(consumed),
            lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false), revision: revision,
            source: .conversion, remainingComposition: remaining, originalInputCount: 5,
            consumedInputCount: consumed, queryReading: "ハシ", readingOverride: reading)
    }

    func testReferenceMatchingRequiresConsumptionAndAcceptsCanonicalAlternatives() throws {
        let trace = CandidatePipelineTrace(revision: 1, references: ["橋", "が"], consumedInputCount: 5)
        trace.record(.pooled, values: [value("橋", consumed: 2), value("か\u{3099}")])
        let result = trace.snapshot()
        XCTAssertEqual(result[.pooled]?.count, 2)
        XCTAssertEqual(result[.pooled]?.referenceRank, 2, "A partial homograph cannot count as the target")
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("橋")); XCTAssertFalse(encoded.contains("が"))
        XCTAssertFalse(encoded.contains("ハシ"), "Export numeric observations, not fixture or candidate text")
    }

    func testIncrementalScoringKeepsOnlyLatestStageAndPublicationIsSeparate() {
        let trace = CandidatePipelineTrace(revision: 1, references: ["橋"], consumedInputCount: 5)
        let base = [value("箸"), value("橋")]
        trace.record(.ranked, values: base)
        trace.record(.scored, values: Array(base.prefix(1)))
        XCTAssertNil(trace.snapshot()[.scored]?.referenceRank)
        for _ in 0..<300 { trace.record(.scored, values: base) }
        trace.record(.modelRanked, values: Array(base.reversed()))
        trace.published(base, modelUsed: false)
        let result = trace.snapshot()
        XCTAssertEqual(result.stages.count, 4)
        XCTAssertEqual(result[.scored]?.referenceRank, 2)
        XCTAssertEqual(result[.modelRanked]?.referenceRank, 1)
        XCTAssertEqual(result[.initial]?.referenceRank, 2)
        XCTAssertFalse(result.modelUsed)
        XCTAssertFalse(result.top1Improved, "An unshown model preference is not a user benefit")
    }

    func testNetTop1DistinguishesPromotionsRegressionsAndMissingRecall() {
        let trace = CandidatePipelineTrace(revision: 1, references: ["橋"], consumedInputCount: 5)
        let good = value("橋"), other = value("箸")
        trace.record(.ranked, values: [other, good])
        trace.published([good, other], modelUsed: true)
        XCTAssertTrue(trace.snapshot().top1Improved)
        XCTAssertFalse(trace.snapshot().top1Regressed)
        trace.record(.ranked, values: [good, other])
        trace.published([other, good], modelUsed: true)
        XCTAssertTrue(trace.snapshot().top1Regressed)
        trace.record(.pooled, values: [other])
        XCTAssertNil(trace.snapshot()[.pooled]?.referenceRank)
        trace.record(.eligible, values: [])
        XCTAssertEqual(trace.snapshot()[.eligible]?.count, 0, "Empty and unobserved stages differ")
        XCTAssertNil(trace.snapshot()[.supported])
    }

    func testAnotherRevisionCannotOverwriteCandidateStages() {
        let trace = CandidatePipelineTrace(revision: 1, consumedInputCount: 5)
        trace.record(.initial, values: [value("橋", revision: 2)])
        XCTAssertNil(trace.snapshot()[.initial])
        trace.cancelBeforePublication()
        XCTAssertTrue(trace.snapshot().cancelledBeforePublication)
    }

    func testStoredReadingStillHonorsMutableScopeAndDisplaySemantics() {
        var value = value("橋", reading: "はし")
        XCTAssertEqual(value.reading, "ハシ")
        XCTAssertTrue(value.exactReading)
        value.scopeReading = "ハ"; value.explicitScope = true
        XCTAssertFalse(value.exactReading)
        XCTAssertFalse(value.scopeFullConsumption)
        value.scopeReading = "ハシ"; value.displaySurface = "はし"
        value.widthVariant = .halfWidthKatakana
        XCTAssertTrue(value.exactReading)
        XCTAssertEqual(value.text, "はし")
        XCTAssertEqual(value.reading, "ハシ")
        XCTAssertEqual(value.ruby, "")
        XCTAssertFalse(self.value("A", reading: "A").exactReading)
    }
}
