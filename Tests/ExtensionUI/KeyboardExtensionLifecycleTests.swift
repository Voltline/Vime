import XCTest

/// Uses the installed extension in a separate process. Every round resigns
/// first responder, verifies disappearance, then focuses and types again.
@MainActor
final class KeyboardExtensionLifecycleTests: XCTestCase {
    func testPortraitHeightPreferenceSurvivesReconnectAndRotation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
            app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-height", "1"]
            app.launch()
        }
        var shortHeight: CGFloat?
        for factor in [0.85, 1.6, 1.0] {
            app.terminate()
            app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-height", String(factor),
                "--keyboard-extension-test-ranking", "engine"]
            app.launch()
            let editor = app.textViews["vime.extension.editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
            if !app.buttons["vime.key.h"].waitForExistence(timeout: 2) {
                let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                    ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
                for _ in 0..<6 {
                    guard !app.buttons["vime.key.h"].exists, globe.exists else { break }
                    globe.tap()
                    if app.buttons["vime.key.h"].waitForExistence(timeout: 2) { break }
                }
            }
            XCTAssertTrue(app.buttons["vime.key.h"].exists)
            let root = app.otherElements["vime.keyboard"]
            XCTAssertTrue(root.waitForExistence(timeout: 3))
            let height = root.frame.height
            print("VIME_HEIGHT_PREFERENCE factor=\(factor) input=\(root.frame)")
            if factor == 0.85 { shortHeight = height }
            if factor == 1.6 {
                XCTAssertGreaterThan(height - (try XCTUnwrap(shortHeight)), 100,
                    "The saved tall preference must resize the installed extension, not just its preview")
            }
            for round in 0..<3 {
                if round == 1 {
                    XCUIDevice.shared.orientation = .landscapeLeft
                    XCTAssertTrue(app.buttons["vime.key.return"].waitForExistence(timeout: 5))
                    XCUIDevice.shared.orientation = .portrait
                }
                app.buttons["vime.extension.dismiss"].tap()
                XCTAssertTrue(app.buttons["vime.key.h"].waitForNonExistence(timeout: 5))
                app.buttons["vime.extension.focus"].tap()
                XCTAssertTrue(app.buttons["vime.key.h"].waitForExistence(timeout: 5))
                let stableHeight = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    abs(root.frame.height - height) < 1
                }, object: root)
                XCTAssertEqual(XCTWaiter.wait(for: [stableHeight], timeout: 5), .completed,
                    "Reconnecting after rotation must restore the saved portrait height")
                XCTAssertTrue(app.buttons["vime.key.return"].isHittable)
            }
        }
    }

    func testSymbolCategorySwipesPreserveScrollingAndSelection() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-ranking", "engine",
            "--v21-extension-audit-on", "--v21-extension-audit-duration-seconds", "600",
            "--v21-extension-audit-sample-ms", "1000", "--v21-extension-audit-write-ms", "2000",
            "--v21-extension-audit-run-id", "emoji-fast-predictive-20261014"]
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.tap()
        // Component tests can leave iOS's selected input mode on English.
        // Select the installed extension through the same globe UI as a user.
        if !app.buttons["vime.key.h"].waitForExistence(timeout: 2) {
            let globe = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "下一个键盘", "Next keyboard"))
            for _ in 0..<6 {
                guard !app.buttons["vime.key.h"].exists, globe.firstMatch.exists else { break }
                globe.firstMatch.tap()
                if app.buttons["vime.key.h"].waitForExistence(timeout: 2) { break }
            }
        }
        XCTAssertTrue(app.buttons["vime.key.h"].waitForExistence(timeout: 5))
        app.buttons["表情"].tap()
        let grid = app.collectionViews["vime.symbols.grid"]
        let categories = app.scrollViews["vime.symbols.categories"]
        let modes = app.segmentedControls["vime.symbols.mode"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        func expectCategory(_ index: Int) {
            let tab = app.buttons["vime.symbols.category.\(index)"]
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: tab)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThanOrEqual(tab.frame.minX, categories.frame.minX - 1)
            XCTAssertLessThanOrEqual(tab.frame.maxX, categories.frame.maxX + 1)
        }
        func drag(_ dx: CGFloat, _ dy: CGFloat = 0) {
            let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)))
        }
        expectCategory(0)
        let before = editor.value as? String ?? ""
        XCTAssertTrue(grid.cells.count > 0)
        let smile = app.descendants(matching: .any)["vime.symbol.😀"]
        XCTAssertTrue(smile.waitForExistence(timeout: 5)); XCTAssertTrue(smile.isHittable)
        for _ in 0..<3 {
            grid.swipeLeft(velocity: .fast); grid.swipeRight(velocity: .fast)
        }
        XCTAssertEqual(editor.value as? String, before, "Fast fling/reversal never inserts a pending or reused emoji")
        app.buttons["vime.symbols.category.0"].tap(); expectCategory(0)
        drag(-150); expectCategory(0)
        XCTAssertFalse(smile.isHittable, "Scroll within a category rather than snapping to another tab")
        drag(0, -50); expectCategory(0)
        drag(-100, -30); expectCategory(0)
        XCTAssertEqual(editor.value as? String, before, "Continuous and diagonal dragging never inserts")
        app.buttons["vime.symbols.category.1"].tap(); expectCategory(1)
        let wave = app.descendants(matching: .any)["vime.symbol.👋"]
        XCTAssertTrue(wave.waitForExistence(timeout: 3)); XCTAssertTrue(wave.isHittable)
        wave.tap(); XCTAssertEqual(editor.value as? String, before + "👋")
        for index in 2...9 { app.buttons["vime.symbols.category.\(index)"].tap(); expectCategory(index) }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "emoji-continuous-flags"; attachment.lifetime = .keepAlways; add(attachment)
        // A mode tap lands on its first item. A continuous drag across that
        // boundary enters the preceding mode's final category, in either axis size.
        modes.buttons["颜文字"].tap(); expectCategory(0)
        drag(150); expectCategory(9); XCTAssertTrue(modes.buttons["Emoji"].isSelected)
        drag(-300); expectCategory(0); XCTAssertTrue(modes.buttons["颜文字"].isSelected)
        app.buttons["vime.symbols.category.1"].tap(); expectCategory(1)
        let sad = app.descendants(matching: .any)["vime.symbol.(T_T)"]
        XCTAssertTrue(sad.waitForExistence(timeout: 3)); sad.tap()
        for index in 2...7 { app.buttons["vime.symbols.category.\(index)"].tap(); expectCategory(index) }
        modes.buttons["符号"].tap(); expectCategory(0)
        drag(150); expectCategory(7); XCTAssertTrue(modes.buttons["颜文字"].isSelected)
        drag(-300); expectCategory(0); XCTAssertTrue(modes.buttons["符号"].isSelected)
        app.buttons["vime.symbols.category.1"].tap(); expectCategory(1)
        let arrow = app.descendants(matching: .any)["vime.symbol.↑"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 3)); arrow.tap()
        for index in 2...10 { app.buttons["vime.symbols.category.\(index)"].tap(); expectCategory(index) }
        drag(-150); expectCategory(10)
        modes.buttons["Emoji"].tap(); expectCategory(0)
        XCUIDevice.shared.orientation = .landscapeLeft
        for _ in 0..<3 {
            grid.swipeLeft(velocity: .fast); grid.swipeRight(velocity: .fast)
        }
        app.buttons["vime.symbols.category.0"].tap(); expectCategory(0)
        drag(-150); expectCategory(0)
        app.buttons["vime.symbols.category.1"].tap(); expectCategory(1)
        drag(-100, -25); expectCategory(1)
        XCTAssertEqual(editor.value as? String, before + "👋(T_T)↑")
        app.buttons["vime.symbols.close"].tap()
        XCTAssertTrue(app.buttons["vime.key.h"].waitForExistence(timeout: 3))
    }

    func testLandscapeMinimumHeightShowsAndTypesCompleteBottomRow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-height", "0.85"]
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
            app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-height", "1"]
            app.launch()
        }
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.buttons["vime.key.h"].waitForExistence(timeout: 5))
        for round in 1...3 {
            XCUIDevice.shared.orientation = round == 2 ? .landscapeRight : .landscapeLeft
            let space = app.buttons["vime.key.space"]
            let enter = app.buttons["vime.key.return"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: enter)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            XCTAssertTrue(space.isHittable)
            let firstRow = app.buttons["vime.key.q"]
            let lastFirstRow = app.buttons["vime.key.p"]
            let brand = app.buttons["vime.brand.settings"]
            let mode = app.buttons["切换平假名和片假名"]
            let arrow = app.buttons["vime.candidates.expand"]
            let keyPlaneRight = lastFirstRow.frame.maxX
            XCTAssertEqual(brand.frame.minX, firstRow.frame.minX, accuracy: 1)
            XCTAssertEqual(arrow.frame.maxX, lastFirstRow.frame.maxX, accuracy: 1)
            XCTAssertEqual(arrow.frame.minX - mode.frame.maxX, 8, accuracy: 1)
            func capture(_ state: String) {
                let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                attachment.name = "landscape-round-\(round)-\(state)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
            capture("idle")
            for control in [app.buttons["vime.brand.settings"], app.buttons["切换平假名和片假名"],
                            app.buttons["vime.candidates.expand"]] {
                XCTAssertTrue(control.isHittable)
                XCTAssertGreaterThanOrEqual(firstRow.frame.minY - control.frame.maxY, 8,
                    "Toolbar controls must not touch the first row")
            }
            app.buttons["vime.brand.settings"].tap()
            XCTAssertTrue(app.scrollViews["vime.settings"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["vime.panel.close"].frame.maxX, keyPlaneRight, accuracy: 1)
            capture("settings")
            app.buttons["vime.panel.close"].tap()
            XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
            for key in [space, enter] {
                XCTAssertTrue(app.frame.contains(key.frame))
                XCTAssertGreaterThanOrEqual(key.frame.height, 39)
                let input = app.otherElements["vime.keyboard"]
                let bottomSpace = input.frame.maxY - key.frame.maxY
                print("VIME_LANDSCAPE_GEOMETRY input=\(input.frame) key=\(key.frame) screen=\(app.frame)")
                XCTAssertGreaterThanOrEqual(bottomSpace, 1, "The complete key must remain inside its input view")
                XCTAssertLessThanOrEqual(bottomSpace, 2,
                    "Only the key margin belongs inside Vime; UIKit owns the bottom area outside it")
            }
            let previous = editor.value as? String ?? ""
            app.buttons["vime.key.a"].tap()
            capture("candidate-strip")
            app.buttons["vime.candidates.expand"].tap()
            XCTAssertTrue(app.scrollViews["vime.candidates.panel"].waitForExistence(timeout: 3))
            capture("expanded-candidates")
            app.buttons["vime.panel.close"].tap()
            XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
            space.tap()
            enter.tap()
            XCTAssertEqual(editor.value as? String, previous + "あ")
            XCTAssertEqual(app.staticTexts["vime.extension.marked"].label, "待确认文本：无")
            // The first return confirms the conversion; the second inserts a newline.
            enter.tap()
            XCTAssertEqual(editor.value as? String, previous + "あ\n")
            app.buttons["表情"].tap()
            let modes = app.segmentedControls["vime.symbols.mode"]
            XCTAssertTrue(modes.waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["vime.symbols.close"].frame.maxX, keyPlaneRight, accuracy: 1)
            capture("emoji")
            modes.buttons["颜文字"].tap()
            capture("kaomoji")
            modes.buttons["符号"].tap()
            capture("symbols")
            app.buttons["vime.symbols.close"].tap()
            XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
            XCTAssertTrue(enter.isHittable)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "landscape-minimum-height-round-\(round)"
            attachment.lifetime = .keepAlways; add(attachment)
            XCUIDevice.shared.orientation = .portrait
            app.buttons["vime.extension.dismiss"].tap()
            XCTAssertTrue(app.buttons["vime.key.h"].waitForNonExistence(timeout: 5))
            app.buttons["vime.extension.clear"].tap()
            XCTAssertEqual(editor.value as? String, "")
            app.buttons["vime.extension.focus"].tap()
            XCTAssertTrue(app.buttons["vime.key.h"].waitForExistence(timeout: 5))
        }
    }

    func testThreeHundredConstantContextOpenCloseCycles() throws {
        try exercise(ranking: "languageModel", cycles: 300, clearDocument: true)
    }

    func testSixtyConstantContextOpenCloseCycles() throws {
        try exercise(ranking: "languageModel", cycles: 60, clearDocument: true)
    }

    func testThirtyLanguageModelOpenCloseCycles() throws {
        try exercise(ranking: "languageModel", cycles: 30)
    }

    func testTenDictionaryOpenCloseCycles() throws {
        try exercise(ranking: "engine", cycles: 10)
    }

    func testTwentyFourMixedFeatureOpenCloseCycles() throws {
        try exercise(ranking: "languageModel", cycles: 24, mixedFeatures: true)
    }

    private func exercise(ranking: String, cycles: Int, clearDocument: Bool = false, mixedFeatures: Bool = false) throws {
        continueAfterFailure = false
        executionTimeAllowance = 3_600
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-extension-test", "--keyboard-extension-test-ranking", ranking,
            "--v21-extension-audit-on", "--v21-extension-audit-duration-seconds", "3600",
            "--v21-extension-audit-sample-ms", "1000", "--v21-extension-audit-write-ms", "5000",
            "--v21-extension-audit-run-id", "lifecycle-\(cycles)-" + ranking]
        app.launch()
        let editor = app.textViews["vime.extension.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        if !app.buttons["vime.key.h"].waitForExistence(timeout: 3) {
            let globe = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Next keyboard", "下一键盘", "下一个键盘", "切换系统键盘", "次のキーボード"] as NSArray)).firstMatch
            for _ in 0..<6 {
                guard !app.buttons["vime.key.h"].exists, globe.exists else { break }
                globe.tap()
                _ = app.buttons["vime.key.h"].waitForExistence(timeout: 1)
            }
        }
        XCTAssertTrue(app.buttons["vime.key.h"].exists, "The actual extension must be enabled in this simulator")
        let began = ProcessInfo.processInfo.systemUptime
        for cycle in 1...cycles {
            XCTAssertTrue(app.buttons["vime.key.h"].exists, "Vime was replaced before cycle \(cycle)")
            let previous = editor.value as? String ?? ""
            let readings = [("hashi", "はし"), ("nihongo", "にほんご"),
                ("ashitanokaiginisankashimasu", "あしたのかいぎにさんかします"), ("tennanhantenn", "てんあんはんてん")]
            // The long run measures creation/teardown. Warm the neural model
            // with an ambiguous reading first, then keep each round short and
            // identical; the mixed run separately stresses richer input.
            let (roman, kana) = mixedFeatures ? readings[(cycle - 1) % readings.count]
                : (cycles >= 300 && cycle > 1 ? ("a", "あ") : readings[0])
            print("VIME_EXTENSION_PHASE cycle=\(cycle) phase=typing seconds=\(Int(ProcessInfo.processInfo.systemUptime - began))")
            for character in roman { app.buttons["vime.key.\(character)"].tap() }
            XCTAssertEqual(editor.value as? String, previous + kana)
            if mixedFeatures {
                print("VIME_EXTENSION_PHASE cycle=\(cycle) phase=candidate_panel seconds=\(Int(ProcessInfo.processInfo.systemUptime - began))")
                app.buttons["vime.candidates.expand"].tap()
                let panel = app.scrollViews["vime.candidates.panel"]
                XCTAssertTrue(panel.waitForExistence(timeout: 3))
                panel.swipeUp()
                app.buttons["vime.panel.close"].tap()
            }
            if roman != "a" { app.buttons["vime.key.space"].tap() }
            app.buttons["vime.key.return"].tap()
            XCTAssertNotEqual(editor.value as? String, previous)
            XCTAssertEqual(app.staticTexts["vime.extension.marked"].label, "待确认文本：无")
            if mixedFeatures && cycle.isMultiple(of: 4) {
                print("VIME_EXTENSION_PHASE cycle=\(cycle) phase=symbol_panel seconds=\(Int(ProcessInfo.processInfo.systemUptime - began))")
                app.buttons["表情"].tap()
                let modes = app.segmentedControls["vime.symbols.mode"]
                XCTAssertTrue(modes.waitForExistence(timeout: 3))
                modes.buttons["颜文字"].tap()
                modes.buttons["符号"].tap()
                app.buttons["vime.symbols.close"].tap()
            }
            let committed = editor.value as? String
            app.buttons["vime.extension.dismiss"].tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                object: app.buttons["vime.key.h"])
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed,
                "Cycle \(cycle) must really close the extension")
            XCTAssertEqual(editor.value as? String, committed)
            if clearDocument {
                // Hold the prompt length constant to distinguish lifecycle
                // growth from Core ML workspaces for progressively longer text.
                app.buttons["vime.extension.clear"].tap()
                XCTAssertEqual(editor.value as? String, "")
            }
            if mixedFeatures && cycle.isMultiple(of: 6) {
                XCUIDevice.shared.orientation = cycle.isMultiple(of: 12) ? .portrait : .landscapeLeft
            }
            app.buttons["vime.extension.focus"].tap()
            // Do not switch back using the globe after initial setup: fallback
            // to the native keyboard is a failure, not a recoverable test step.
            XCTAssertTrue(app.buttons["vime.key.h"].waitForExistence(timeout: 5),
                "Vime did not reopen at cycle \(cycle)")
            XCTAssertEqual(editor.value as? String, clearDocument ? "" : committed, "Reopening must preserve the host document")
            print("VIME_EXTENSION_LIFECYCLE ranking=\(ranking) constant_context=\(clearDocument) cycle=\(cycle) seconds=\(Int(ProcessInfo.processInfo.systemUptime - began))")
        }
        app.buttons["vime.extension.dismiss"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "lifecycle-" + ranking + "-completed"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
