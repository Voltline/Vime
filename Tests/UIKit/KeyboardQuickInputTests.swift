import XCTest
import UIKit

@MainActor
final class KeyboardQuickInputTests: XCTestCase {
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

    func testClipboardRequiresOptInAndFullAccessReadsChangedVersionsOnceAndBoundsStorage() {
        var version = 1, reads = 0, metadataReads = 0
        var value: String? = " first\nsecond "
        let clipboard = KeyboardClipboard(changeCount: { metadataReads += 1; return version }, readText: { reads += 1; return value })
        clipboard.poll(enabled: false, hasFullAccess: true)
        clipboard.poll(enabled: true, hasFullAccess: false)
        XCTAssertEqual(metadataReads, 0); XCTAssertEqual(reads, 0)
        clipboard.poll(enabled: true, hasFullAccess: true)
        XCTAssertEqual(clipboard.text, value)
        for _ in 0..<10 { clipboard.poll(enabled: true, hasFullAccess: true) }
        XCTAssertEqual(reads, 1)
        version += 1; value = nil // An image, empty clipboard or denied read.
        clipboard.poll(enabled: true, hasFullAccess: true)
        clipboard.clear()
        clipboard.poll(enabled: true, hasFullAccess: true)
        XCTAssertNil(clipboard.text); XCTAssertEqual(reads, 2, "A denied/empty read is not retried on every show")
        version += 1; value = String(repeating: "あ", count: 30_000)
        clipboard.poll(enabled: true, hasFullAccess: true)
        XCTAssertNil(clipboard.text, "Oversized text must not be truncated and offered as if complete")
        version += 1; value = " \n\t "
        clipboard.poll(enabled: true, hasFullAccess: true)
        XCTAssertNil(clipboard.text)
        version += 1; value = "latest"
        clipboard.poll(enabled: true, hasFullAccess: true)
        clipboard.poll(enabled: false, hasFullAccess: true)
        XCTAssertNil(clipboard.text)
    }

