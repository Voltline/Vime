import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardLearnedNearReadingTests: XCTestCase {
    private func directory() throws -> URL {
        let url = isolatedLearningDirectory()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private var before = ""

    private func makeSession(_ url: URL) -> KeyboardSession {
        let session = KeyboardSession(memoryDirectoryURL: url)
        session.leftContextProvider = { [unowned self] in before }
        session.learningContextProvider = { [unowned self] in KeyboardLearningContext(document: "field", before: before, after: "") }
        return session
    }

    private func learn(_ surface: String, typing raw: String, in session: KeyboardSession) throws {
        _ = session.type(raw)
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == surface && $0.fullConsumption },
                                  "\(surface) not offered for \(raw): \(session.candidates)")
        let edits = session.choose(index)
        session.didApplyEdits(edits)
        before += surface
        session.didApplyEdits(); session.finishLearningFeedback()
        session.reset()
    }

    /// 呼び出し reached from よびだす only by a key correction (す→し): its
    /// learning must not put it above 呼び出す, which reads what was typed.
    func testLearnedNearReadingDoesNotLeadExactReading() throws {
        let session = makeSession(try directory())
        for _ in 0..<3 { try learn("呼び出し", typing: "yobidashi", in: session) }
        before = ""
        _ = session.type("yobidasu")
        XCTAssertEqual(session.candidates.first, "呼び出す", "\(session.candidates)")
        let learned = try XCTUnwrap(session.candidateSnapshots.first { $0.text == "呼び出し" })
        XCTAssertNotNil(learned.correction)
        XCTAssertGreaterThan(learned.userPreferenceScore, 0)
    }

    /// A real typo still has some exact segmentation (ヨブだし), but the
    /// corrected reading is clearly better, so the learned word still leads.
    func testLearnedCorrectionStillLeadsARealTypo() throws {
        let session = makeSession(try directory())
        for _ in 0..<3 { try learn("呼び出し", typing: "yobidashi", in: session) }
        for raw in ["yobudashi", "yobidaahi"] {
            before = ""
            _ = session.type(raw)
            XCTAssertEqual(session.candidates.first, "呼び出し", "\(raw): \(session.candidates)")
            XCTAssertNotNil(session.candidateSnapshots.first?.correction, raw)
            XCTAssertTrue(session.candidateSnapshots.contains { CandidatePrefixPolicy.spellsInputExactly($0) }, raw)
            session.reset()
        }
    }
}
