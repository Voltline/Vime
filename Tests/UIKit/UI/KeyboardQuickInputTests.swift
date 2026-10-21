import XCTest
import UIKit

@MainActor
final class KeyboardQuickInputTests: XCTestCase {
    func testConcurrentBackgroundPreparationLeavesOnlyCacheLookupsForMainThread() async {
        let identifier = UUID().uuidString
        let values = (0..<64).map { index in
            var value = CandidatePresentation(text: "\(identifier)·\(index)ㇱ日本語", source: .conversion,
                consumedInputCount: 1, correction: nil)
            value.detailAnnotation = "注釈 \(identifier) \(index)"
            return value
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                DispatchQueue.concurrentPerform(iterations: 8) { _ in
                    for value in values { KeyboardCandidateTextMetrics.prepare(value, first: true) }
                }
                continuation.resume()
            }
        }
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        for value in values {
            for font in [UIFont.systemFont(ofSize: 18), .systemFont(ofSize: 18, weight: .medium)] {
                XCTAssertGreaterThan(KeyboardCandidateTextMetrics.width(of: value.text, font: font), 0)
            }
            XCTAssertGreaterThan(KeyboardCandidateTextMetrics.width(of: value.annotation!, font: .systemFont(ofSize: 10)), 0)
        }
        let report = KeyboardPerformance.report()
        XCTAssertNil(report["candidateTextLayout"], "UI must reuse all prepared widths even after concurrent cache misses")
        XCTAssertEqual(report["candidateWidthCacheLookup"]?["totalCount"], 192)
    }

    func testCandidateMetricsPreserveJapaneseLatinEmojiAndAnnotationWidths() {
        for font in [UIFont.systemFont(ofSize: 18), .systemFont(ofSize: 18, weight: .medium), .systemFont(ofSize: 10)] {
            for text in ["日本語", "ひらがな", "半角片假名 · 部分转换", "GitHub 123", "ｶﾞｯｺｳ", "ㇱㇿ", "2️⃣", "👨‍👩‍👧‍👦", "1+1=2", "長い候補\n短い", " "] {
                let reference = (text as NSString).size(withAttributes: [.font: font]).width
                let measured = KeyboardCandidateTextMetrics.width(of: text, font: font)
                XCTAssertEqual(ceil(measured), ceil(reference), accuracy: 1, text)
                XCTAssertEqual(KeyboardCandidateTextMetrics.width(of: text, font: font), measured, "Cached widths must preserve the font weight and size")
            }
        }
    }
    func testNumberRailOwnsVerticalScrollingAndReloadsAppSymbolsWithoutChangingHeight() async throws {
        let fixture = try await Fixture(english: true)
        defer { fixture.close() }
        let height = fixture.keyboard.preferredHeight(for: 440)
        try fixture.tapKey(title: "123")
        let rail = try XCTUnwrap(fixture.descendants.compactMap { $0 as? KeyboardNumberSymbolRail }.first)
        let surface = try XCTUnwrap(fixture.descendants.compactMap { $0 as? KeyboardTouchSurface }.first)
        XCTAssertFalse(rail.isHidden)
        XCTAssertEqual(rail.symbols, fixture.preferences.numberSymbols)
        XCTAssertGreaterThan(rail.contentSize.height, rail.bounds.height)
        let symbol = try fixture.button("vime.number.+")
        let point = symbol.convert(CGPoint(x: symbol.bounds.midX, y: symbol.bounds.midY), to: fixture.keyboard)
        XCTAssertNil(surface.resolvedKey(at: point), "The rail must never activate key-plane cursor gestures")
        XCTAssertTrue(try XCTUnwrap(fixture.keyboard.hitTest(point, with: nil)).isDescendant(of: rail))
        try fixture.tapKey(id: "vime.number.+")
        XCTAssertEqual(fixture.text.text, "+")
        fixture.preferences.numberSymbols = ["¥", "(", "00", "%", "=", "§"]
        fixture.keyboard.reloadPreferences(); fixture.keyboard.layoutIfNeeded(); rail.layoutIfNeeded()
        XCTAssertEqual(rail.symbols, ["¥", "(", "00", "%", "=", "§"])
        XCTAssertEqual(rail.contentOffset.y, 0)
        XCTAssertFalse(fixture.descendants.contains { $0.accessibilityIdentifier == "vime.number.+" })
        try fixture.tapKey(id: "vime.number.00")
        XCTAssertEqual(fixture.text.text, "+00")
        XCTAssertEqual(fixture.keyboard.preferredHeight(for: 440), height)
        let one = try fixture.button("vime.number.1"), nine = try fixture.button("vime.number.9")
        XCTAssertEqual(rail.frame.minY, one.frame.minY)
        XCTAssertEqual(rail.frame.maxY, nine.frame.maxY)
        let image = UIGraphicsImageRenderer(bounds: fixture.keyboard.bounds).image { fixture.keyboard.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "数字键盘-连续符号栏"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSelectedCandidateUsesTextUnderlineAndKeepsBottomEmojiEntry() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        for letter in "nihongo" { try fixture.tapKey(id: "vime.key." + String(letter)) }
        let candidate = try XCTUnwrap(fixture.descendants.compactMap { $0 as? KeyboardCandidateButton }.first { $0.tag == 0 })
        let underline = try XCTUnwrap(candidate.subviews.first { $0.accessibilityIdentifier == "vime.candidate.underline" })
        candidate.layoutIfNeeded()
        XCTAssertFalse(underline.isHidden)
        XCTAssertEqual(underline.bounds.height, 2)
        let title = try XCTUnwrap(candidate.titleLabel)
        let textBottom = candidate.convert(title.bounds, from: title).maxY
        XCTAssertGreaterThanOrEqual(underline.frame.minY, textBottom, "The line stays below the glyphs")
        XCTAssertLessThanOrEqual(underline.frame.minY - textBottom, KeyboardCandidateButton.underlineGap + 4,
            "The line hugs the candidate text instead of the key row")
        XCTAssertLessThan(underline.frame.maxY, candidate.bounds.maxY - 4)
        let emoji = try XCTUnwrap(fixture.descendants.first { $0.accessibilityLabel == "表情" })
        XCTAssertFalse(emoji.isHidden)
        XCTAssertGreaterThan(emoji.frame.minY, candidate.frame.maxY)
    }
    func testDecimalArithmeticPrecedenceNegativeParenthesesPercentAndFullWidth() throws {
        let examples = ["1+1": "2", "1+2*3": "7", "(1+2)*3": "9", "0.1+0.2": "0.3",
            "-2*-3": "6", "10/4": "2.5", "200*10%": "20", "50%": "0.5",
            "１＋２×（３−１）": "5", "1+1=": "2", ".5+.25": "0.75", "1--2": "3"]
        for (expression, expected) in examples {
            XCTAssertEqual(KeyboardCalculation.evaluate(expression)?.result, expected, expression)
        }
        XCTAssertEqual(KeyboardCalculation.trailing(in: "合計は 1+1")?.equation, "1+1=2")
        XCTAssertEqual(KeyboardCalculation.trailing(in: "total 1+1")?.result, "2")
        XCTAssertEqual(KeyboardCalculation.evaluate("１＋１＝")?.equation, "１＋１＝2")
    }

    func testIncompleteUnsafeAndOverlongExpressionsDoNotOfferPartialResults() {
        for expression in ["", "123", "1+", "1/0", "(1+2", "1..2+3", "1+1=2", "1e2+1",
            "1+foo()", "pow(2,3)", String(repeating: "(", count: 17) + "1+2" + String(repeating: ")", count: 17),
            String(repeating: "1+", count: 70) + "2"] {
            XCTAssertNil(KeyboardCalculation.evaluate(expression), expression)
        }
        for text in ["orderABC1+2", "1+2 ", "1+1=2", "3\n2", String(repeating: "1+", count: 70) + "2"] {
            XCTAssertNil(KeyboardCalculation.trailing(in: text), text)
        }
    }

    func testClipboardRequiresOptInAndFullAccessReadsChangedVersionsOnceAndBoundsStorage() async {
        var version = 1, reads = 0, metadataReads = 0
        var value: String? = " first\nsecond "
        let clipboard = KeyboardClipboard(changeCount: { metadataReads += 1; return version }, readText: { reads += 1; return value }, history: ClipboardHistoryStore(inMemory: true))
        clipboard.checkForChanges(enabled: false, hasFullAccess: true)
        clipboard.checkForChanges(enabled: true, hasFullAccess: false)
        XCTAssertEqual(metadataReads, 0); XCTAssertEqual(reads, 0)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        XCTAssertEqual(clipboard.text, value)
        for _ in 0..<10 { clipboard.checkForChanges(enabled: true, hasFullAccess: true) }
        XCTAssertEqual(reads, 1)
        version += 1; value = nil // An image, empty clipboard or denied read.
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        clipboard.clear()
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        XCTAssertNil(clipboard.text); XCTAssertEqual(reads, 2, "A denied/empty read is not retried on every show")
        version += 1; value = String(repeating: "あ", count: 30_000)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        XCTAssertNil(clipboard.text, "Oversized text must not be truncated and offered as if complete")
        version += 1; value = " \n\t "
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        XCTAssertNil(clipboard.text)
        version += 1; value = "latest"
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        clipboard.checkForChanges(enabled: false, hasFullAccess: true)
        XCTAssertNil(clipboard.text)
    }

    func testAsyncClipboardRejectsSupersededAndCancelledLoads() async {
        var version = 1
        var completions: [(String?) -> Void] = []
        var progress: [Progress] = []
        let clipboard = KeyboardClipboard(changeCount: { version }, loadText: { complete in
            completions.append(complete)
            let load = Progress(totalUnitCount: 1); progress.append(load); return load
        }, history: ClipboardHistoryStore(inMemory: true))
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await waitUntil { completions.count == 1 }
        XCTAssertEqual(completions.count, 1, "A pending read must not start another permission request")
        version += 1
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        XCTAssertEqual(completions.count, 1, "Slow loads must not pile up even when the clipboard changes")
        completions[0]("old")
        XCTAssertNil(clipboard.text)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await waitUntil { completions.count == 2 }
        completions[1]("latest")
        await settle(clipboard)
        XCTAssertEqual(clipboard.text, "latest")
        version += 1
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await waitUntil { completions.count == 3 }
        clipboard.checkForChanges(enabled: false, hasFullAccess: true)
        XCTAssertTrue(progress[2].isCancelled)
        completions[2]("late after opt-out")
        XCTAssertNil(clipboard.text)
    }

    func testSystemTextProviderLoadsAsynchronouslyWithoutChangingMultilineText() async {
        let original = "👩🏽‍💻 first\n二行目\t "
        let provider = NSItemProvider(object: original as NSString)
        let ready = expectation(description: "Text item provider")
        let progress = KeyboardClipboard.loadText(from: provider) { value in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(value, original)
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 3)
        withExtendedLifetime(progress) {}
    }

    func testNumericPageImmediatelyOffersSymbolsAndBothResultsReplaceWholeExpression() async throws {
        for english in [false, true] {
            for choice in [0, 1] {
                let fixture = try await Fixture(english: english)
                defer { fixture.close() }
                fixture.text.text = "前文👩🏽‍💻 "; fixture.text.selectedRange = NSRange(location: fixture.text.text.utf16.count, length: 0)
                try fixture.tapKey(title: "123")
                XCTAssertFalse(try fixture.button("vime.quickSymbol.(").isHidden)
                for digit in ["1", "+", "1"] { try fixture.tapKey(id: "vime.number." + digit) }
                XCTAssertEqual(fixture.text.text, "前文👩🏽‍💻 1+1")
                let result = try fixture.button("vime.calculation.\(choice)")
                XCTAssertEqual(result.title(for: .normal), choice == 0 ? "2" : "1+1=2")
                result.sendActions(for: .touchDown); result.sendActions(for: .touchUpInside)
                XCTAssertEqual(fixture.text.text, "前文👩🏽‍💻 " + (choice == 0 ? "2" : "1+1=2"))
                XCTAssertNil(fixture.text.markedTextRange)
                XCTAssertFalse(fixture.session.isComposing)
                XCTAssertTrue(try fixture.button("vime.brand.settings").isHidden)
                try fixture.tapKey(title: "ABC")
                XCTAssertFalse(try fixture.button("vime.brand.settings").isHidden)
            }
        }
    }

    func testMinusDoesNotBecomeJapaneseProlongedSoundAndSymbolsRemainAvailable() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        try fixture.tapKey(title: "123")
        for value in ["3", "-", "1"] { try fixture.tapKey(id: "vime.number." + value) }
        XCTAssertEqual(fixture.text.text, "3-1")
        let result = try fixture.button("vime.calculation.0")
        XCTAssertEqual(result.title(for: .normal), "2")
        result.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, "2")
        try fixture.button("vime.quickSymbol.(").sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, "2()")
        XCTAssertEqual(fixture.text.selectedRange.location, 2)
    }

    func testPairedBracketsNestAtCaretAndCanBeDisabledWithoutChangingPaste() async throws {
        let fixture = try await Fixture(english: true, clipboardText: "(literal)")
        defer { fixture.close() }
        try fixture.tapKey(title: "123")
        for _ in 0..<2 { try fixture.button("vime.quickSymbol.(").sendActions(for: .touchUpInside) }
        XCTAssertEqual(fixture.text.text, "(())")
        XCTAssertEqual(fixture.text.selectedRange, NSRange(location: 2, length: 0))
        try fixture.tapKey(id: "vime.number.1")
        XCTAssertEqual(fixture.text.text, "((1))")
        fixture.preferences.autoPairBrackets = false
        fixture.keyboard.reloadPreferences()
        try fixture.button("vime.quickSymbol.(").sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, "((1())")
        XCTAssertEqual(fixture.text.selectedRange.location, 4)
        try fixture.tapKey(title: "ABC")
        try fixture.button("vime.clipboard.paste").sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, "((1((literal)))")
    }

    func testPairConfirmsNumericCompositionAndContinuesInsideJapaneseBrackets() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        try fixture.tapKey(title: "123")
        for value in ["1", "2"] { try fixture.tapKey(id: "vime.number." + value) }
        try fixture.button("vime.quickSymbol.「").sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, "12「」")
        XCTAssertEqual(fixture.text.selectedRange.location, 3)
        XCTAssertNil(fixture.host.markedText)
        try fixture.tapKey(id: "vime.number.3")
        XCTAssertEqual(fixture.text.text, "12「3」")
        XCTAssertEqual(fixture.host.markedText, "3")
    }

    func testPairReceiptRecognizesBothSidesOfOwnCaretMoveAndRejectsExternalNavigation() throws {
        var receipt = try XCTUnwrap(KeyboardPartialCommitReceipt(document: "A", before: "前文12", after: "tail",
            selection: nil, ownedMark: "12", edits: [.insert("12"), .insertPair(opening: "「", closing: "」")], preedit: nil))
        XCTAssertTrue(receipt.acknowledges(document: "A", before: "前文12「」", after: "tail", selection: nil))
        XCTAssertTrue(receipt.acknowledges(document: "A", before: "前文12「", after: "」tail", selection: nil))
        receipt.updatePreedit(.init(text: "あ"))
        XCTAssertTrue(receipt.acknowledges(document: "A", before: "前文12「あ", after: "」tail", selection: nil))
        XCTAssertFalse(receipt.acknowledges(document: "A", before: "前文", after: "12「」tail", selection: nil))
        XCTAssertFalse(receipt.acknowledges(document: "B", before: "前文12「", after: "」tail", selection: nil))
    }

    func testReplacementDeletesMultiCharacterMarkWithoutAnEmptyMarkRoundTrip() throws {
        let text = UITextView()
        text.text = "KEEP 12+"; text.selectedRange = NSRange(location: text.text.utf16.count, length: 0)
        var emptyMarks = 0
        let host = KeyboardHostConnection(setMarkedText: {
            if $0.isEmpty { emptyMarks += 1; return } // A remote host can defer this command.
            text.setMarkedText($0, selectedRange: $1)
        }, unmarkText: { text.unmarkText() }, insertText: { text.insertText($0) },
            deleteBackward: { text.deleteBackward() },
            undoAnchor: { .init(document: "remote", before: "KEEP 12+34", after: "", selection: nil) })
        host.updatePreedit(.init(text: "34"))
        XCTAssertTrue(host.replaceText(.init(anchor: .init(document: "remote", before: "KEEP 12+", after: ""),
            markedText: "34", committedSuffix: "12+", text: "46")))
        XCTAssertEqual(emptyMarks, 0)
        XCTAssertEqual(text.text, "KEEP 46")
        XCTAssertNil(host.markedText)
    }

    func testHeldCalculationCannotDeleteNewInputOrSelection() async throws {
        let fixture = try await Fixture(english: true)
        defer { fixture.close() }
        try fixture.tapKey(title: "123")
        for value in ["1", "+", "1"] { try fixture.tapKey(id: "vime.number." + value) }
        let held = try fixture.button("vime.calculation.0")
        held.sendActions(for: .touchDown)
        try fixture.tapKey(id: "vime.number.2")
        held.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, "1+12")
        let newer = try fixture.button("vime.calculation.0")
        newer.sendActions(for: .touchDown)
        fixture.text.selectedRange = NSRange(location: 0, length: 2)
        newer.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, "1+12")
    }

    func testClipboardAutomaticallyPreviewsAndPastesExactMultilineTextWithoutLearning() async throws {
        let value = " hello 👩🏽‍💻\n二行目\t "
        let fixture = try await Fixture(clipboardText: value)
        defer { fixture.close() }
        XCTAssertTrue(fixture.preferences.clipboardSuggestions)
        XCTAssertEqual(fixture.clipboard.text, value)
        XCTAssertFalse(fixture.descendants.contains { $0.accessibilityIdentifier == "vime.clipboard" })
        let preview = try XCTUnwrap(fixture.descendants.compactMap { $0 as? ClipboardSuggestionView }.first)
        fixture.keyboard.layoutIfNeeded()
        XCTAssertFalse(preview.isHidden)
        XCTAssertFalse(fixture.text.hasText, "Showing the preview cannot insert")
        let paste = try fixture.button("vime.clipboard.paste")
        paste.sendActions(for: .touchDown); paste.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, value)
        XCTAssertNil(fixture.clipboard.text)
        XCTAssertTrue(fixture.session.suggestions.isEmpty)
        XCTAssertTrue(fixture.session.candidates.isEmpty)
        XCTAssertFalse(fixture.session.isComposing)
    }

    func testDisablingClipboardAndHidingKeyboardClearPreviewAndStopReads() async throws {
        let fixture = try await Fixture(clipboardText: "private")
        defer { fixture.close() }
        let held = try fixture.button("vime.clipboard.paste")
        held.sendActions(for: .touchDown)
        fixture.preferences.clipboardSuggestions = false
        fixture.keyboard.reloadPreferences()
        held.sendActions(for: .touchUpInside)
        XCTAssertTrue(fixture.text.text.isEmpty)
        XCTAssertNil(fixture.clipboard.text)
        XCTAssertTrue(try XCTUnwrap(fixture.descendants.compactMap { $0 as? ClipboardSuggestionView }.first).isHidden)
        fixture.preferences.clipboardSuggestions = true
        fixture.keyboard.reloadPreferences()
        await settle(fixture.clipboard)
        XCTAssertNotNil(fixture.clipboard.text)
        fixture.keyboard.setClipboardActive(false)
        XCTAssertNil(fixture.clipboard.text)
    }

    func testDefaultOffPreferenceSharesExplicitOptInWithoutOverwritingIt() throws {
        let localName = "vime.clipboard.local.\(UUID())", sharedName = "vime.clipboard.shared.\(UUID())"
        let local = try XCTUnwrap(UserDefaults(suiteName: localName)), shared = try XCTUnwrap(UserDefaults(suiteName: sharedName))
        defer { local.removePersistentDomain(forName: localName); shared.removePersistentDomain(forName: sharedName) }
        XCTAssertFalse(KeyboardPreferences(defaults: local).clipboardSuggestions)
        let app = KeyboardPreferences(defaults: local, sharedDefaults: shared)
        app.clipboardSuggestions = true
        let extensionPreferences = KeyboardPreferences(defaults: local, sharedDefaults: shared)
        XCTAssertTrue(extensionPreferences.snapshot.clipboardSuggestions)
        extensionPreferences.clipboardSuggestions = false
        XCTAssertFalse(app.clipboardSuggestions)
    }

    func testReplacementRejectsChangedHostWithoutClearingOwnedMark() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        fixture.text.text = "1+"; fixture.text.selectedRange = NSRange(location: 2, length: 0)
        fixture.host.updatePreedit(.init(text: "1"))
        let request = KeyboardTextReplacement(anchor: .init(document: "wrong", before: "1+", after: ""),
            markedText: "1", committedSuffix: "1+", text: "2")
        XCTAssertFalse(fixture.host.replaceText(request))
        XCTAssertEqual(fixture.text.text, "1+1")
        XCTAssertEqual(fixture.host.markedText, "1")
    }

    func testReplacementUsesOneKnownSuffixEvenWhenProxyContextLags() throws {
        let text = UITextView()
        text.text = "KEEP👩🏽‍💻 1+"; text.selectedRange = NSRange(location: text.text.utf16.count, length: 0)
        var deletes = 0
        let host = KeyboardHostConnection(setMarkedText: { text.setMarkedText($0, selectedRange: $1) },
            unmarkText: { text.unmarkText() }, insertText: { text.insertText($0) },
            deleteBackward: { deletes += 1; text.deleteBackward() },
            undoAnchor: { .init(document: "delayed", before: "KEEP👩🏽‍💻 1+1", after: "", selection: nil) })
        host.updatePreedit(.init(text: "1"))
        XCTAssertTrue(host.replaceText(.init(anchor: .init(document: "delayed", before: "KEEP👩🏽‍💻 1+", after: ""),
            markedText: "1", committedSuffix: "1+", text: "1+1=2")))
        XCTAssertEqual(text.text, "KEEP👩🏽‍💻 1+1=2")
        XCTAssertEqual(deletes, 3)
        XCTAssertNil(text.markedTextRange)
    }

    func testClipboardNotificationsReadImmediatelyAndStopWhileHidden() async throws {
        var version = 1, reads = 0, value = "first"
        let clipboard = KeyboardClipboard(changeCount: { version }, readText: { reads += 1; return value }, history: ClipboardHistoryStore(inMemory: true))
        let fixture = try await Fixture(clipboardOverride: clipboard)
        defer { fixture.close() }
        XCTAssertEqual(reads, 1)
        version += 1; value = "second"
        NotificationCenter.default.post(name: UIPasteboard.changedNotification, object: UIPasteboard.general)
        await settle(clipboard)
        XCTAssertEqual(clipboard.text, "second")
        XCTAssertEqual(reads, 2)
        NotificationCenter.default.post(name: UIPasteboard.changedNotification, object: UIPasteboard.general)
        await settle(clipboard)
        XCTAssertEqual(reads, 2, "Duplicate notifications must not re-read unchanged content")
        fixture.keyboard.setClipboardActive(false)
        XCTAssertNil(clipboard.text)
        version += 1; value = "third"
        NotificationCenter.default.post(name: UIPasteboard.changedNotification, object: UIPasteboard.general)
        await Task.yield()
        XCTAssertEqual(reads, 2)
        fixture.keyboard.setClipboardActive(true)
        await settle(clipboard)
        XCTAssertEqual(clipboard.text, "third")
        XCTAssertEqual(reads, 3)
    }

    func testClipboardFallbackDetectsMissedNotificationWithoutReloadingUnchangedText() async throws {
        var version = 1, reads = 0, metadataReads = 0, value = "initial"
        let clipboard = KeyboardClipboard(changeCount: { metadataReads += 1; return version },
            readText: { reads += 1; return value }, history: ClipboardHistoryStore(inMemory: true))
        let fixture = try await Fixture(clipboardOverride: clipboard)
        defer { fixture.close() }
        version = 2; value = "copied in another process"
        let deadline = Date().addingTimeInterval(1.5)
        while clipboard.text != value, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(clipboard.text, value)
        XCTAssertEqual(reads, 2)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(reads, 2, "Idle fallback must check metadata without loading text again")
        fixture.keyboard.setClipboardActive(false)
        let stoppedAt = metadataReads
        version = 3
        NotificationCenter.default.post(name: UIPasteboard.changedNotification, object: UIPasteboard.general)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(metadataReads, stoppedAt, "Hidden keyboard must stop both timer and notifications")
        XCTAssertEqual(reads, 2)
    }

    func testQuickStripFitsNarrowPortraitCompactAndQwertyNumberLayout() async throws {
        let fixture = try await Fixture(english: true, clipboardText: "待粘贴的文字")
        defer { fixture.close() }
        fixture.preferences.nineKeyNumbers = false
        fixture.keyboard.reloadPreferences()
        try fixture.tapKey(title: "123")
        for width in [CGFloat(320), 440, 680] {
            fixture.keyboard.compact = width > 600
            fixture.keyboard.frame = CGRect(x: 0, y: 0, width: width, height: fixture.keyboard.preferredHeight(for: width))
            fixture.keyboard.layoutIfNeeded()
            let strip = try XCTUnwrap(fixture.descendants.compactMap { $0 as? KeyboardQuickCandidateStrip }.first)
            let expand = try fixture.button("vime.candidates.expand")
            XCTAssertLessThanOrEqual(strip.frame.maxX, expand.frame.minX)
            XCTAssertGreaterThan(strip.bounds.height, 20)
            XCTAssertFalse(strip.isHidden)
            XCTAssertTrue(try fixture.button("vime.brand.settings").isHidden)
            let metrics = KeyboardMetrics(width: width, compact: fixture.keyboard.compact, showsFooter: false)
            XCTAssertEqual(strip.frame.minX, fixture.keyboard.compact ? metrics.contentLeft : 4 * width / 440,
                accuracy: 0.001)
            try fixture.tapKey(title: "1"); try fixture.tapKey(title: "1")
            let image = UIGraphicsImageRenderer(bounds: fixture.keyboard.bounds).image { fixture.keyboard.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "数字候选-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testDismissOnlyHidesSuggestionAndAdjacentDedupStillAllowsAThenBThenA() async throws {
        var version = 1, value = "A"
        let clipboard = KeyboardClipboard(changeCount: { version }, readText: { value }, history: ClipboardHistoryStore(inMemory: true))
        let fixture = try await Fixture(clipboardOverride: clipboard)
        defer { fixture.close() }
        let preview = try XCTUnwrap(fixture.descendants.compactMap { $0 as? ClipboardSuggestionView }.first)
        let dismiss = try fixture.button("vime.clipboard.dismiss")
        dismiss.sendActions(for: .touchDown); dismiss.sendActions(for: .touchUpInside)
        XCTAssertTrue(preview.isHidden)
        XCTAssertTrue(fixture.text.text.isEmpty)
        let retained = try await clipboard.history.entries()
        XCTAssertEqual(retained.map(\.text), ["A"])
        fixture.keyboard.hostContextDidChange()
        fixture.keyboard.setClipboardActive(false); fixture.keyboard.setClipboardActive(true)
        await settle(clipboard)
        XCTAssertTrue(preview.isHidden)
        version += 1
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        XCTAssertTrue(preview.isHidden, "Copying A again must not undo dismissal")
        for text in ["B", "A"] {
            version += 1; value = text
            clipboard.checkForChanges(enabled: true, hasFullAccess: true)
            await settle(clipboard)
            XCTAssertFalse(preview.isHidden)
            XCTAssertEqual(try fixture.button("vime.clipboard.paste").accessibilityLabel, text)
        }
    }

    func testCompositionAndNumericShortcutsTakePriorityOverClipboardPreview() async throws {
        let fixture = try await Fixture(clipboardText: "clipboard")
        defer { fixture.close() }
        let preview = try XCTUnwrap(fixture.descendants.compactMap { $0 as? ClipboardSuggestionView }.first)
        let held = try fixture.button("vime.clipboard.paste")
        held.sendActions(for: .touchDown)
        try fixture.tapKey(id: "vime.key.a")
        XCTAssertTrue(preview.isHidden)
        held.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, "あ", "A held paste cannot replace active composition")
        XCTAssertEqual(fixture.clipboard.text, "clipboard")
        fixture.keyboard.confirmComposition()
        XCTAssertFalse(preview.isHidden)
        try fixture.tapKey(title: "123")
        XCTAssertTrue(preview.isHidden)
        let strip = try XCTUnwrap(fixture.descendants.compactMap { $0 as? KeyboardQuickCandidateStrip }.first)
        XCTAssertFalse(strip.isHidden)
        for digit in ["1", "+", "1"] { try fixture.tapKey(id: "vime.number." + digit) }
        XCTAssertEqual(try fixture.button("vime.calculation.0").title(for: .normal), "2")
    }

    func testHeldClipboardActionsCannotPasteOrDismissANewerValue() async throws {
        for action in ["paste", "dismiss"] {
            var version = 1, value = "old"
            let clipboard = KeyboardClipboard(changeCount: { version }, readText: { value }, history: ClipboardHistoryStore(inMemory: true))
            let fixture = try await Fixture(clipboardOverride: clipboard)
            defer { fixture.close() }
            let button = try fixture.button("vime.clipboard." + action)
            button.sendActions(for: .touchDown)
            version += 1; value = "new"
            clipboard.checkForChanges(enabled: true, hasFullAccess: true)
            await settle(clipboard)
            button.sendActions(for: .touchUpInside)
            XCTAssertTrue(fixture.text.text.isEmpty)
            XCTAssertEqual(clipboard.text, "new")
        }
    }

    func testClipboardCardFitsNarrowPortraitCompactAndDarkAppearance() async throws {
        let fixture = try await Fixture(clipboardText: String(repeating: "長いテキスト👩🏽‍💻", count: 50))
        defer { fixture.close() }
        let preview = try XCTUnwrap(fixture.descendants.compactMap { $0 as? ClipboardSuggestionView }.first)
        for theme in [KeyboardTheme.system, .midnight] {
            fixture.preferences.theme = theme; fixture.keyboard.reloadPreferences()
            for width in [CGFloat(320), 440, 680] {
                fixture.keyboard.compact = width > 600
                fixture.keyboard.frame.size = CGSize(width: width, height: fixture.keyboard.preferredHeight(for: width))
                fixture.keyboard.layoutIfNeeded(); preview.layoutIfNeeded()
                let paste = try fixture.button("vime.clipboard.paste"), dismiss = try fixture.button("vime.clipboard.dismiss")
                let brand = try fixture.button("vime.brand.settings")
                XCTAssertFalse(preview.isHidden)
                XCTAssertGreaterThanOrEqual(preview.frame.minX, brand.frame.maxX)
                XCTAssertLessThanOrEqual(preview.frame.maxX, fixture.keyboard.bounds.maxX)
                XCTAssertEqual(preview.frame.minY, brand.frame.minY)
                XCTAssertEqual(preview.frame.height, brand.frame.height)
                XCTAssertEqual(dismiss.bounds.width, 44)
                XCTAssertLessThanOrEqual(paste.frame.maxX, dismiss.frame.minX)
                XCTAssertGreaterThan(paste.bounds.width, 150)
                XCTAssertTrue(preview.hitTest(CGPoint(x: dismiss.frame.midX, y: dismiss.frame.midY), with: nil) === dismiss)
                let image = UIGraphicsImageRenderer(bounds: fixture.keyboard.bounds).image { fixture.keyboard.layer.render(in: $0.cgContext) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "剪贴板预览-\(theme.rawValue)-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testSettingsHistoryComesFirstAndGroupedControlsFitPortraitAndLandscape() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        try fixture.button("vime.brand.settings").sendActions(for: .touchUpInside)
        var appSettingsOpens = 0
        fixture.keyboard.onOpenAppSettings = { appSettingsOpens += 1 }
        try fixture.button("vime.setting.openAppSettings").sendActions(for: .touchUpInside)
        XCTAssertEqual(appSettingsOpens, 1)
        for theme in [KeyboardTheme.system, .midnight] {
            fixture.preferences.theme = theme; fixture.keyboard.reloadPreferences()
            for width in [CGFloat(320), 440, 680] {
                fixture.keyboard.compact = width > 600
                fixture.keyboard.frame.size = CGSize(width: width, height: fixture.keyboard.preferredHeight(for: width))
                fixture.keyboard.layoutIfNeeded()
                let settings = try XCTUnwrap(fixture.descendants.compactMap { $0 as? KeyboardSettingsPanel }.first)
                settings.layoutIfNeeded()
                let history = try fixture.button("vime.setting.clipboardHistory")
                let sound = try XCTUnwrap(fixture.descendants.first { $0.accessibilityIdentifier == "vime.setting.sound" })
                let slider = try XCTUnwrap(fixture.descendants.first { $0.accessibilityIdentifier == "vime.setting.haptics" })
                let numbers = try XCTUnwrap(fixture.descendants.first { $0.accessibilityIdentifier == "vime.setting.numbers" })
                let appSettings = try fixture.button("vime.setting.openAppSettings")
                let historyFrame = history.convert(history.bounds, to: settings)
                XCTAssertGreaterThanOrEqual(historyFrame.minY, 0)
                XCTAssertLessThanOrEqual(historyFrame.maxY, settings.bounds.height)
                XCTAssertLessThan(historyFrame.maxY, sound.convert(sound.bounds, to: settings).midY)
                for control in [sound, slider, numbers, appSettings] {
                    let rect = control.convert(control.bounds, to: settings)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, settings.bounds.width)
                    XCTAssertGreaterThan(rect.width, 30)
                }
                XCTAssertLessThan(historyFrame.maxY, appSettings.convert(appSettings.bounds, to: settings).midY)
                XCTAssertLessThan(appSettings.convert(appSettings.bounds, to: settings).maxY,
                    sound.convert(sound.bounds, to: settings).midY)
                XCTAssertLessThanOrEqual(appSettings.convert(appSettings.bounds, to: settings).maxY, settings.bounds.height,
                    "The App settings shortcut must be visible without scrolling")
                let image = UIGraphicsImageRenderer(bounds: fixture.keyboard.bounds).image { fixture.keyboard.layer.render(in: $0.cgContext) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "快捷设置-\(theme.rawValue)-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testHistoryMenuPastesLiteralMultilineTextAndClearRejectsOldSelection() async throws {
        let value = "(literal) 👩🏽‍💻\n第二行\t "
        let fixture = try await Fixture(clipboardText: value)
        defer { fixture.close() }
        fixture.keyboard.setClipboardActive(false)
        fixture.keyboard.setClipboardActive(true)
        await settle(fixture.clipboard)
        XCTAssertNil(fixture.clipboard.text, "Reopening must not re-arm the clipboard button")
        try fixture.button("vime.brand.settings").sendActions(for: .touchUpInside)
        try fixture.button("vime.setting.clipboardHistory").sendActions(for: .touchUpInside)
        fixture.keyboard.layoutIfNeeded()
        let panel = try XCTUnwrap(fixture.descendants.compactMap { $0 as? ClipboardHistoryPanel }.first)
        let table = try XCTUnwrap(panel.subviews.compactMap { $0 as? UITableView }.first)
        await waitUntil { table.numberOfRows(inSection: 0) == 1 }
        for theme in [KeyboardTheme.system, .midnight] {
            fixture.preferences.theme = theme; fixture.keyboard.reloadPreferences()
            for width in [CGFloat(320), 440, 680] {
                fixture.keyboard.compact = width > 600
                fixture.keyboard.frame.size = CGSize(width: width, height: fixture.keyboard.preferredHeight(for: width))
                fixture.keyboard.layoutIfNeeded(); panel.layoutIfNeeded(); table.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: fixture.keyboard.bounds).image { fixture.keyboard.layer.render(in: $0.cgContext) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "剪贴板历史-\(theme.rawValue)-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        try fixture.button("vime.clipboard.history.back").sendActions(for: .touchUpInside)
        XCTAssertTrue(panel.isHidden)
        try fixture.button("vime.setting.clipboardHistory").sendActions(for: .touchUpInside)
        await waitUntil { !panel.isHidden && table.numberOfRows(inSection: 0) == 1 }
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        await waitUntil { fixture.text.text == value }
        XCTAssertTrue(fixture.session.suggestions.isEmpty)
        XCTAssertTrue(fixture.session.candidates.isEmpty)
        XCTAssertFalse(fixture.session.isComposing)
        try fixture.button("vime.brand.settings").sendActions(for: .touchUpInside)
        try fixture.button("vime.setting.clipboardHistory").sendActions(for: .touchUpInside)
        await waitUntil { !panel.isHidden && table.numberOfRows(inSection: 0) == 1 }
        let entries = try await fixture.clipboard.history.entries()
        let held = try XCTUnwrap(entries.first)
        try fixture.button("vime.clipboard.history.clear").sendActions(for: .touchUpInside)
        await waitUntil { table.numberOfRows(inSection: 0) == 0 }
        panel.onSelect?(held)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.text.text, value, "A cleared history row cannot insert old text")
        let cleared = try await fixture.clipboard.history.entries()
        XCTAssertTrue(cleared.isEmpty)
        for width in [CGFloat(320), 440, 680] {
            fixture.keyboard.compact = width > 600
            fixture.keyboard.frame.size = CGSize(width: width, height: fixture.keyboard.preferredHeight(for: width))
            fixture.keyboard.layoutIfNeeded()
            XCTAssertLessThanOrEqual(panel.frame.maxY, fixture.keyboard.bounds.maxY)
            let image = UIGraphicsImageRenderer(bounds: fixture.keyboard.bounds).image { fixture.keyboard.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "剪贴板历史-空状态-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }
    private func settle(_ clipboard: KeyboardClipboard) async {
        await waitUntil { !clipboard.isLoading }
    }

    @MainActor private final class Fixture {
        let keyboard: KeyboardView
        let session: KeyboardSession
        let text = UITextView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 900))
        let preferences: KeyboardPreferences
        let clipboard: KeyboardClipboard
        let host: KeyboardHostConnection
        private let suite: String
        var descendants: [UIView] {
            func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(all) }
            return all(keyboard)
        }
        init(english: Bool = false, clipboardText: String? = nil, clipboardOverride: KeyboardClipboard? = nil) async throws {
            suite = "vime.quick.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            preferences = KeyboardPreferences(defaults: defaults)
            preferences.candidateRanking = .engine; preferences.phraseSuggestions = false
            preferences.sound = false; preferences.hapticIntensity = 0
            preferences.clipboardSuggestions = clipboardText != nil || clipboardOverride != nil
            clipboard = clipboardOverride ?? KeyboardClipboard(changeCount: { 1 }, readText: { clipboardText }, history: ClipboardHistoryStore(inMemory: true))
            session = KeyboardSession()
            if english { _ = session.activateEnglish() }
            keyboard = KeyboardView(frame: CGRect(x: 0, y: 400, width: 440, height: 350), session: session,
                preferences: preferences, clipboard: clipboard)
            let text = text
            host = KeyboardHostConnection(setMarkedText: { text.setMarkedText($0, selectedRange: $1) },
                unmarkText: { text.unmarkText() }, insertText: { text.insertText($0) }, deleteBackward: { text.deleteBackward() },
                adjustInsertionPosition: { offset in
                    if let position = text.position(from: text.selectedTextRange!.start, offset: offset) {
                        text.selectedTextRange = text.textRange(from: position, to: position)
                    }
                },
                undoAnchor: {
                    let value = text.text! as NSString, range = text.selectedRange
                    return .init(document: "quick-fixture", before: value.substring(to: range.location),
                        after: value.substring(from: NSMaxRange(range)), selection: range.length == 0 ? nil : value.substring(with: range))
                })
            let host = host
            keyboard.onEditsAndPreeditChange = { host.apply($0, preedit: $1) }
            keyboard.onPreeditChange = { host.updatePreedit($0) }
            keyboard.onReplaceText = { host.replaceText($0) }
            keyboard.learningContextProvider = {
                let value = text.text! as NSString, range = text.selectedRange
                let before = value.substring(to: range.location), mark = host.markedText ?? ""
                return .init(document: "quick-fixture", before: !mark.isEmpty && before.hasSuffix(mark)
                    ? String(before.dropLast(mark.count)) : before,
                    after: value.substring(from: NSMaxRange(range)), hasSelection: range.length > 0)
            }
            keyboard.leftContextProvider = { [weak keyboard] in keyboard?.learningContextProvider?()?.before }
            window.rootViewController = UIViewController()
            window.rootViewController?.view.addSubview(text)
            window.rootViewController?.view.addSubview(keyboard)
            window.isHidden = false
            keyboard.layoutIfNeeded()
            let deadline = Date().addingTimeInterval(3)
            while clipboard.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(clipboard.isLoading)
        }
        func button(_ id: String) throws -> UIButton {
            try XCTUnwrap(descendants.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id }, id)
        }
        func tapKey(title: String? = nil, id: String? = nil) throws {
            let key = try XCTUnwrap(descendants.compactMap { $0 as? UIButton }.first { key in
                if let id { return key.accessibilityIdentifier == id }
                return key.title(for: .normal) == title
            })
            if let key = key as? KeyboardKey { key.action?() }
            else { key.sendActions(for: .touchUpInside) }
            keyboard.layoutIfNeeded()
        }
        func close() {
            keyboard.stopInteractions(); keyboard.setClipboardActive(false); window.isHidden = true
            preferences.store.removePersistentDomain(forName: suite)
        }
    }
}
