import CRime
import Foundation
import XCTest

/// The 双拼 schemas: two keys a syllable, its initial and its final's key.
final class ShuangpinTests: XCTestCase {
    override class func setUp() { RimeSmokeTests.setUp() }

    private func candidates(_ input: String, schema: String) -> (preedit: String?, texts: [String]) {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        XCTAssertTrue(vime_rime_select_schema(session, schema))
        for scalar in input.unicodeScalars { _ = vime_rime_process_key(session, Int32(scalar.value), 0) }
        var raw = vime_rime_snapshot(session, 20)
        defer { vime_rime_snapshot_free(&raw) }
        let texts = (0..<Int(raw.candidateCount)).map { String(cString: raw.candidates[$0].text) }
        return (raw.preedit.map { String(cString: $0) }, texts)
    }

    func testFlypy() {
        let schema = "vime_shuangpin_flypy"
        XCTAssertEqual(candidates("nihc", schema: schema).texts.first, "你好")
        XCTAssertTrue(candidates("vsgo", schema: schema).texts.prefix(3).contains("中国"))
        XCTAssertTrue(candidates("uuru", schema: schema).texts.prefix(3).contains("输入"))
        XCTAssertTrue(candidates("lt", schema: schema).texts.contains("略"), "ü")
        XCTAssertTrue(candidates("ah", schema: schema).texts.contains("昂"), "no initial")
        XCTAssertTrue(candidates("vsg", schema: schema).texts.prefix(3).contains("中国"), "a lone key is the initial")
        XCTAssertFalse(candidates("nihao", schema: schema).texts.prefix(3).contains("你好"), "full pinyin is not a spelling")
    }

    func testZiranma() {
        let schema = "vime_shuangpin_ziranma"
        XCTAssertEqual(candidates("nihk", schema: schema).texts.first, "你好")
        XCTAssertTrue(candidates("vsgo", schema: schema).texts.prefix(3).contains("中国"))
        XCTAssertEqual(candidates("nihk", schema: schema).preedit, "ni hk", "the preedit shows the keys")
    }
}
