import CRime
import Foundation
import XCTest

/// Next-word suggestions: phrases of the dictionary that begin with the word
/// just committed.
final class ContinuationTests: XCTestCase {
    override class func setUp() {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("vime-rime-continuation-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        precondition(vime_rime_start(PinyinToleranceTests.data.path, user.path))
    }

    /// Commits `input` with Space and returns the commit's last word and code.
    private func commit(_ session: VimeRimeSession, _ input: String) -> (commit: String?, word: String?, code: String?) {
        vime_rime_clear(session)
        for scalar in (input + " ").unicodeScalars { _ = vime_rime_process_key(session, Int32(scalar.value), 0) }
        var raw = vime_rime_snapshot(session, 0)
        defer { vime_rime_snapshot_free(&raw) }
        func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }
        return (string(raw.commit), string(raw.commitWord), string(raw.commitCode))
    }

    private func continuations(_ session: VimeRimeSession, _ word: String, _ code: String, traditional: Bool = false)
        -> [(text: String, genuine: String, code: String)] {
        var list = vime_rime_continuations(session, word, code, 10, traditional)
        defer { vime_rime_continuations_free(&list) }
        return (0..<Int(list.count)).map {
            let item = list.items[$0]
            return (String(cString: item.text), String(cString: item.genuine), String(cString: item.code))
        }
    }

    func testCommitsOfferWhatFollowsThem() throws {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        precondition(vime_rime_select_schema(session, "vime_pinyin"))
        for (input, expected) in [("dianhua", "号码"), ("women", "的"), ("jintian", "早上"), ("zhongguo", "人")] {
            let committed = commit(session, input)
            let word = try XCTUnwrap(committed.word, input)
            let code = try XCTUnwrap(committed.code, input)
            XCTAssertEqual(committed.commit, word, input)
            let found = continuations(session, word, code)
            XCTAssertTrue(found.contains { $0.text == expected }, "\(input): \(found.map(\.text))")
            // Each continuation can be asked about in turn.
            let next = try XCTUnwrap(found.first { $0.code.split(separator: " ").count > 0 })
            _ = continuations(session, next.genuine, next.code)
        }
        let phone = try XCTUnwrap(commit(session, "dianhua").code)
        XCTAssertTrue(continuations(session, "电话", phone, traditional: true).contains { $0.text == "號碼" && $0.genuine == "号码" })
        // Raw letters are no dictionary word.
        vime_rime_clear(session)
        for scalar in "xyz".unicodeScalars { _ = vime_rime_process_key(session, Int32(scalar.value), 0) }
        _ = vime_rime_process_key(session, 0xFF0D, 0)
        var raw = vime_rime_snapshot(session, 0)
        XCTAssertNil(raw.commitWord)
        vime_rime_snapshot_free(&raw)
        XCTAssertTrue(continuations(session, "", "1").isEmpty)
    }
}
