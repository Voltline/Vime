import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardWidthCandidateTests: XCTestCase {
    private func query(_ raw: String) -> ComposingText {
        var value = ComposingText()
        RomajiConverter.insert(raw.replacingOccurrences(of: "-", with: "ー"), into: &value)
        return value
    }

    func testNativeFormatsPreserveSpellingAndOrdinaryRanking() throws {
        let engine = JapaneseCandidateEngine()
        for (raw, surface, kind) in [
            ("gakkou", "ｶﾞｯｺｳ", CandidateWidthVariant.halfWidthKatakana),
            ("be-to-benn", "ﾍﾞｰﾄｰﾍﾞﾝ", .halfWidthKatakana),
            ("12345", "１２３４５", .fullWidthAlphanumeric),
            ("abc123", "ａｂｃ１２３", .fullWidthAlphanumeric),
            ("GitHub", "ＧｉｔＨｕｂ", .fullWidthAlphanumeric)
        ] {
            engine.reset()
            let composing = query(raw)
            let base = engine.candidates(for: composing, revision: 1, includeCorrections: false)
            XCTAssertFalse(base.contains { $0.widthVariant != nil })
            let expanded = engine.addingWidthCandidates(to: base, for: composing, katakana: false, revision: 1)
            let value = try XCTUnwrap(expanded.first { $0.text == surface }, raw)
            XCTAssertEqual(value.widthVariant, kind)
            XCTAssertEqual(value.source, .scriptVariant)
            XCTAssertTrue(value.fullConsumption)
            XCTAssertTrue(value.engineFullConsumption)
            XCTAssertEqual(value.consumedInputCount, composing.input.count)
            XCTAssertFalse(value.lexical)
            XCTAssertFalse(value.learningEligible)
            XCTAssertFalse(value.candidate.isLearningTarget)
            XCTAssertEqual(value.presentation.annotation, kind.annotation)
            XCTAssertEqual(expanded.filter { $0.text == surface }.count, 1)
            let again = engine.candidates(for: composing, revision: 2, includeCorrections: false)
            XCTAssertEqual(again.map(\.presentation), base.map(\.presentation), "Formatting queries must not change ordinary conversion state or order")
        }
    }

    func testExpandedSelectionCommitsHalfWidthWithoutChangingPreedit() throws {
        let session = KeyboardSession()
        _ = session.type("gakkou")
        let mark = session.preedit
        let raw = session.raw
        XCTAssertFalse(session.candidateSnapshots.contains { $0.widthVariant != nil })
        session.setExpandedCandidates(true)
        XCTAssertEqual(session.preedit, mark)
        XCTAssertEqual(session.raw, raw)
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "ｶﾞｯｺｳ" })
        XCTAssertEqual(session.choose(index), [.insert("ｶﾞｯｺｳ")])
        XCTAssertFalse(session.isComposing)
        XCTAssertNil(session.preedit)
    }

    func testUnfinishedRomanIsPreservedUntilExplicitBoundary() throws {
        let session = KeyboardSession()
        _ = session.type("be-to-ben")
        XCTAssertEqual(session.preedit, "べーとーべn")
        let raw = session.raw
        session.setExpandedCandidates(true)
        XCTAssertEqual(session.preedit, "べーとーべn")
        XCTAssertEqual(session.raw, raw)
        XCTAssertFalse(session.candidateSnapshots.contains { $0.widthVariant == .halfWidthKatakana })
        XCTAssertEqual(session.space(), [])
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "ﾍﾞｰﾄｰﾍﾞﾝ" })
        XCTAssertEqual(session.choose(index), [.insert("ﾍﾞｰﾄｰﾍﾞﾝ")])
        XCTAssertFalse(session.isComposing)
        _ = session.type("nanim")
        session.setExpandedCandidates(true)
        XCTAssertEqual(session.raw, "nanim")
        XCTAssertEqual(session.preedit, "なにm")
        XCTAssertTrue(session.candidates.contains("何も"))
    }

    func testWidthPrefixKeepsRemainderConvertible() throws {
        let engine = JapaneseCandidateEngine()
        let composing = query("gakkoudesu")
        let base = engine.candidates(for: composing, revision: 1, includeCorrections: false, conversionLength: 4)
        let expanded = engine.addingWidthCandidates(to: base, for: composing, katakana: false,
            revision: 1, conversionLength: 4)
        let value = try XCTUnwrap(expanded.first { $0.text == "ｶﾞｯｺｳ" })
        XCTAssertFalse(value.fullConsumption)
        XCTAssertTrue(value.engineFullConsumption, "The native scoped query is fully consumed even though the document still has a remainder")
        XCTAssertTrue(value.explicitScope)
        XCTAssertEqual(value.consumedReadingCount, 4)
        XCTAssertEqual(value.remainingComposition.convertTarget, "です")
        XCTAssertEqual(value.presentation.annotation, "半角片假名 · 前段")
        let session = KeyboardSession()
        _ = session.type("gakkoudesu")
        session.adjustConversionRange(by: -1)
        session.setExpandedCandidates(true)
        let first = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "ｶﾞｯｺｳ" && !$0.fullConsumption })
        XCTAssertEqual(session.choose(first), [.insert("ｶﾞｯｺｳ")])
        XCTAssertEqual(session.preedit, "です")
        let last = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "です" && $0.fullConsumption })
        XCTAssertEqual(session.choose(last), [.insert("です")])
        XCTAssertFalse(session.isComposing)
    }

    func testAsyncExpandedFormatsRespectLatestRevision() async throws {
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: directory)
        session.candidateRanking = .engine
        let ready = expectation(description: "Latest raw spelling gets a full-width candidate")
        var delivered = false
        session.onCandidatesChange = {
            if session.candidatesAreCurrent && session.candidateSnapshots.contains(where: { $0.text == "１２３４５" }) && !delivered {
                delivered = true; ready.fulfill()
            }
        }
        _ = session.type("gakkou")
        session.setExpandedCandidates(true)
        session.reset()
        _ = session.type("12345")
        session.setExpandedCandidates(true)
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(session.raw, "12345")
        XCTAssertEqual(session.preedit, "12345")
        XCTAssertFalse(session.candidates.contains("ｶﾞｯｺｳ"))
        XCTAssertTrue(session.candidateSnapshots.allSatisfy { $0.revision == session.revision })
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "１２３４５" })
        XCTAssertEqual(session.choose(index), [.insert("１２３４５")])
        XCTAssertFalse(session.isComposing)
        session.onCandidatesChange = nil
    }
}
