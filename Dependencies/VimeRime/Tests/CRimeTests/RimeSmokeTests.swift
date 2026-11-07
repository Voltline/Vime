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

    func testCommitCompositionKeepsEarlierSelections() throws {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        type("nihaoma", into: session)
        XCTAssertTrue(vime_rime_is_composing(session))
        var raw = vime_rime_snapshot(session, 80)
        let candidates = (0..<Int(raw.candidateCount)).map { String(cString: raw.candidates[$0].text) }
        vime_rime_snapshot_free(&raw)
        XCTAssertTrue(vime_rime_select_candidate(session, try XCTUnwrap(candidates.firstIndex(of: "你好"))))
        XCTAssertTrue(vime_rime_commit_composition(session))
        XCTAssertEqual(snapshot(session).commit, "你好吗")
        XCTAssertFalse(vime_rime_is_composing(session))
    }

    func testBackspaceRightAfterACommitForgetsIt() throws {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        let before = try XCTUnwrap(rank(of: "试", after: "shi", selecting: false, session: session))
        _ = rank(of: "试", after: "shi", selecting: true, session: session)
        // The host deletes the commit; Rime sees an unhandled BackSpace.
        XCTAssertFalse(vime_rime_process_key(session, 0xff08, 0))
        XCTAssertEqual(rank(of: "试", after: "shi", selecting: false, session: session), before)
        // Control: the same single selection without BackSpace is learned.
        let control = try XCTUnwrap(rank(of: "室", after: "shi", selecting: false, session: session))
        _ = rank(of: "室", after: "shi", selecting: true, session: session)
        _ = vime_rime_process_key(session, 0xff1b, 0)
        XCTAssertLessThan(try XCTUnwrap(rank(of: "室", after: "shi", selecting: false, session: session)), control)
    }

    private func commitFirst(_ input: String, session: VimeRimeSession) -> String? {
        type(input, into: session)
        XCTAssertTrue(vime_rime_select_candidate(session, 0))
        let commit = snapshot(session).commit
        _ = vime_rime_process_key(session, 0xff1b, 0)
        return commit
    }

    func testLongSentencesAreNotLearnedWhole() throws {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        let long = try XCTUnwrap(commitFirst("womenmingtianyiqiqukandianying", session: session))
        XCTAssertGreaterThan(long.count, 8)
        let short = try XCTUnwrap(commitFirst("tamenqukandianying", session: session))
        XCTAssertLessThanOrEqual(short.count, 8)
        // Completion offers a learned phrase for the start of its input.
        XCTAssertFalse(candidates(for: "womenmingtianyiqi", limit: 60).contains(long))
        XCTAssertTrue(candidates(for: "tamenqukan", limit: 60).contains(short))
    }

    func testCompletionsAreMarked() throws {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        type("zhonggdt", into: session)
        var raw = vime_rime_snapshot(session, 20)
        defer { vime_rime_snapshot_free(&raw) }
        let marked = (0..<Int(raw.candidateCount)).filter { raw.candidates[$0].completion }
            .map { String(cString: raw.candidates[$0].text) }
        XCTAssertTrue(marked.contains { $0.count > 6 }, "\(marked)")
        XCTAssertFalse(raw.candidates[0].completion)
    }

    func testLearningSurvivesARestart() throws {
        var session = vime_rime_create_session()
        let before = try XCTUnwrap(rank(of: "式", after: "shi", selecting: false, session: session))
        for _ in 0..<3 { _ = rank(of: "式", after: "shi", selecting: true, session: session) }
        // An unhandled key ends the learning transaction, as a reset does.
        _ = vime_rime_process_key(session, 0xff1b, 0)
        vime_rime_destroy_session(session)
        vime_rime_stop()
        XCTAssertTrue(vime_rime_start(Self.data.path, Self.user.path))
        session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        XCTAssertLessThan(try XCTUnwrap(rank(of: "式", after: "shi", selecting: false, session: session)), before)
    }

    private func candidates(for input: String, limit: Int32 = 20) -> [String] {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        type(input, into: session)
        var raw = vime_rime_snapshot(session, limit)
        defer { vime_rime_snapshot_free(&raw) }
        return (0..<Int(raw.candidateCount)).map { String(cString: raw.candidates[$0].text) }
    }

    /// Prints the first candidates of the inputs in VIME_DUMP, separated by spaces.
    func testDump() throws {
        guard let list = ProcessInfo.processInfo.environment["VIME_DUMP"] else { throw XCTSkip("set VIME_DUMP") }
        let inputs = list.split(separator: " ")
        for input in inputs { print("DUMP \(input): \(candidates(for: String(input), limit: 5).joined(separator: " "))") }
    }

    func testCommonWordsComeFirst() {
        let expected = [
            "nihao": "你好", "women": "我们", "shenme": "什么", "zhongguo": "中国", "xianzai": "现在",
            "wodou": "我都", "jintiantianqizhenhao": "今天天气真好", "xiexie": "谢谢", "mingtian": "明天",
            "pengyou": "朋友", "zhidao": "知道", "keyi": "可以",
        ]
        for (input, word) in expected { XCTAssertEqual(candidates(for: input).first, word, input) }
    }

    func testPolyphonesInWordsTakeTheWordsReading() {
        // 行, 长, 重 and 乐 read differently in these words than on their own.
        for (input, word) in ["yinhang": "银行", "zhangda": "长大", "chongxin": "重新", "yinyue": "音乐", "xingli": "行李"] {
            XCTAssertEqual(candidates(for: input).first, word, input)
        }
        XCTAssertFalse(candidates(for: "yinxing", limit: 40).contains("银行"))
    }

    func testEnglishWordsMixIn() {
        for (input, word) in ["hello": "hello", "iphone": "iPhone", "ok": "OK", "github": "GitHub", "thanks": "thanks"] {
            let found = candidates(for: input)
            XCTAssertLessThan(found.firstIndex(of: word) ?? 99, 2, "\(input): \(found)")
        }
        // Input that is whole pinyin keeps a Chinese candidate first.
        for (input, word) in ["an": "an", "she": "she", "hang": "hang"] {
            let found = candidates(for: input, limit: 60)
            XCTAssertNotEqual(found.first, word, input)
            XCTAssertTrue(found.first?.unicodeScalars.first.map { $0.value >= 0x4E00 } ?? false, "\(input): \(found)")
        }
    }
}
