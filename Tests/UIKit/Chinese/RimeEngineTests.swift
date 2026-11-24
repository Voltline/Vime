import CRime
import XCTest

final class RimeEngineTests: XCTestCase {
    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("RimeEngineTests-\(UUID().uuidString)")

    private func engine() throws -> RimeEngine {
        RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled"),
                   userDirectory: Self.user)
    }

    func testFullPinyinCommitsOnce() throws {
        let engine = try engine()
        let typed = engine.sendAndWait(.type("nihao"))
        XCTAssertEqual(typed.input, "nihao")
        XCTAssertEqual(typed.candidates.first?.text, "你好")
        XCTAssertNil(typed.commit)
        let selected = engine.sendAndWait(.select(0))
        XCTAssertEqual(selected.commit, "你好")
        XCTAssertFalse(selected.isComposing)
        XCTAssertNil(engine.sendAndWait(.clear).commit)
    }

    func testLoneVowelSyllablesAlsoListWhatTheirShorterStartSpells() throws {
        XCTAssertEqual(PinyinVowelSplit.spelling(for: "ei"), "e'i")
        XCTAssertEqual(PinyinVowelSplit.spelling(for: "en"), "e'n")
        XCTAssertEqual(PinyinVowelSplit.spelling(for: "ang"), "an'g")
        for input in ["e", "shang", "nihao", "xyz", "e'i"] { XCTAssertNil(PinyinVowelSplit.spelling(for: input), input) }

        let engine = try engine()
        let typed = engine.sendAndWait(.type("ei"))
        let texts = typed.candidates.map(\.text)
        XCTAssertEqual(texts.first, "诶", "the syllable's own characters come first")
        let hungry = try XCTUnwrap(texts.firstIndex(of: "饿"), "e's characters follow: \(texts)")
        XCTAssertGreaterThan(hungry, try XCTUnwrap(texts.firstIndex(of: "欸")))
        XCTAssertFalse(typed.candidates[hungry].coversInput)
        let chosen = engine.sendAndWait(.select(hungry))
        XCTAssertEqual(chosen.preedit, "饿i", "the rest stays to type on")
        _ = engine.sendAndWait(.clear)

        let en = engine.sendAndWait(.type("en")).candidates.map(\.text)
        XCTAssertEqual(Array(en.prefix(2)), ["嗯", "恩"])
        XCTAssertTrue(en.contains("恶念") && en.contains("饿"), "e then n follows: \(en)")
        _ = engine.sendAndWait(.clear)
    }

    func testCompletionAddsAtMostTwoCharacters() throws {
        XCTAssertEqual(RimeEngine.syllableCount("zhong g d t"), 4)
        XCTAssertEqual(RimeEngine.syllableCount("你好 ma"), 1)
        XCTAssertTrue(RimeEngine.completionFits("你好", syllables: 2))
        XCTAssertTrue(RimeEngine.completionFits("中国地图", syllables: 2))
        XCTAssertFalse(RimeEngine.completionFits("中国地图出", syllables: 2))
        XCTAssertTrue(RimeEngine.completionFits("iPhone", syllables: 1))

        let engine = try engine()
        let typed = engine.sendAndWait(.type("zhonggdt"))
        XCTAssertFalse(typed.candidates.isEmpty)
        XCTAssertTrue(typed.candidates.allSatisfy { $0.text.count <= 6 }, "\(typed.candidates.map(\.text))")
        // Indices count shown candidates, skipping hidden ones.
        let second = typed.candidates[1].text
        let selected = engine.sendAndWait(.select(1))
        // A phrase for part of the input stays in the preedit until the rest is chosen.
        XCTAssertTrue(selected.commit == second || selected.preedit.hasPrefix(second), "\(second) \(selected)")
        _ = engine.sendAndWait(.clear)
        XCTAssertTrue(engine.sendAndWait(.type("nih")).candidates.map(\.text).contains("你好"))
        _ = engine.sendAndWait(.clear)
    }

    func testLearningResetDeletesTheUserDictionary() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RimeEngineTests-\(UUID().uuidString)"))
        try assertResetDeletesTheUserDictionary(KeyboardLearningResetRequests(defaults: defaults), reset: { $0.request() })
    }

    func testChineseLearningResetLeavesTheJapaneseRequestAlone() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RimeEngineTests-\(UUID().uuidString)"))
        let requests = KeyboardLearningResetRequests(defaults: defaults)
        try assertResetDeletesTheUserDictionary(requests, reset: { $0.chinese.request() })
        XCTAssertFalse(requests.chinese.isPending)
        XCTAssertNil(requests.requestID)
        XCTAssertFalse(requests.isPending)
    }

    func testLearnedWordChangesMergeWhenRimeStartsAgain() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RimeEngineTests-\(UUID().uuidString)"))
        let pending = FileManager.default.temporaryDirectory.appendingPathComponent("RimePending-\(UUID().uuidString)")
        let learned = ChineseLearnedWords(userDirectory: Self.user, pendingDirectory: pending, defaults: defaults)
        let engine = RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData), userDirectory: Self.user, learnedWords: learned)
        _ = engine.sendAndWait(.clear)
        func stored() throws -> ChineseLearnedWord? { try learned.words().first { $0.text == "栅格弥漫" } }
        func waiting() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: pending.path)) ?? [] }

        let imported = try learned.importFile(Data("# Rime\n栅格弥漫\tzha ge mi man\t7\n弥漫\tnot pinyin\t1\n".utf8))
        XCTAssertEqual(imported.added, 1)
        XCTAssertEqual(imported.skipped, 1)
        XCTAssertEqual(try stored()?.commits, 7, "changes still waiting show at once")
        XCTAssertEqual(waiting().count, 1)

        _ = engine.sendAndWait(.clear)
        XCTAssertEqual(waiting(), [], "Rime merged the change when it started again")
        let word = try XCTUnwrap(try stored())
        XCTAssertEqual(word.pinyin, "zha ge mi man")
        XCTAssertTrue(try XCTUnwrap(String(data: try learned.exportText(), encoding: .utf8)).contains("栅格弥漫\tzha ge mi man\t"))

        try learned.delete([word])
        XCTAssertNil(try stored())
        _ = engine.sendAndWait(.clear)
        XCTAssertEqual(waiting(), [])
        XCTAssertNil(try stored(), "the deletion reached the dictionary")
        XCTAssertEqual(engine.sendAndWait(.type("nihao")).candidates.first?.text, "你好", "Rime still answers")
        _ = engine.sendAndWait(.clear)
    }

    private func assertResetDeletesTheUserDictionary(_ requests: KeyboardLearningResetRequests,
                                                     reset: (KeyboardLearningResetRequests) -> Void) throws {
        let engine = RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData), userDirectory: Self.user, resetRequests: requests)
        func rank() -> Int? {
            let index = engine.sendAndWait(.type("shi")).candidates.firstIndex { $0.text == "式" }
            _ = engine.sendAndWait(.clear)
            return index
        }
        // Rime keeps the user directory of the first engine in the process,
        // which an earlier test may have taught. A reset restarts it here,
        // empty, so the baseline and the final rank share one dictionary.
        reset(requests)
        _ = engine.sendAndWait(.clear)
        let before = try XCTUnwrap(rank())
        for _ in 0..<3 {
            let index = try XCTUnwrap(engine.sendAndWait(.type("shi")).candidates.firstIndex { $0.text == "式" })
            XCTAssertEqual(engine.sendAndWait(.select(index)).commit, "式")
            _ = engine.sendAndWait(.finishLearning)
        }
        XCTAssertLessThan(try XCTUnwrap(rank()), before)
        reset(requests)
        _ = engine.sendAndWait(.clear)
        XCTAssertEqual(rank(), before)
        XCTAssertNil(requests.pendingID(for: "rime." + Self.user.lastPathComponent))
        XCTAssertNil(requests.chinese.pendingID(for: "rime." + Self.user.lastPathComponent))
    }

    func testTraditionalCharactersFollowTheOption() throws {
        let engine = try engine()
        defer { _ = engine.sendAndWait(.setTraditional(false)); _ = engine.sendAndWait(.clear) }
        XCTAssertEqual(engine.sendAndWait(.type("toufa")).candidates.first?.text, "头发")
        // Turning it on while composing looks the same input up again.
        let shown = engine.sendAndWait(.setTraditional(true))
        XCTAssertEqual(shown.input, "toufa")
        XCTAssertEqual(shown.candidates.first?.text, "頭髮")
        XCTAssertEqual(engine.sendAndWait(.select(0)).commit, "頭髮")
        XCTAssertEqual(engine.sendAndWait(.type("zhongguo")).candidates.first?.text, "中國")
        _ = engine.sendAndWait(.clear)
        XCTAssertTrue(engine.sendAndWait(.setTraditional(false)).candidates.isEmpty)
        XCTAssertEqual(engine.sendAndWait(.type("zhongguo")).candidates.first?.text, "中国")
        _ = engine.sendAndWait(.clear)
        // A new session, as after Rime restarts, starts traditional again.
        let other = try self.engine()
        _ = other.sendAndWait(.setTraditional(true))
        XCTAssertEqual(other.sendAndWait(.type("zhongguo")).candidates.first?.text, "中國")
        _ = other.sendAndWait(.clear)
    }

    func testFuzzyPinyinFollowsTheSettings() throws {
        let engine = try engine()
        defer { _ = engine.sendAndWait(.setFuzzy([])); _ = engine.sendAndWait(.clear) }
        func shows(_ input: String, _ text: String) -> Bool {
            defer { _ = engine.sendAndWait(.clear) }
            return engine.sendAndWait(.type(input)).candidates.prefix(6).contains { $0.text == text }
        }
        XCTAssertFalse(shows("sijian", "时间"))
        // Turning it on while composing looks the same input up again.
        _ = engine.sendAndWait(.type("sijian"))
        let shown = engine.sendAndWait(.setFuzzy(.retroflex))
        XCTAssertEqual(shown.input, "sijian")
        XCTAssertTrue(shown.candidates.prefix(6).contains { $0.text == "时间" }, "\(shown.candidates.map(\.text))")
        _ = engine.sendAndWait(.clear)
        XCTAssertFalse(shows("lanren", "男人"))
        _ = engine.sendAndWait(.setFuzzy([.retroflex, .initials]))
        XCTAssertTrue(shows("lanren", "男人"))
        XCTAssertEqual(engine.sendAndWait(.type("zhongguo")).candidates.first?.text, "中国")
        _ = engine.sendAndWait(.clear)
        _ = engine.sendAndWait(.setFuzzy([]))
        XCTAssertFalse(shows("sijian", "时间"))
    }

    func testOtherSpellingsAreLookedUpAside() throws {
        let engine = try engine()
        defer { _ = engine.sendAndWait(.clear) }
        XCTAssertEqual(engine.sendAndWait(.type("shenem")).input, "shenem")
        let done = expectation(description: "lookup")
        nonisolated(unsafe) var found: [(spelling: String, candidates: [RimeCandidate])] = []
        engine.lookUp(["shenme", "keyi"], limit: 4, isCancelled: { false }) { found = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(found.map(\.spelling), ["shenme", "keyi"])
        XCTAssertEqual(found.first?.candidates.first?.text, "什么")
        XCTAssertEqual(found.last?.candidates.first?.text, "可以")
        // The typing session still holds what was typed.
        let state = engine.sendAndWait(.selectSpelling(input: "shenme", text: "什么"))
        XCTAssertEqual(state.commit, "什么")
        XCTAssertFalse(state.isComposing)
        // A phrase the spelling does not give leaves the input alone.
        _ = engine.sendAndWait(.type("gongzo"))
        XCTAssertEqual(engine.sendAndWait(.selectSpelling(input: "gongzuo", text: "什么")).input, "gongzo")
        let cancelled = expectation(description: "cancelled")
        cancelled.isInverted = true
        engine.lookUp(["shenme"], limit: 4, isCancelled: { true }) { _ in cancelled.fulfill() }
        wait(for: [cancelled], timeout: 0.3)
    }

    func testCommandsRunInOrder() throws {
        let engine = try engine()
        let done = expectation(description: "all commands")
        let states = LockedStates()
        for letter in "women" { engine.send(.type(String(letter))) { states.append($0) } }
        engine.send(.backspace) { states.append($0) }
        engine.send(.type("n")) { states.append($0); done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(states.values.map(\.input), ["w", "wo", "wom", "wome", "women", "wome", "women"])
        XCTAssertEqual(states.values.last?.candidates.first?.text, "我们")
        _ = engine.sendAndWait(.clear)
    }

    func testCommitInputAndSyllableBreak() throws {
        let engine = try engine()
        XCTAssertTrue(engine.sendAndWait(.type("xi'an")).candidates.prefix(3).map(\.text).contains("西安"))
        XCTAssertEqual(engine.sendAndWait(.commitInput).commit, "xi'an")
        _ = engine.sendAndWait(.type("lv"))
        XCTAssertEqual(engine.sendAndWait(.clear).input, "")
    }

    func testClosingReleasesTheUserDictionaryAndKeepsWhatWasLearned() throws {
        let engine = try engine()
        _ = engine.sendAndWait(.clear)
        let directory = try XCTUnwrap(RimeEngine.runningUserDirectory)
        // A commit leaves Rime's learning transaction open; closing must write it.
        XCTAssertEqual(engine.sendAndWait(.type("shurufa")).candidates.first?.text, "输入法")
        XCTAssertEqual(engine.sendAndWait(.select(0)).commit, "输入法")
        _ = engine.sendAndWait(.type("nihao"))
        XCTAssertTrue(RimeEngine.userDictionaryIsOpen(), "a running session holds the user dictionary")

        RimeEngine.closeUserDictionaries()
        XCTAssertFalse(RimeEngine.userDictionaryIsOpen(), "closing releases the database and its LOCK")
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("RimeClosed-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: text) }
        let database = directory.appendingPathComponent(ChineseLearnedWords.dictionary + ".userdb", isDirectory: true)
        XCTAssertGreaterThan(vime_rime_userdb_export(database.path, ChineseLearnedWords.dictionary, text.path), 0)
        XCTAssertTrue(try String(contentsOf: text, encoding: .utf8).contains("输入法\tshu ru fa\t"))

        // Looking up continuations alone does not open it again.
        XCTAssertEqual(engine.continuationsAndWait(of: "你好", code: "ni hao", limit: 3), [])
        XCTAssertFalse(RimeEngine.userDictionaryIsOpen())
        // Nor does a late command that is not a key: a setting, or the input set again.
        _ = engine.sendAndWait(.setTraditional(false))
        _ = engine.sendAndWait(.setInput("nihao"))
        XCTAssertFalse(RimeEngine.userDictionaryIsOpen(), "only a key opens it before the keyboard shows again")

        // The next key opens it again and carries on with the composition.
        let resumed = engine.sendAndWait(.type("ma"))
        print("RimeEngineTests reopen key: \(resumed.duration)")
        XCTAssertEqual(resumed.input, "nihaoma")
        XCTAssertEqual(resumed.candidates.first?.text, "你好吗")
        XCTAssertTrue(RimeEngine.userDictionaryIsOpen())
        XCTAssertLessThan(resumed.duration, .milliseconds(150))
        _ = engine.sendAndWait(.clear)

        // Opening ahead of the next key, as the keyboard does in the foreground.
        RimeEngine.closeUserDictionaries()
        RimeEngine.reopenUserDictionaries()
        XCTAssertTrue(RimeEngine.userDictionaryIsOpen())
        XCTAssertLessThan(engine.sendAndWait(.type("a")).duration, .milliseconds(100))
        _ = engine.sendAndWait(.clear)
    }

    func testWarmCommandIsFast() throws {
        let engine = try engine()
        _ = engine.sendAndWait(.type("a"))
        _ = engine.sendAndWait(.clear)
        var slowest = Duration.zero
        for letter in "zhonghuarenmingongheguo" {
            slowest = max(slowest, engine.sendAndWait(.type(String(letter))).duration)
        }
        XCTAssertEqual(engine.sendAndWait(.clear).input, "")
        print("RimeEngineTests slowest warm key: \(slowest)")
        XCTAssertLessThan(slowest, .milliseconds(100))
    }
}

/// Phase 0 numbers: cold start, per-key time and memory, for full pinyin and
/// for the nine-key schema typing the same sentences as digits. Runs only
/// when TEST_RUNNER_VIME_RIME_METRICS is set; each report is printed as a
/// VIME_RIME_METRICS line and, where that path is writable, saved there.
/// Run each test in its own process, so the memory numbers stay apart.
final class RimeEngineMetricsTests: XCTestCase {
    private static let sentences = ["nihao", "womenyiqiqukandianying", "jintiantianqizhenhao", "zhonghuarenmingongheguo",
                                    "woxiangmaiyibuxinshouji", "zhegewentiwozaixiangxiang", "xiawusandiankaihui", "zg", "bjdx",
                                    "shurufa", "ruguoniyouwenti", "qingbawenjianfageiwo"]

    func testMeasure() throws { try measure(nineKey: false) }
    func testMeasureNineKey() throws { try measure(nineKey: true) }

    private func measure(nineKey: Bool) throws {
        let path = ProcessInfo.processInfo.environment["VIME_RIME_METRICS"]
        try XCTSkipIf(path == nil, "set TEST_RUNNER_VIME_RIME_METRICS to measure")
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("RimeMetrics-\(UUID().uuidString)")
        let before = footprint()
        let engine = RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData), userDirectory: user)
        // Rime starts on the first command, which for nine-key selects its schema.
        let setup = nineKey ? engine.sendAndWait(.setLayoutSchema(RimeEngine.nineKeySchema)).duration : .zero
        let cold = setup + engine.sendAndWait(.type(nineKey ? "6" : "n")).duration
        let afterStart = footprint()
        _ = engine.sendAndWait(.clear)
        var timed: [(ms: Double, at: String)] = []
        for _ in 0..<5 {
            for sentence in Self.sentences {
                let typed = nineKey ? NineKeyPinyin.digits(for: sentence) : sentence
                for (index, key) in typed.enumerated() {
                    timed.append((engine.sendAndWait(.type(String(key))).duration.milliseconds, String(typed.prefix(index + 1))))
                }
                timed.append((engine.sendAndWait(.select(0)).duration.milliseconds, typed + " select"))
            }
        }
        let keys = timed.map(\.ms).sorted()
        print("VIME_RIME_SLOWEST", timed.sorted { $0.ms > $1.ms }.prefix(8).map { String(format: "%@ %.1f", $0.at, $0.ms) })
        func percentile(_ p: Double) -> Double { keys[min(keys.count - 1, Int(Double(keys.count) * p))] }
        let report: [String: Double] = [
            "cold_start_ms": cold.milliseconds, "key_p50_ms": percentile(0.5), "key_p95_ms": percentile(0.95),
            "key_max_ms": keys.last ?? 0, "footprint_before_mb": before, "footprint_after_start_mb": afterStart,
            "footprint_after_typing_mb": footprint(), "keys": Double(keys.count),
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("VIME_RIME_METRICS \(nineKey ? "nine_key" : "full_pinyin") " + String(decoding: data, as: UTF8.self))
        if let path {
            let output = URL(fileURLWithPath: path + (nineKey ? ".nine-key.json" : ""))
            try? data.write(to: output)
        }
    }

    private func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

private extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

private final class LockedStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [RimeState] = []
    var values: [RimeState] { lock.withLock { states } }
    func append(_ state: RimeState) { lock.withLock { states.append(state) } }
}
