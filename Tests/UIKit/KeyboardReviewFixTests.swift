import XCTest
import UIKit

@MainActor
final class KeyboardReviewFixTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    func testDelayedLineDeletionConsumesEachSnapshotOnlyOnceIncludingRepeatedGesture() throws {
        let controller = LineDeletionController()
        controller.proxy.prepare("KEEP\nabc", window: 3, delayed: true)
        controller.loadViewIfNeeded(); controller.viewWillAppear(false)
        defer { controller.viewWillDisappear(false) }
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardTouchSurface }.first)
        surface.onDeleteLine?(); surface.onDeleteLine?()
        XCTAssertEqual(controller.proxy.text.text, "KEEP\n")
        XCTAssertEqual(controller.proxy.deletes, 3)
        controller.proxy.acknowledge()
        controller.textDidChange(nil)
        surface.onDeleteLine?()
        XCTAssertEqual(controller.proxy.text.text, "KEEP\n", "Never delete the preceding newline")
    }

    func testSynchronousLineDeletionContinuesThroughAcknowledgedContextWindows() throws {
        let controller = LineDeletionController()
        controller.proxy.prepare("KEEP\nabcdefghijklmnop", window: 5, delayed: false)
        controller.loadViewIfNeeded(); controller.viewWillAppear(false)
        defer { controller.viewWillDisappear(false) }
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardTouchSurface }.first)
        surface.onDeleteLine?()
        XCTAssertEqual(controller.proxy.text.text, "KEEP\n")
        XCTAssertEqual(controller.proxy.deletes, 16)
    }

    func testDelayedLineDeletionSnapshotsSelectionBeforeDeletingIt() throws {
        let controller = LineDeletionController()
        let before = "KEEP\nabc", selected = "選択\n"
        controller.proxy.prepare(before + selected + "AFTER", window: 100, delayed: true,
            selection: NSRange(location: before.utf16.count, length: selected.utf16.count))
        controller.loadViewIfNeeded(); controller.viewWillAppear(false)
        defer { controller.viewWillDisappear(false) }
        let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardTouchSurface }.first)
        surface.onDeleteLine?()
        XCTAssertEqual(controller.proxy.text.text, "KEEP\nAFTER")
        XCTAssertEqual(controller.proxy.deletes, 4)
    }

    func testLateNeuralSuggestionsPreserveOrderTokensAndHeldButton() async throws {
        let gate = JapaneseCandidateWorker()
        let wasSuspended = JapaneseCandidateWorker.isLanguageModelSuspendedForMemoryPressure
        gate.allowLanguageModel()
        defer { if wasSuspended { gate.handleMemoryPressure() } else { gate.allowLanguageModel() } }
        let suite = "vime.review.suggestions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = KeyboardPreferences(defaults: defaults)
        preferences.candidateRanking = .languageModel; preferences.phraseSuggestions = true
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session, preferences: preferences)
        defer { keyboard.stopInteractions(); session.reset() }
        let ready = expectation(description: "conversion")
        let render = session.onCandidatesChange
        var conversionReady = false
        session.onCandidatesChange = {
            render?()
            if session.isComposing && session.candidatesAreCurrent && !conversionReady {
                conversionReady = true; ready.fulfill()
            }
        }
        _ = session.type("desu")
        await fulfillment(of: [ready], timeout: 10)
        let index = try XCTUnwrap(session.candidates.firstIndex(of: "です"))
        let published = expectation(description: "native list and neural supplement")
        published.expectedFulfillmentCount = 2
        var initial: [String] = []
        var token: CandidateSelectionToken?
        var button: UIButton?
        var committed: [KeyboardEdit] = []
        keyboard.onEdit = { committed += $0 }
        session.onCandidatesChange = {
            render?()
            guard !session.isComposing, !session.suggestions.isEmpty else { return }
            if initial.isEmpty {
                initial = session.suggestions
                token = session.stripPresentations.first?.selectionToken
                keyboard.layoutIfNeeded()
                let scroll = self.descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates" }
                button = scroll.flatMap { self.descendants($0).compactMap { $0 as? UIButton }.first }
                button?.sendActions(for: .touchDown)
            } else {
                XCTAssertEqual(Array(session.suggestions.prefix(initial.count)), initial)
                XCTAssertEqual(session.stripPresentations.first?.selectionToken, token)
            }
            published.fulfill()
        }
        _ = session.choose(index)
        await fulfillment(of: [published], timeout: 15)
        session.onCandidatesChange = render
        XCTAssertLessThanOrEqual(session.suggestions.count, 20)
        XCTAssertEqual(try XCTUnwrap(button).title(for: .normal), initial.first)
        button?.sendActions(for: .touchUpInside)
        XCTAssertFalse(committed.isEmpty, "A late supplement must not discard a held selection")
        XCTAssertTrue(session.suggestions.isEmpty)
    }

    func testInactiveKeyboardPreservesBoundedSharedEmojiCacheAndPressureClearsIt() throws {
        let gate = JapaneseCandidateWorker()
        let wasSuspended = JapaneseCandidateWorker.isLanguageModelSuspendedForMemoryPressure
        defer { if wasSuspended { gate.handleMemoryPressure() } else { gate.allowLanguageModel() } }
        KeyboardEmojiImages.clear()
        defer { KeyboardEmojiImages.clear() }
        let keyboard = KeyboardView(frame: .zero, session: KeyboardSession(asynchronousCandidates: true))
        defer { keyboard.stopInteractions() }
        let image = try XCTUnwrap(KeyboardEmojiImages.displayImage("😀", scale: 3))
        let before = KeyboardEmojiImages.retainedBytes
        XCTAssertGreaterThan(before, 0)
        keyboard.releaseInactiveResources()
        XCTAssertEqual(KeyboardEmojiImages.retainedBytes, before)
        XCTAssertTrue(KeyboardEmojiImages.displayImage("😀", scale: 3) === image)
        XCTAssertLessThanOrEqual(KeyboardEmojiImages.retainedBytes, 8 * 1024 * 1024)
        keyboard.handleMemoryPressure()
        XCTAssertEqual(KeyboardEmojiImages.retainedBytes, 0)
    }
}

