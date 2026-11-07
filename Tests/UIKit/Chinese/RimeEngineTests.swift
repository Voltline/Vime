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
        let requests = KeyboardLearningResetRequests(defaults: defaults)
        let engine = RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData), userDirectory: Self.user, resetRequests: requests)
        func rank() -> Int? {
            let index = engine.sendAndWait(.type("shi")).candidates.firstIndex { $0.text == "式" }
            _ = engine.sendAndWait(.clear)
            return index
        }
        let before = try XCTUnwrap(rank())
        for _ in 0..<3 {
            let index = try XCTUnwrap(engine.sendAndWait(.type("shi")).candidates.firstIndex { $0.text == "式" })
            XCTAssertEqual(engine.sendAndWait(.select(index)).commit, "式")
            _ = engine.sendAndWait(.finishLearning)
        }
        XCTAssertLessThan(try XCTUnwrap(rank()), before)
        requests.request()
        _ = engine.sendAndWait(.clear)
        XCTAssertEqual(rank(), before)
        XCTAssertNil(requests.pendingID(for: "rime." + Self.user.lastPathComponent))
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

/// Phase 0 numbers: cold start, per-key time and memory. Runs only when
/// TEST_RUNNER_VIME_RIME_METRICS names an output file.
final class RimeEngineMetricsTests: XCTestCase {
    func testMeasure() throws {
        let path = ProcessInfo.processInfo.environment["VIME_RIME_METRICS"]
        try XCTSkipIf(path == nil, "set TEST_RUNNER_VIME_RIME_METRICS to measure")
        let output = URL(fileURLWithPath: try XCTUnwrap(path))
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("RimeMetrics-\(UUID().uuidString)")
        let before = footprint()
        let engine = RimeEngine(data: try XCTUnwrap(RimeEngine.bundledData), userDirectory: user)
        let cold = engine.sendAndWait(.type("n")).duration
        let afterStart = footprint()
        _ = engine.sendAndWait(.clear)
        let sentences = ["nihao", "womenyiqiqukandianying", "jintiantianqizhenhao", "zhonghuarenmingongheguo",
                         "woxiangmaiyibuxinshouji", "zhegewentiwozaixiangxiang", "xiawusandiankaihui", "zg", "bjdx",
                         "shurufa", "ruguoniyouwenti", "qingbawenjianfageiwo"]
        var keys: [Double] = []
        for _ in 0..<5 {
            for sentence in sentences {
                for letter in sentence { keys.append(engine.sendAndWait(.type(String(letter))).duration.milliseconds) }
                keys.append(engine.sendAndWait(.select(0)).duration.milliseconds)
            }
        }
        keys.sort()
        func percentile(_ p: Double) -> Double { keys[min(keys.count - 1, Int(Double(keys.count) * p))] }
        let report: [String: Double] = [
            "cold_start_ms": cold.milliseconds, "key_p50_ms": percentile(0.5), "key_p95_ms": percentile(0.95),
            "key_max_ms": keys.last ?? 0, "footprint_before_mb": before, "footprint_after_start_mb": afterStart,
            "footprint_after_typing_mb": footprint(), "keys": Double(keys.count),
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
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
