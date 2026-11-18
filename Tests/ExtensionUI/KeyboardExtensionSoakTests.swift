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
        if !app.keys["vime.key.t"].waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
            for _ in 0..<15 {
                guard !app.keys["vime.key.t"].exists, globe.exists else { break }
                globe.tap()
                _ = app.keys["vime.key.t"].waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(app.keys["vime.key.t"].exists, "Enable the actual extension before running the soak")
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
            XCTAssertTrue(app.keys["vime.key.t"].exists, "Keyboard was replaced during the soak")
            expectClearMark()
            let before = editor.value as? String ?? ""
            let (word, reading) = corpus[cycles % corpus.count]
            for character in word {
                let identifier = character == "-" ? "vime.key.prolonged" : "vime.key." + String(character)
                app.keys[identifier].tap()
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
                    app.keys["vime.key.return"].tap(); keyTaps += 1
                }
            } else {
                app.keys["vime.key.space"].tap()
                let selectedHostText = editor.value as? String
                app.keys["vime.key.return"].tap()
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
                app.keys["vime.key.delete"].tap(); keyTaps += 1
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
        XCTAssertTrue(app.keys["vime.key.t"].exists)
        expectClearMark()
    }

    /// Chinese pinyin on the installed keyboard: whole sentences (some with
    /// a slip) for the sentence scoring, short words, the expanded menu and
    /// deletions. Opt in with VIME_ZH_SOAK_SECONDS (60...3600).
    func testContinuousInstalledChineseSoak() throws {
        guard let seconds = ProcessInfo.processInfo.environment["VIME_ZH_SOAK_SECONDS"].flatMap(Double.init),
              seconds.isFinite, (60...3_600).contains(seconds) else {
            throw XCTSkip("Opt-in device soak: set VIME_ZH_SOAK_SECONDS to 60...3600")
        }
        let runID = "device-soak-chinese"
        executionTimeAllowance = seconds + 300
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test", "--keyboard-input-language", "chinese",
            "--v21-extension-audit-on", "--v21-extension-audit-duration-seconds", String(Int(seconds) + 300),
            "--v21-extension-audit-sample-ms", "1000", "--v21-extension-audit-write-ms", "15000",
            "--v21-extension-audit-run-id", runID]
        app.launch()
        // Chinese keys need not be reported as keys: look them up by identifier.
        func key(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        if !key("vime.key.t").waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
            for _ in 0..<15 {
                guard !key("vime.key.t").exists, globe.exists else { break }
                globe.tap()
                _ = key("vime.key.t").waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(key("vime.key.t").exists, "Enable the actual extension before running the soak")
        let corpus = ["womenjintianxiawusandianzaigongsilouxiajianmian", "nihao", "xiexie",
            "ranhouyiqiqukandianying", "wodeshoujikuaimeidianle", "mingtianzaoshangjiudiankaihui",
            "zhegewentiwomenxuyaozaitaolunyixia", "zhongwen", "shurufa", "wanshangyiqichifanma",
            "tamenyijingdaolejichangle", "zhegegongnenghenhaoyong", "jitian", "wohenxihuanzhegedifang",
            "xianzaiqushijianhaishilaidejide", "qingbangwokanyixiazhegewenjian", "shijian", "dianhua",
            "zuotianxiayulesuoyimeiyouchumen", "zhouweiwomenqupashanba", "jintiantianqizhenbucuo",
            "nikebukeyibangwomaiyibeikafei", "zhegexiangmudejindutaimanle", "kuaidiyijingfangzaimenkoule"]
        let began = ProcessInfo.processInfo.systemUptime
        var lastCheckpoint = began
        var cycles = 0, keyTaps = 0, menuSelections = 0, unchanged = 0, languageSwitches = 0
        let switches = ProcessInfo.processInfo.environment["VIME_ZH_SOAK_SWITCH"] == "1"
        defer {
            let data: [String: Any] = ["requested_seconds": seconds, "active_seconds": ProcessInfo.processInfo.systemUptime - began,
                "cycles": cycles, "key_taps": keyTaps, "expanded_selections": menuSelections, "unchanged_commits": unchanged,
                "language_switches": languageSwitches]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
                print("VIME_SOAK_SUMMARY " + String(decoding: json, as: UTF8.self))
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = runID + "-final"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        while ProcessInfo.processInfo.systemUptime - began < seconds {
            XCTAssertTrue(key("vime.key.t").exists, "Keyboard was replaced during the soak")
            let before = editor.value as? String ?? ""
            let pinyin = corpus[cycles % corpus.count]
            for character in pinyin { key("vime.key." + String(character)).tap(); keyTaps += 1 }
            // Let the ranking and sentence scoring of the whole input run.
            Thread.sleep(forTimeInterval: 0.8)
            if cycles.isMultiple(of: 5), app.buttons["vime.candidates.expand"].exists {
                app.buttons["vime.candidates.expand"].tap()
                let panel = app.scrollViews["vime.candidates.panel"]
                let candidate = panel.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "候选词：")).firstMatch
                if candidate.waitForExistence(timeout: 5), candidate.isHittable {
                    candidate.tap(); menuSelections += 1
                } else if app.buttons["vime.panel.close"].exists { app.buttons["vime.panel.close"].tap() }
            }
            // Commit whatever is left: space takes the first candidate each time.
            for _ in 0..<6 where !(app.staticTexts["vime.extension.marked"].label == "待确认文本：无") {
                key("vime.key.space").tap(); keyTaps += 1
                Thread.sleep(forTimeInterval: 0.3)
            }
            if editor.value as? String == before { unchanged += 1 }
            Thread.sleep(forTimeInterval: 1.2)
            if cycles % 4 == 2 { key("vime.key.delete").tap(); keyTaps += 1 }
            // Keep the host document short: a long one slows every query of it.
            if cycles % 12 == 11 {
                for _ in 0..<60 where !((editor.value as? String) ?? "").isEmpty {
                    key("vime.key.delete").press(forDuration: 1.5)
                }
            }
            // With VIME_ZH_SOAK_SWITCH, a few Japanese words every sixth
            // sentence: swipe up on the language key there and back.
            // A short drag up from the key's centre: XCUI's swipeUp travels
            // too far and too fast for the key's flick.
            func flickLanguageKey() {
                let centre = key("vime.key.language").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                // A slow drag, like a thumb: a fast synthetic one ends before the key reads it as a flick.
                centre.press(forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: 0, dy: -36)),
                             withVelocity: 200, thenHoldForDuration: 0.05)
            }
            if switches, cycles % 5 == 4, key("vime.key.language").exists {
                flickLanguageKey()
                Thread.sleep(forTimeInterval: 0.5)
                for word in ["arigatou", "konnichiha"] {
                    for character in word { key("vime.key." + String(character)).tap(); keyTaps += 1 }
                    Thread.sleep(forTimeInterval: 0.8)
                    key("vime.key.space").tap(); key("vime.key.return").tap(); keyTaps += 2
                }
                flickLanguageKey()
                Thread.sleep(forTimeInterval: 0.5)
                languageSwitches += 2
            }
            cycles += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCheckpoint >= 60 {
                print("VIME_SOAK_PROGRESS chinese elapsed=\(Int(now - began)) cycles=\(cycles) keyTaps=\(keyTaps) unchanged=\(unchanged)")
                lastCheckpoint = now
            }
        }
        XCTAssertLessThan(unchanged, max(cycles / 4, 2), "Most sentences must reach the host")
        XCTAssertTrue(key("vime.key.t").exists)
    }
}
