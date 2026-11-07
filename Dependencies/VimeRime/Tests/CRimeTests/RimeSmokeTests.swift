import CRime
import Foundation
import XCTest

/// Runs the prebuilt data in Shared/Resources/RimeData.bundle on macOS.
final class RimeSmokeTests: XCTestCase {
    static let data = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../../Shared/Resources/RimeData.bundle").standardized
    static let user = FileManager.default.temporaryDirectory.appendingPathComponent("vime-rime-tests-\(UUID().uuidString)")

    override class func setUp() {
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        precondition(vime_rime_start(data.path, user.path))
    }

    private func type(_ text: String, into session: VimeRimeSession) {
        for scalar in text.unicodeScalars { _ = vime_rime_process_key(session, Int32(scalar.value), 0) }
    }

    private func snapshot(_ session: VimeRimeSession) -> (input: String?, commit: String?, candidates: [String]) {
        var raw = vime_rime_snapshot(session, 20)
        defer { vime_rime_snapshot_free(&raw) }
        let candidates = (0..<Int(raw.candidateCount)).map { String(cString: raw.candidates[$0].text) }
        return (raw.input.map { String(cString: $0) }, raw.commit.map { String(cString: $0) }, candidates)
    }

    func testFullPinyinAndSelection() throws {
        let session = vime_rime_create_session()
        XCTAssertNotEqual(session, 0)
        defer { vime_rime_destroy_session(session) }
        type("nihao", into: session)
        let state = snapshot(session)
        XCTAssertEqual(state.input, "nihao")
        XCTAssertEqual(state.candidates.first, "你好")
        XCTAssertTrue(vime_rime_select_candidate(session, 0))
        XCTAssertEqual(snapshot(session).commit, "你好")
        XCTAssertNil(snapshot(session).commit, "a commit is taken once")
    }

    func testAbbreviationAndSentence() {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        type("zg", into: session)
        XCTAssertTrue(snapshot(session).candidates.contains("中国"))
        vime_rime_clear(session)
        type("womenyiqiqukandianying", into: session)
        XCTAssertEqual(snapshot(session).candidates.first, "我们一起去看电影")
        XCTAssertTrue(vime_rime_process_key(session, 0xff08, 0), "BackSpace edits the composition")
        XCTAssertEqual(snapshot(session).input, "womenyiqiqukandianyin")
    }

    private func rank(of text: String, after input: String, selecting: Bool, session: VimeRimeSession) -> Int? {
        type(input, into: session)
        var raw = vime_rime_snapshot(session, 60)
        let candidates = (0..<Int(raw.candidateCount)).map { String(cString: raw.candidates[$0].text) }
        vime_rime_snapshot_free(&raw)
        let index = candidates.firstIndex(of: text)
        if selecting, let index { _ = vime_rime_select_candidate(session, index); _ = snapshot(session) }
        vime_rime_clear(session)
        return index
    }

    func testLearningFilterKeepsTheUserDictionaryUnchanged() throws {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session); vime_rime_set_learning_filter(nil) }
        // 示 and 势 start well below the first page for "shi".
        vime_rime_set_learning_filter { text in String(cString: text!) != "势" }
        let blocked = try XCTUnwrap(rank(of: "势", after: "shi", selecting: false, session: session))
        for _ in 0..<3 { _ = rank(of: "势", after: "shi", selecting: true, session: session) }
        XCTAssertEqual(rank(of: "势", after: "shi", selecting: false, session: session), blocked)

        let learned = try XCTUnwrap(rank(of: "示", after: "shi", selecting: false, session: session))
        for _ in 0..<3 { _ = rank(of: "示", after: "shi", selecting: true, session: session) }
        XCTAssertLessThan(try XCTUnwrap(rank(of: "示", after: "shi", selecting: false, session: session)), learned)
    }

    func testPartialSelectionLeavesTheRest() throws {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        type("nihaoma", into: session)
        var raw = vime_rime_snapshot(session, 80)
        let candidates = (0..<Int(raw.candidateCount)).map { String(cString: raw.candidates[$0].text) }
        vime_rime_snapshot_free(&raw)
        let index = try XCTUnwrap(candidates.firstIndex(of: "你好"), "\(candidates)")
        XCTAssertTrue(vime_rime_select_candidate(session, index))
        let rest = snapshot(session)
        XCTAssertNil(rest.commit)
        XCTAssertEqual(rest.candidates.first, "吗", "\(rest.candidates)")
        XCTAssertTrue(vime_rime_select_candidate(session, 0))
        XCTAssertEqual(snapshot(session).commit, "你好吗")
    }
}
