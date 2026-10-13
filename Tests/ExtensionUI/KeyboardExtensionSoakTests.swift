import XCTest

/// Explicitly opt in with VIME_SOAK_SECONDS in the xctestrun environment.
/// Every character is a tap on the installed keyboard, never injected host text.
@MainActor
final class KeyboardExtensionSoakTests: XCTestCase {
    func testContinuousInstalledExtensionSoak() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let seconds = environment["VIME_SOAK_SECONDS"].flatMap(Double.init),
              seconds.isFinite, (60...1_500).contains(seconds) else {
            throw XCTSkip("Opt-in device soak: set VIME_SOAK_SECONDS to 60...1500")
        }
        let ranking = environment["VIME_SOAK_RANKING"] == "engine" ? "engine" : "languageModel"
        let runID = "simulator-soak-" + ranking
        executionTimeAllowance = seconds + 240
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-ranking", ranking,
            "--v21-extension-audit-on", "--v21-extension-audit-duration-seconds", "1800",
            "--v21-extension-audit-sample-ms", "1000", "--v21-extension-audit-write-ms", "15000",
            "--v21-extension-audit-run-id", runID]
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        if !app.buttons["vime.key.t"].waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
            for _ in 0..<6 {
                guard !app.buttons["vime.key.t"].exists, globe.exists else { break }
                globe.tap()
                _ = app.buttons["vime.key.t"].waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(app.buttons["vime.key.t"].exists, "Enable the actual extension before running the soak")
        let began = ProcessInfo.processInfo.systemUptime
        var lastCheckpoint = began
        var cycles = 0
        var keyTaps = 0
        var menuSelections = 0
        var nonemptySuggestionObservations = 0
        let corpus = [("nihongo", "にほんご"), ("shizuka", "しずか"), ("shitsuka", "しつか"),
            ("desu", "です"), ("dedu", "でづ"), ("yo-roppa", "よーろっぱ"), ("be-to-ben", "べーとーべn"),
            ("tennanhantenn", "てんあんはんてん"),
            ("watashihanihongowobenkyoushiteimasu", "わたしはにほんごをべんきょうしています"),
            ("arigatou", "ありがとう"), ("gakkou", "がっこう"), ("konpyu-ta", "こんぴゅーた")]
        defer {
            let data: [String: Any] = ["ranking": ranking, "requested_seconds": seconds,
                "active_seconds": ProcessInfo.processInfo.systemUptime - began, "cycles": cycles,
                "key_taps": keyTaps, "expanded_selections": menuSelections,
                "nonempty_next_word_observations": nonemptySuggestionObservations,
                "note": "XCTest tapping is slower than human bursts; internal extension timings exclude its IPC overhead"]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
                print("VIME_SOAK_SUMMARY " + String(decoding: json, as: UTF8.self))
                let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
                attachment.name = runID; attachment.lifetime = .keepAlways; add(attachment)
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = runID + "-final"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        func markIsClear() -> Bool { app.staticTexts["vime.extension.marked"].label == "待确认文本：无" }
        func expectClearMark() {
            let clear = NSPredicate { _, _ in markIsClear() }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: clear, object: editor)], timeout: 5), .completed,
                "Committed word must leave no marked remainder")
        }
        while ProcessInfo.processInfo.systemUptime - began < seconds {
            // If iOS replaces the extension, fail at the next cycle, without
            // switching back and hiding a genuine termination from the result.
            XCTAssertTrue(app.buttons["vime.key.t"].exists, "Keyboard was replaced during the soak")
            expectClearMark()
            let before = editor.value as? String ?? ""
            let (word, reading) = corpus[cycles % corpus.count]
            for character in word {
                let identifier = character == "-" ? "vime.key.prolonged" : "vime.key." + String(character)
                app.buttons[identifier].tap()
                keyTaps += 1
            }
            XCTAssertFalse(markIsClear(), "The real host must receive marked text for \(word)")
            XCTAssertEqual(editor.value as? String, before + reading, "Typing must preserve the existing host document")
            XCTAssertEqual(app.staticTexts["vime.extension.marked"].label, "待确认文本：" + reading)
            // Five and twelve are coprime: every corpus entry reaches both
            // the expanded menu and the regular strip across successive passes.
            if cycles.isMultiple(of: 5) {
                app.buttons["vime.candidates.expand"].tap()
                let panel = app.scrollViews["vime.candidates.panel"]
                XCTAssertTrue(panel.waitForExistence(timeout: 5))
                let candidate = panel.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "候选词：")).firstMatch
                XCTAssertTrue(candidate.waitForExistence(timeout: 5))
                let ready = NSPredicate { _, _ in candidate.exists && candidate.isHittable && candidate.isEnabled }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: candidate)], timeout: 5), .completed)
                candidate.tap()
                menuSelections += 1
                // A partial candidate legitimately leaves a marked remainder.
                // Commit that remainder explicitly rather than pretending that
                // selecting the first segment should finish the entire input.
                if !markIsClear() {
                    if app.buttons["vime.panel.close"].exists { app.buttons["vime.panel.close"].tap() }
                    app.buttons["vime.key.return"].tap(); keyTaps += 1
                }
            } else {
                app.buttons["vime.key.space"].tap()
                let selectedHostText = editor.value as? String
                app.buttons["vime.key.return"].tap()
                keyTaps += 2
                XCTAssertEqual(editor.value as? String, selectedHostText, "Confirmation must not duplicate the selected preedit")
            }
            expectClearMark()
            XCTAssertNotEqual(editor.value as? String, before, "Commit must change the actual host document")
            // Give confirmation feedback / next-word generation time to run.
            // This bounded pause models vocabulary entry and is not a debounce.
            Thread.sleep(forTimeInterval: 1.8)
            if app.scrollViews["vime.candidates"].buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "候选词：")).count > 0 {
                nonemptySuggestionObservations += 1
            }
            if cycles % 4 == 2 {
                app.buttons["vime.key.delete"].tap(); keyTaps += 1
                expectClearMark()
            }
            cycles += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCheckpoint >= 60 {
                print("VIME_SOAK_PROGRESS ranking=\(ranking) elapsed=\(Int(now - began)) cycles=\(cycles) keyTaps=\(keyTaps)")
                lastCheckpoint = now
            }
        }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - began, seconds)
        XCTAssertGreaterThan(cycles, 1)
        XCTAssertTrue(app.buttons["vime.key.t"].exists)
        expectClearMark()
    }
}