@MainActor
private final class LineDeletionController: KeyboardViewController {
    let proxy = LineDeletionProxy()
    override var textDocumentProxy: any UITextDocumentProxy { proxy }
}

@MainActor
private final class LineDeletionProxy: NSObject, UITextDocumentProxy {
    let text = UITextView()
    let documentIdentifier = UUID()
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { text.hasText }
    private var window = 100
    private var delayed = true
    private var before = "", after = ""
    private var selection: String?
    private(set) var deletes = 0
    var documentContextBeforeInput: String? { before }
    var documentContextAfterInput: String? { after }
    var selectedText: String? { selection }
    func prepare(_ value: String, window: Int, delayed: Bool, selection: NSRange? = nil) {
        text.text = value; text.selectedRange = selection ?? NSRange(location: value.utf16.count, length: 0)
        self.window = window; self.delayed = delayed; acknowledge()
    }
    func acknowledge() {
        let value = text.text! as NSString
        before = String(value.substring(to: text.selectedRange.location).suffix(window))
        after = value.substring(from: NSMaxRange(text.selectedRange))
        selection = text.selectedRange.length == 0 ? nil : value.substring(with: text.selectedRange)
    }
    func insertText(_ value: String) { text.insertText(value); if !delayed { acknowledge() } }
    func deleteBackward() { deletes += 1; text.deleteBackward(); if !delayed { acknowledge() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ value: String, selectedRange: NSRange) { text.setMarkedText(value, selectedRange: selectedRange) }
    func unmarkText() { text.unmarkText() }
}