    func testAsyncClipboardRejectsSupersededAndCancelledLoads() {
        var version = 1
        var completions: [(String?) -> Void] = []
        var progress: [Progress] = []
        let clipboard = KeyboardClipboard(changeCount: { version }, loadText: { complete in
            completions.append(complete)
            let load = Progress(totalUnitCount: 1); progress.append(load); return load
        })
        clipboard.poll(enabled: true, hasFullAccess: true)
        clipboard.poll(enabled: true, hasFullAccess: true)
        XCTAssertEqual(completions.count, 1, "A pending read must not start another permission request")
        version += 1
        clipboard.poll(enabled: true, hasFullAccess: true)
        XCTAssertEqual(completions.count, 1, "Slow loads must not pile up even when the clipboard changes")
        completions[0]("old")
        XCTAssertNil(clipboard.text)
        clipboard.poll(enabled: true, hasFullAccess: true)
        completions[1]("latest")
        XCTAssertEqual(clipboard.text, "latest")
        version += 1
        clipboard.poll(enabled: true, hasFullAccess: true)
        clipboard.poll(enabled: false, hasFullAccess: true)
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

    func testNumericPageImmediatelyOffersSymbolsAndBothResultsReplaceWholeExpression() throws {
        for english in [false, true] {
            for choice in [0, 1] {
                let fixture = try Fixture(english: english)
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
            }
        }
    }

    func testMinusDoesNotBecomeJapaneseProlongedSoundAndSymbolsRemainAvailable() throws {
        let fixture = try Fixture()
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

    func testPairedBracketsNestAtCaretAndCanBeDisabledWithoutChangingPaste() throws {
        let fixture = try Fixture(english: true, clipboardText: "(literal)")
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
        try fixture.button("vime.clipboard").sendActions(for: .touchUpInside)
        try fixture.button("vime.clipboard.paste").sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, "((1((literal)))")
    }

    func testPairConfirmsNumericCompositionAndContinuesInsideJapaneseBrackets() throws {
        let fixture = try Fixture()
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
        host.updateMarkedText("34")
        XCTAssertTrue(host.replaceText(.init(anchor: .init(document: "remote", before: "KEEP 12+", after: ""),
            markedText: "34", committedSuffix: "12+", text: "46")))
        XCTAssertEqual(emptyMarks, 0)
        XCTAssertEqual(text.text, "KEEP 46")
        XCTAssertNil(host.markedText)
    }

    func testHeldCalculationCannotDeleteNewInputOrSelection() throws {
        let fixture = try Fixture(english: true)
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

    func testClipboardEntryPreviewsAndPastesExactMultilineTextWithoutLearningOrHistory() throws {
        let value = " hello 👩🏽‍💻\n二行目\t "
        let fixture = try Fixture(clipboardText: value)
        defer { fixture.close() }
        XCTAssertTrue(fixture.preferences.clipboardSuggestions)
        XCTAssertEqual(fixture.clipboard.text, value)
        let mode = try XCTUnwrap(fixture.descendants.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "切换平假名和片假名" })
        let entry = try fixture.button("vime.clipboard")
        fixture.keyboard.layoutIfNeeded()
        XCTAssertFalse(entry.isHidden)
        XCTAssertLessThan(entry.frame.midX, mode.frame.midX)
        XCTAssertTrue(fixture.text.text.isEmpty)
        entry.sendActions(for: .touchUpInside)
        let paste = try fixture.button("vime.clipboard.paste")
        XCTAssertFalse(fixture.text.hasText, "Opening a preview cannot insert")
        paste.sendActions(for: .touchDown); paste.sendActions(for: .touchUpInside)
        XCTAssertEqual(fixture.text.text, value)
        XCTAssertNil(fixture.clipboard.text)
        XCTAssertTrue(fixture.session.suggestions.isEmpty)
        XCTAssertTrue(fixture.session.candidates.isEmpty)
        XCTAssertFalse(fixture.session.isComposing)
    }

    func testDisablingClipboardAndHidingKeyboardClearPreviewAndStopReads() throws {
        let fixture = try Fixture(clipboardText: "private")
        defer { fixture.close() }
        try fixture.button("vime.clipboard").sendActions(for: .touchUpInside)
        let held = try fixture.button("vime.clipboard.paste")
        held.sendActions(for: .touchDown)
        fixture.preferences.clipboardSuggestions = false
        fixture.keyboard.reloadPreferences()
        held.sendActions(for: .touchUpInside)
        XCTAssertTrue(fixture.text.text.isEmpty)
        XCTAssertNil(fixture.clipboard.text)
        XCTAssertTrue(try fixture.button("vime.clipboard").isHidden)
        fixture.preferences.clipboardSuggestions = true
        fixture.keyboard.reloadPreferences()
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

    func testReplacementRejectsChangedHostWithoutClearingOwnedMark() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.text.text = "1+"; fixture.text.selectedRange = NSRange(location: 2, length: 0)
        fixture.host.updateMarkedText("1")
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
        host.updateMarkedText("1")
        XCTAssertTrue(host.replaceText(.init(anchor: .init(document: "delayed", before: "KEEP👩🏽‍💻 1+", after: ""),
            markedText: "1", committedSuffix: "1+", text: "1+1=2")))
        XCTAssertEqual(text.text, "KEEP👩🏽‍💻 1+1=2")
        XCTAssertEqual(deletes, 3)
        XCTAssertNil(text.markedTextRange)
    }

    func testClipboardPollingStopsWhileHiddenAndResumesWithLatestOnly() async throws {
        var version = 1, reads = 0, value = "first"
        let clipboard = KeyboardClipboard(changeCount: { version }, readText: { reads += 1; return value })
        let fixture = try Fixture(clipboardOverride: clipboard)
        defer { fixture.close() }
        XCTAssertEqual(reads, 1)
        version += 1; value = "second"
        try await Task.sleep(for: .milliseconds(2600))
        XCTAssertEqual(clipboard.text, "second")
        XCTAssertEqual(reads, 2)
        fixture.keyboard.setClipboardActive(false)
        XCTAssertNil(clipboard.text)
        version += 1; value = "third"
        try await Task.sleep(for: .milliseconds(2600))
        XCTAssertEqual(reads, 2)
        fixture.keyboard.setClipboardActive(true)
        XCTAssertEqual(clipboard.text, "third")
        XCTAssertEqual(reads, 3)
    }

    func testQuickStripFitsNarrowPortraitCompactAndQwertyNumberLayout() throws {
        let fixture = try Fixture(english: true, clipboardText: "待粘贴的文字")
        defer { fixture.close() }
        fixture.preferences.nineKeyNumbers = false
        fixture.keyboard.reloadPreferences()
        try fixture.tapKey(title: "123")
        for width in [CGFloat(320), 440, 680] {
            fixture.keyboard.compact = width > 600
            fixture.keyboard.frame = CGRect(x: 0, y: 0, width: width, height: fixture.keyboard.preferredHeight(for: width))
            fixture.keyboard.layoutIfNeeded()
            let strip = try XCTUnwrap(fixture.descendants.compactMap { $0 as? KeyboardQuickCandidateStrip }.first)
            let entry = try fixture.button("vime.clipboard")
            let expand = try fixture.button("vime.candidates.expand")
            XCTAssertLessThanOrEqual(entry.frame.maxX, strip.frame.minX)
            XCTAssertLessThanOrEqual(strip.frame.maxX, expand.frame.minX)
            XCTAssertGreaterThan(strip.bounds.height, 20)
            XCTAssertFalse(strip.isHidden)
            try fixture.tapKey(title: "1"); try fixture.tapKey(title: "1")
            let image = UIGraphicsImageRenderer(bounds: fixture.keyboard.bounds).image { fixture.keyboard.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "数字候选-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
        }
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
        init(english: Bool = false, clipboardText: String? = nil, clipboardOverride: KeyboardClipboard? = nil) throws {
            suite = "vime.quick.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            preferences = KeyboardPreferences(defaults: defaults)
            preferences.candidateRanking = .engine; preferences.phraseSuggestions = false
            preferences.sound = false; preferences.hapticIntensity = 0
            preferences.clipboardSuggestions = clipboardText != nil || clipboardOverride != nil
            clipboard = clipboardOverride ?? KeyboardClipboard(changeCount: { 1 }, readText: { clipboardText })
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
        }
        func button(_ id: String) throws -> UIButton {
            try XCTUnwrap(descendants.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == id }, id)
        }
        func tapKey(title: String? = nil, id: String? = nil) throws {
            let key = try XCTUnwrap(descendants.compactMap { $0 as? KeyboardKey }.first { key in
                if let id { return key.accessibilityIdentifier == id }
                return key.title(for: .normal) == title
            })
            key.action?(); keyboard.layoutIfNeeded()
        }
        func close() {
            keyboard.stopInteractions(); keyboard.setClipboardActive(false); window.isHidden = true
            preferences.store.removePersistentDomain(forName: suite)
        }
    }
}
