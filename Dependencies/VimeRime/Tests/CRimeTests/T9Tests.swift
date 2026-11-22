import CRime
import Foundation
import XCTest

/// The nine-key schema (vime_t9): digits 2–9 spell pinyin, letters spell the
/// syllables picked from the syllable bar.
final class T9Tests: XCTestCase {
    override class func setUp() { RimeSmokeTests.setUp() }

    private func session() -> VimeRimeSession {
        let session = vime_rime_create_session()
        XCTAssertTrue(vime_rime_select_schema(session, "vime_t9"))
        return session
    }

    private func type(_ text: String, into session: VimeRimeSession) {
        for scalar in text.unicodeScalars { _ = vime_rime_process_key(session, Int32(scalar.value), 0) }
    }

    private func snapshot(_ session: VimeRimeSession, limit: Int32 = 20)
        -> (input: String?, preedit: String?, candidates: [(text: String, comment: String)]) {
        var raw = vime_rime_snapshot(session, limit)
        defer { vime_rime_snapshot_free(&raw) }
        let candidates = (0..<Int(raw.candidateCount)).map {
            (String(cString: raw.candidates[$0].text), raw.candidates[$0].comment.map { String(cString: $0) } ?? "")
        }
        return (raw.input.map { String(cString: $0) }, raw.preedit.map { String(cString: $0) }, candidates)
    }

    func testDigitsSpellWords() {
        let session = session()
        defer { vime_rime_destroy_session(session) }
        type("64426", into: session)  // nihao
        let state = snapshot(session)
        XCTAssertEqual(state.input, "64426")
        XCTAssertEqual(state.candidates.first?.text, "你好")
        XCTAssertEqual(state.candidates.first?.comment, "ni hao", "the spelling hint gives the reading")
    }

    func testSentenceAndAbbreviation() {
        let session = session()
        defer { vime_rime_destroy_session(session) }
        type("94664486", into: session)  // zhongguo
        let state = snapshot(session)
        XCTAssertTrue(state.candidates.prefix(3).contains { $0.text == "中国" })
        vime_rime_clear(session)
        type("5464824", into: session)  // jingtai
        XCTAssertEqual(snapshot(session).candidates.first?.text, "静态")
    }

    func testPickedSyllableNarrowsTheReading() {
        let session = session()
        defer { vime_rime_destroy_session(session) }
        type("xiong'486", into: session)
        let state = snapshot(session)
        XCTAssertFalse(state.candidates.prefix(5).contains { $0.text == "中国" })
    }

    func testSpeed() {
        let session = session()
        defer { vime_rime_destroy_session(session) }
        let clock = ContinuousClock()
        let input = "936643664742684264"
        var worst = Duration.zero
        for scalar in input.unicodeScalars {
            let start = clock.now
            _ = vime_rime_process_key(session, Int32(scalar.value), 0)
            _ = snapshot(session, limit: 60)
            worst = max(worst, clock.now - start)
        }
        XCTAssertLessThan(worst, .milliseconds(100), "one key and its candidates")
    }
}
