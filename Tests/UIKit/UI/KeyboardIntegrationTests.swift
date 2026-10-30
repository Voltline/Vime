import XCTest
import UIKit

@MainActor
final class KeyboardIntegrationTests: XCTestCase {
    private var renderingWindow: UIWindow?
    private var defaultsSuites: [String] = []

    override func tearDown() {
        renderingWindow?.isHidden = true
        renderingWindow = nil
        for suite in defaultsSuites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaultsSuites = []
        super.tearDown()
    }
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func button(_ id: String, in keyboard: KeyboardView) throws -> UIButton {
        try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == id } as? UIButton)
    }

    private func makeKeyboard(suggestionsEnabled: Bool = false) -> KeyboardView {
        let suite = "VimeIntegrationTests." + UUID().uuidString
        defaultsSuites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.phraseSuggestions = suggestionsEnabled
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: KeyboardSession(), preferences: preferences)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = .light
        let input = UIInputView(frame: keyboard.frame, inputViewStyle: .keyboard)
        input.addSubview(keyboard)
        window.rootViewController?.view.addSubview(input)
        window.isHidden = false
        renderingWindow = window
        keyboard.overrideUserInterfaceStyle = .light
        keyboard.layoutIfNeeded()
        return keyboard
    }

    private func capture(_ keyboard: KeyboardView, name: String) throws {
        keyboard.updateTraitsIfNeeded()
        descendants(keyboard).forEach { $0.updateTraitsIfNeeded() }
        keyboard.layoutIfNeeded()
        descendants(keyboard).forEach { $0.layoutIfNeeded() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: keyboard.bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(keyboard.bounds)
            keyboard.superview?.frame.size = keyboard.bounds.size
            keyboard.superview?.layoutIfNeeded()
            keyboard.superview?.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
    }

    func testDisconnectedExtensionLifecycleDoesNotCrash() {
        // Reproduces the device crash: UIKit has not connected a host document.
        // Reading documentIdentifier here previously force-bridged nil to UUID.
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        controller.textDidChange(nil)
        controller.selectionDidChange(nil)
        controller.viewWillLayoutSubviews()
        controller.viewWillDisappear(false)
        XCTAssertEqual(descendants(controller.view).filter { $0 is KeyboardView }.count, 1)
    }

    func testReferenceLayoutAndToolbarHitTesting() throws {
        let keyboard = makeKeyboard()
        XCTAssertEqual(keyboard.preferredHeight(for: 440), 350)
        let q = try button("vime.key.q", in: keyboard)
        XCTAssertEqual(q.frame, CGRect(x: 5, y: 56, width: 36.8, height: 46.5))
        XCTAssertEqual(q.title(for: .normal), "Q")
        let space = try button("vime.key.space", in: keyboard)
        XCTAssertEqual(space.frame, CGRect(x: 158.3, y: 224, width: 136.5, height: 46.5))
        let emoji = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "表情" })
        XCTAssertEqual(emoji.frame.minX, 70.7, accuracy: 0.001)
        XCTAssertEqual(emoji.frame.minY, space.frame.minY)
        let a = try button("vime.key.a", in: keyboard)
        let l = try button("vime.key.l", in: keyboard)
        let prolonged = try button("vime.key.prolonged", in: keyboard)
        XCTAssertEqual(a.frame, CGRect(x: 5, y: 112, width: 36.8, height: 46.5))
        XCTAssertEqual(prolonged.frame.minX, 399.2, accuracy: 0.001)
        XCTAssertEqual(prolonged.frame.minY, a.frame.minY)
        XCTAssertEqual(prolonged.frame.width, a.frame.width)
        let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
        let gap = CGPoint(x: (l.frame.maxX + prolonged.frame.minX) / 2, y: l.frame.midY)
        XCTAssertNotNil(surface.resolvedKey(at: gap), "New second-row gap stays covered")
        XCTAssertTrue(surface.resolvedKey(at: CGPoint(x: 439, y: prolonged.frame.midY)) === prolonged)
        let settings = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "键盘设置" && !$0.isHidden })
        let location = settings.convert(CGPoint(x: settings.bounds.midX, y: settings.bounds.midY), to: keyboard)
        XCTAssertTrue(keyboard.hitTest(location, with: nil) === settings)
        try capture(keyboard, name: "keyboard-reference-layout")
        keyboard.showsFooter = false
        XCTAssertEqual(keyboard.preferredHeight(for: 440), 272)
    }

    func testTypingCandidatesCommitAndEnglish() throws {
        let keyboard = makeKeyboard()
        var edits: [KeyboardEdit] = []
        keyboard.onEdit = { edits += $0 }
        for character in "nihongo" {
            try button("vime.key." + String(character), in: keyboard).sendActions(for: .touchUpInside)
        }
        XCTAssertTrue(edits.isEmpty, "Composition is marked text; only confirmation emits committed edits")
        try capture(keyboard, name: "keyboard-japanese-candidates")
        let japanese = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "候选词：日本語" } as? UIButton)
        japanese.sendActions(for: .touchUpInside)
        XCTAssertEqual(edits, [.insert("日本語")])
        try button("vime.key.return", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(edits.last, .returnKey)
        try button("vime.key.language", in: keyboard).sendActions(for: .touchUpInside)
        try button("vime.key.a", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(edits.last, .insert("a"))
    }

    func testDarkAndNarrowKeyboardSnapshots() throws {
        let keyboard = makeKeyboard()
        keyboard.overrideUserInterfaceStyle = .dark
        keyboard.updateTraitsIfNeeded()
        XCTAssertEqual(keyboard.traitCollection.userInterfaceStyle, .dark)
        keyboard.setNeedsLayout()
        try capture(keyboard, name: "keyboard-dark")
        keyboard.overrideUserInterfaceStyle = .light
        keyboard.frame.size = CGSize(width: 375, height: keyboard.preferredHeight(for: 375))
        try capture(keyboard, name: "keyboard-375pt")
        for control in descendants(keyboard).compactMap({ $0 as? UIButton }) where control.accessibilityIdentifier?.hasPrefix("vime.key.") == true {
            XCTAssertGreaterThanOrEqual(control.frame.minX, 0)
            XCTAssertLessThanOrEqual(control.frame.maxX, 375)
        }
    }

    private func connect(_ keyboard: KeyboardView, to view: UITextView) -> KeyboardHostConnection {
        let host = KeyboardHostConnection(
            setMarkedText: { view.setMarkedText($0, selectedRange: $1) },
            unmarkText: { view.unmarkText() },
            insertText: { view.insertText($0) },
            deleteBackward: { view.deleteBackward() }
        )
        keyboard.onEdit = { host.apply($0) }
        keyboard.onPreeditChange = { host.updatePreedit($0) }
        return host
    }

    func testInlineMarkedTextCandidatesAndSurroundingDocument() throws {
        let keyboard = makeKeyboard()
        let view = UITextView(frame: CGRect(x: 0, y: 380, width: 440, height: 200))
        renderingWindow?.rootViewController?.view.addSubview(view)
        view.text = "どうして。"
        view.selectedRange = NSRange(location: 4, length: 0)
        let host = connect(keyboard, to: view)
        for character in "nihongo" {
            try button("vime.key." + String(character), in: keyboard).sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(view.text, "どうしてにほんご。")
        XCTAssertEqual(view.text(in: try XCTUnwrap(view.markedTextRange)), "にほんご")
        let settings = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "键盘设置" })
        XCTAssertTrue(settings.isHidden)
        let scroll = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates" })
        keyboard.layoutIfNeeded()
        let emoji = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "表情" })
        XCTAssertFalse(emoji.isHidden)
        XCTAssertEqual(scroll.frame.minX, 4, accuracy: 0.001)
        for candidate in descendants(scroll).compactMap({ $0 as? KeyboardCandidateButton }) {
            XCTAssertGreaterThanOrEqual(candidate.bounds.height, candidate.intrinsicContentSize.height,
                "The strip must fit the candidate title and any reading annotation")
        }
        let firstKey = try button("vime.key.q", in: keyboard)
        XCTAssertLessThanOrEqual(scroll.convert(scroll.bounds, to: keyboard).maxY,
            firstKey.convert(firstKey.bounds, to: keyboard).minY)
        XCTAssertFalse(descendants(keyboard).contains { $0 is UILabel && $0.accessibilityLabel?.hasPrefix("当前输入：") == true })
        try button("vime.key.space", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "どうして日本語。")
        XCTAssertEqual(host.markedText, "日本語")
        let delete = try button("vime.key.delete", in: keyboard)
        delete.sendActions(for: .touchDown)
        delete.sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "どうしてにほんご。", "Backspace first cancels conversion preview")
        let candidate = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "候选词：日本語" } as? UIButton)
        candidate.sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "どうして日本語。")
        XCTAssertNil(view.markedTextRange)
        XCTAssertNil(host.markedText)
        // The reconvert chip keeps the candidate row up until the next input.
        let chip = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.reconvertCommit" })
        XCTAssertFalse(chip.isHidden)
        XCTAssertTrue(settings.isHidden)
        XCTAssertFalse(emoji.isHidden)
    }

    func testCommittedSuggestionsOwnToolbarWhenEnabled() throws {
        let keyboard = makeKeyboard(suggestionsEnabled: true)
        let view = UITextView()
        let host = connect(keyboard, to: view)
        for character in "ekini" { try button("vime.key." + String(character), in: keyboard).sendActions(for: .touchUpInside) }
        let candidate = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "候选词：駅に" } as? UIButton)
        candidate.sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "駅に")
        XCTAssertNil(view.markedTextRange)
        XCTAssertNil(host.markedText)
        keyboard.layoutIfNeeded()
        let settings = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "键盘设置" })
        XCTAssertTrue(settings.isHidden, "Suggestions use the whole row")
        let strip = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates" } as? UIScrollView)
        XCTAssertFalse(strip.isHidden)
        XCTAssertLessThan(strip.frame.minX, settings.frame.maxX)
        let close = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.suggestions.close" } as? UIButton)
        XCTAssertFalse(close.isHidden)
        XCTAssertEqual(close.accessibilityLabel, "关闭联想")
        let suggestions = descendants(strip).compactMap { $0 as? KeyboardCandidateButton }.filter { !$0.isHidden }
        XCTAssertFalse(suggestions.isEmpty, "Actual suggestions, not merely the settings button")
        for suggestion in suggestions {
            XCTAssertTrue(suggestion.suggestion)
            XCTAssertEqual(suggestion.contentHorizontalAlignment, .center)
            XCTAssertGreaterThanOrEqual(suggestion.frame.width, KeyboardCandidateButton.suggestionMinimumWidth)
        }
        var dismissed = false
        keyboard.onDismiss = { dismissed = true }
        close.sendActions(for: .touchUpInside)
        keyboard.layoutIfNeeded()
        XCTAssertFalse(dismissed, "Closing suggestions keeps the keyboard open")
        XCTAssertTrue(strip.isHidden)
        XCTAssertFalse(settings.isHidden, "The idle toolbar returns")
        XCTAssertEqual(close.accessibilityIdentifier, "vime.candidates.expand")
        XCTAssertEqual(view.text, "駅に", "Closing commits nothing")
    }

    func testReconversionReadings() {
        for (text, reading) in ["漢字": "かんじ", "電車": "でんしゃ", "食べる": "たべる", "カタカナ": "かたかな", "ひらがな": "ひらがな", "コーヒー": "こーひー", "ビームを": "びーむを"] {
            XCTAssertEqual(KeyboardReconversion.reading(for: text), reading, text)
        }
        for text in ["hello", "漢字abc", "😀", "", "。", String(repeating: "漢", count: 25)] {
            XCTAssertNil(KeyboardReconversion.reading(for: text), text)
        }
    }

    func testSelectedTextIsReconvertedThroughItsReading() throws {
        let keyboard = makeKeyboard()
        let view = UITextView()
        _ = connect(keyboard, to: view)
        view.text = "漢字を書く"
        view.selectedRange = NSRange(location: 0, length: 2)
        keyboard.selectedTextProvider = { view.selectedRange.length > 0 ? (view.text as NSString).substring(with: view.selectedRange) : nil }
        keyboard.hostContextDidChange(); keyboard.layoutIfNeeded()
        let reconvert = try button("vime.reconvert", in: keyboard)
        XCTAssertEqual(reconvert.title(for: .normal), "重新转换「漢字」")
        reconvert.sendActions(for: .touchDown); reconvert.sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "かんじを書く", "The reading replaces the selection as marked text")
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertNil(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.reconvert" && !($0.superview?.isHidden ?? true) })
        let candidate = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "候选词：漢字" } as? UIButton)
        candidate.sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "漢字を書く")
        XCTAssertNil(view.markedTextRange)

        view.text = "hello"
        view.selectedRange = NSRange(location: 0, length: 5)
        keyboard.hostContextDidChange(); keyboard.layoutIfNeeded()
        XCTAssertNil(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.reconvert" && !($0.superview?.isHidden ?? true) })
    }

    func testEmojiSearchReplacesTheReadingAndFillsRecents() throws {
        let keyboard = makeKeyboard()
        let view = UITextView()
        _ = connect(keyboard, to: view)
        func openEmoji() throws -> (KeyboardSymbolPanel, UICollectionView) {
            let emoji = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "表情" } as? UIButton)
            emoji.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
            let panel = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardSymbolPanel }.first)
            panel.layoutIfNeeded()
            return (panel, try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first))
        }
        var (panel, grid) = try openEmoji()
        XCTAssertNil(descendants(panel).first { $0.accessibilityIdentifier == "vime.symbols.category.recent" }, "No recent category before any use")
        try button("vime.symbols.search", in: keyboard).sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        XCTAssertTrue(panel.isHidden)
        XCTAssertFalse(try button("vime.emojiSearch.prompt", in: keyboard).isEnabled)
        XCTAssertTrue(keyboard.brandButton.isHidden, "Search uses the whole row")
        XCTAssertEqual(try button("vime.emojiSearch.close", in: keyboard).accessibilityLabel, "关闭表情搜索")

        for character in "neko" { try button("vime.key." + String(character), in: keyboard).sendActions(for: .touchUpInside) }
        XCTAssertEqual(view.text, "ねこ")
        XCTAssertTrue(KeyboardEmojiSearch.results(reading: "ねこ", typed: "neko").contains("🐱"))
        try button("vime.emojiResult.🐱", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "🐱", "The emoji replaces the reading")
        XCTAssertNil(view.markedTextRange)
        XCTAssertFalse(keyboard.emojiSearchActive)
        XCTAssertEqual(keyboard.preferences.emojiRecents, ["🐱"])

        (panel, grid) = try openEmoji()
        XCTAssertEqual(try button("vime.symbols.category.recent", in: keyboard).title(for: .normal), "最近")
        XCTAssertEqual(grid.numberOfItems(inSection: 0), 1)
        let smileys = try XCTUnwrap(KeyboardSymbolCatalog.emoji.groups.first?.items.first?.text)
        // Emoji availability loads in the background; the panel publishes it whole.
        let deadline = Date().addingTimeInterval(5)
        while panel.collectionView(grid, numberOfItemsInSection: 1) == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: 1))
        XCTAssertEqual(keyboard.preferences.emojiRecents, [smileys, "🐱"], "Most recent first")
        let kaomoji = 1 + KeyboardSymbolCatalog.emoji.groups.count
        panel.collectionView(grid, didSelectItemAt: IndexPath(item: 0, section: kaomoji))
        XCTAssertEqual(keyboard.preferences.emojiRecents.count, 2, "Only emoji are recorded")
        XCTAssertEqual(view.text, "🐱" + smileys + KeyboardSymbolCatalog.kaomoji[0].items[0].text)

        try button("vime.symbols.search", in: keyboard).sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        XCTAssertNotNil(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.emojiResult.🐱" }, "Idle search offers recents")
        for character in "inu" { try button("vime.key." + String(character), in: keyboard).sendActions(for: .touchUpInside) }
        try button("vime.emojiSearch.close", in: keyboard).sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        XCTAssertFalse(keyboard.emojiSearchActive)
        XCTAssertNotNil(view.markedTextRange, "Closing keeps the reading as ordinary input")
        XCTAssertEqual(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.quickCandidates" }?.isHidden, true)
    }

    func testMarkedTextDeletionCancellationModeAndCaretChanges() throws {
        let keyboard = makeKeyboard()
        let view = UITextView()
        view.text = "前後"; view.selectedRange = NSRange(location: 1, length: 0)
        let host = connect(keyboard, to: view)
        for character in "nn" { try button("vime.key." + String(character), in: keyboard).sendActions(for: .touchUpInside) }
        XCTAssertEqual(view.text, "前ん後")
        let delete = try button("vime.key.delete", in: keyboard)
        delete.sendActions(for: .touchDown)
        delete.sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "前後", "Deleting ん removes its entire marked nn input")
        XCTAssertNil(view.markedTextRange)
        for character in "shi" { try button("vime.key." + String(character), in: keyboard).sendActions(for: .touchUpInside) }
        keyboard.resetComposition()
        XCTAssertEqual(view.text, "前後")
        for character in "hi" { try button("vime.key." + String(character), in: keyboard).sendActions(for: .touchUpInside) }
        try button("vime.key.language", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "前ひ後")
        XCTAssertNil(view.markedTextRange)
        try button("vime.key.a", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "前ひa後")
        try button("vime.key.language", in: keyboard).sendActions(for: .touchUpInside)
        try button("vime.key.k", in: keyboard).sendActions(for: .touchUpInside)
        // A host caret/document change must never delete text at the new location.
        view.unmarkText()
        view.selectedRange = NSRange(location: 0, length: 0)
        host.abandon(); keyboard.resetComposition()
        XCTAssertEqual(view.text, "前ひak後")
        try button("vime.key.a", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "あ前ひak後")
        try button("vime.key.return", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "あ前ひak後")
        XCTAssertNil(view.markedTextRange)
    }

    func testTypingDoesNotWaitForDictionary() async throws {
        try skipTimingSensitiveTestOnCI()
        let baseline = KeyboardSession()
        let start = ProcessInfo.processInfo.systemUptime
        for c in "nihongo" { _ = baseline.type(String(c)) }
        let baselineMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000 / 7

        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        let view = UITextView()
        view.text = "前"; view.selectedRange = NSRange(location: 1, length: 0)
        let host = connect(keyboard, to: view)
        try button("vime.key.n", in: keyboard).sendActions(for: .touchUpInside)
        keyboard.resetComposition() // Any older request must not overwrite the next word.
        let raw = "watashihanihongowobenkyoushiteimasu"
        let expected = "私は日本語を勉強しています"
        let ready = expectation(description: "Latest background candidates and conversion preview")
        let updateView = session.onCandidatesChange
        defer { session.onCandidatesChange = nil }
        session.onCandidatesChange = {
            updateView?()
            XCTAssertEqual(session.candidates.first, expected)
            ready.fulfill()
        }
        let burstStart = ProcessInfo.processInfo.systemUptime
        var slowestKey: TimeInterval = 0
        for c in raw {
            let keyStart = ProcessInfo.processInfo.systemUptime
            try button("vime.key." + String(c), in: keyboard).sendActions(for: .touchUpInside)
            slowestKey = max(slowestKey, ProcessInfo.processInfo.systemUptime - keyStart)
        }
        let burst = ProcessInfo.processInfo.systemUptime - burstStart
        XCTAssertEqual(view.text, "前" + session.composition, "Every key appears inline before dictionary completion")
        XCTAssertEqual(host.markedText, session.composition)
        XCTAssertLessThan(burst, 0.5, "A burst must not wait for per-letter dictionary conversion")
        try button("vime.key.space", in: keyboard).sendActions(for: .touchUpInside)
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(view.text, "前" + expected)
        try button("vime.key.return", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(view.text, "前" + expected)
        XCTAssertNil(view.markedTextRange)
        print("Typing latency: synchronous dictionary mean \(baselineMilliseconds) ms/key; background burst \(burst * 1000) ms for \(raw.count) keys; slowest key \(slowestKey * 1000) ms")
    }
    func testSwipeCommitsOnlyOnReleaseAndCancels() throws {
        let keyboard = makeKeyboard()
        var edits: [KeyboardEdit] = []; keyboard.onEdit = { edits += $0 }
        let q = try XCTUnwrap(try button("vime.key.q", in: keyboard) as? KeyboardKey)
        q.updateSwipe(x: 0, y: -30)
        XCTAssertTrue(edits.isEmpty)
        XCTAssertTrue(descendants(keyboard).contains { $0.accessibilityIdentifier == "vime.swipe.preview" })
        try capture(keyboard, name: "keyboard-swipe-preview")
        q.finishSwipe(cancelled: false)
        XCTAssertEqual(edits, [.insert("1")])
        q.updateSwipe(x: 0, y: -30); q.finishSwipe(cancelled: true)
        XCTAssertEqual(edits.count, 1)
        q.updateSwipe(x: 0, y: -30); q.updateSwipe(x: 0, y: 0); q.finishSwipe(cancelled: false)
        XCTAssertEqual(edits.count, 1)
    }

    func testNumericLayoutsLongVowelAndModeIndicator() throws {
        let keyboard = makeKeyboard()
        XCTAssertNotNil(try button("vime.key.prolonged", in: keyboard))
        try button("vime.key.language", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(try button("vime.key.language", in: keyboard).accessibilityValue, "英文")
        XCTAssertFalse(descendants(keyboard).contains { $0.accessibilityIdentifier == "vime.key.prolonged" })
        try capture(keyboard, name: "keyboard-english")
        let kanaMode = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "切换平假名和片假名" } as? UIButton)
        kanaMode.sendActions(for: .touchUpInside)
        XCTAssertNotNil(try button("vime.key.prolonged", in: keyboard))
        try button("vime.key.language", in: keyboard).sendActions(for: .touchUpInside)
        let toggle = try XCTUnwrap(descendants(keyboard).first { ($0 as? UIButton)?.title(for: .normal) == "123" } as? UIButton)
        toggle.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        let one = try button("vime.number.1", in: keyboard)
        let four = try button("vime.number.4", in: keyboard)
        XCTAssertEqual(one.frame.minX, four.frame.minX)
        XCTAssertGreaterThan(four.frame.minY, one.frame.minY)
        try capture(keyboard, name: "keyboard-number-pad")
        XCTAssertTrue(try button("vime.brand.settings", in: keyboard).isHidden)
        try button("vime.number.ABC", in: keyboard).sendActions(for: .touchUpInside)
        let settings = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityLabel == "键盘设置" && !$0.isHidden } as? UIButton)
        settings.sendActions(for: .touchUpInside)
        let layout = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.setting.numbers" } as? UISegmentedControl)
        layout.selectedSegmentIndex = 1; layout.sendActions(for: .valueChanged)
        settings.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        let numbers = try XCTUnwrap(descendants(keyboard).first { ($0 as? UIButton)?.title(for: .normal) == "123" } as? UIButton)
        numbers.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        XCTAssertFalse(descendants(keyboard).contains { $0.accessibilityIdentifier == "vime.number.1" })
        try capture(keyboard, name: "keyboard-number-full")
        let letters = try XCTUnwrap(descendants(keyboard).first { ($0 as? UIButton)?.title(for: .normal) == "ABC" } as? UIButton)
        letters.sendActions(for: .touchUpInside)
        settings.sendActions(for: .touchUpInside)
        try capture(keyboard, name: "keyboard-settings")
    }

    func testNoPaintedSurfaceAndCandidateEdgeEffects() throws {
        let keyboard = makeKeyboard()
        XCTAssertNil(keyboard.backgroundColor?.cgColor.alpha == 0 ? nil : keyboard.backgroundColor)
        XCTAssertFalse(keyboard.layer.sublayers?.contains { $0 is CAShapeLayer } ?? false)
        let scroll = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates" } as? UIScrollView)
        if #available(iOS 26.0, *) {
            XCTAssertTrue(scroll.topEdgeEffect.isHidden && scroll.bottomEdgeEffect.isHidden)
            XCTAssertTrue(scroll.leftEdgeEffect.isHidden && scroll.rightEdgeEffect.isHidden)
        }
        keyboard.hasFullAccess = false
        try button("vime.key.a", in: keyboard).sendActions(for: .touchUpInside)
        XCTAssertEqual(keyboard.accessibilityValue, "输入中：あ")
        XCTAssertTrue(descendants(keyboard).contains { $0.accessibilityLabel == "候选词：あ" })
    }

}
