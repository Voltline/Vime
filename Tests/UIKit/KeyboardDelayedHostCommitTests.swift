import XCTest
import UIKit

@MainActor
final class KeyboardDelayedHostCommitTests: XCTestCase {
    func testPartialReceiptRejectsCaretFieldAndExternalTextChanges() throws {
        var receipt = try XCTUnwrap(KeyboardPartialCommitReceipt(document: "document-A",
            before: "昨日てんあんはんてん", after: "。", selection: nil,
            ownedMark: "てんあんはんてん", edits: [.insert("天")], preedit: KeyboardPreedit(text: "あんはんてん")))
        XCTAssertTrue(receipt.acknowledges(document: "document-A", before: "昨日天", after: "。", selection: nil))
        XCTAssertTrue(receipt.acknowledges(document: "document-A", before: "昨日天あんはんてん", after: "。", selection: nil))
        XCTAssertFalse(receipt.acknowledges(document: "document-B", before: "昨日天あんはんてん", after: "。", selection: nil))
        XCTAssertFalse(receipt.acknowledges(document: "document-A", before: "昨日天", after: "あんはんてん。", selection: nil))
        XCTAssertFalse(receipt.acknowledges(document: "document-A", before: "昨日天改写", after: "。", selection: nil))
        XCTAssertFalse(receipt.acknowledges(document: "document-A", before: "昨日天あんはんてん", after: "。", selection: "天"))
        XCTAssertFalse(receipt.acknowledges(document: "document-A", before: nil, after: "。", selection: nil))
        receipt.updatePreedit(KeyboardPreedit(text: "あんはんて"))
        XCTAssertTrue(receipt.acknowledges(document: "document-A", before: "昨日天あんはんて", after: "。", selection: nil))
    }

    func testExpandedTianCandidateSurvivesDelayedHostAcknowledgement() async throws {
        let controller = DelayedHostController()
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        controller.view.frame = CGRect(x: 0, y: 240, width: 440, height: 350)
        window.rootViewController?.view.addSubview(controller.view)
        window.isHidden = false
        defer { controller.viewWillDisappear(false); window.isHidden = true }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let keyboard = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? KeyboardView }.first)
        keyboard.layoutIfNeeded()
        func button(_ id: String) throws -> UIButton {
            try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == id } as? UIButton)
        }
        for c in "tennanhantenn" { (try button("vime.key.\(c)") as? KeyboardKey)?.action?() }
        try button("vime.candidates.expand").sendActions(for: .touchUpInside)
        let deadline = Date().addingTimeInterval(10)
        var prefix: UIButton?
        while prefix == nil && Date() < deadline {
            prefix = descendants(keyboard).compactMap { $0 as? UIButton }.first {
                $0.title(for: .normal) == "天" && $0.superview is UIScrollView && $0.isUserInteractionEnabled
            }
            if prefix == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        try XCTUnwrap(prefix).sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.proxy.text.text, "天あんはんてん")
        XCTAssertEqual(keyboard.accessibilityValue, "输入中：あんはんてん")
        // The proxy returns the pre-insertion context during the write, then
        // publishes the new text through textDidChange after the write returns.
        controller.proxy.acknowledge()
        controller.textDidChange(nil)
        controller.selectionDidChange(nil)
        XCTAssertEqual(keyboard.accessibilityValue, "输入中：あんはんてん")
        XCTAssertEqual(controller.proxy.text.text(in: try XCTUnwrap(controller.proxy.text.markedTextRange)), "あんはんてん")
        // Genuine caret movement must still reset, even immediately after a
        // partial commit. Do not mask host changes with a timer or grace period.
        controller.proxy.text.unmarkText()
        controller.proxy.text.selectedRange = NSRange(location: 0, length: 0)
        controller.proxy.acknowledge()
        controller.selectionDidChange(nil)
        XCTAssertFalse(keyboard.accessibilityValue?.hasPrefix("输入中：") ?? true)
        XCTAssertEqual(controller.proxy.text.text, "天あんはんてん")
    }
}

@MainActor
private final class DelayedHostController: KeyboardViewController {
    let proxy = DelayedDocumentProxy()
    override var textDocumentProxy: any UITextDocumentProxy { proxy }
}

/// Exercises the actual extension controller, not a parallel copy of its logic.
@MainActor
private final class DelayedDocumentProxy: NSObject, UITextDocumentProxy {
    let text = UITextView()
    let documentIdentifier = UUID()
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { text.hasText }
    var keyboardType: UIKeyboardType { .default }
    var returnKeyType: UIReturnKeyType { .default }
    private var publishedBefore: String? = ""
    private var publishedAfter: String? = ""
    private var delayed = false
    var documentContextBeforeInput: String? { publishedBefore }
    var documentContextAfterInput: String? { publishedAfter }
    var selectedText: String? {
        text.selectedRange.length == 0 ? nil : (text.text as NSString).substring(with: text.selectedRange)
    }
    func acknowledge() {
        delayed = false
        publishedBefore = (text.text as NSString).substring(to: text.selectedRange.location)
        publishedAfter = (text.text as NSString).substring(from: NSMaxRange(text.selectedRange))
    }
    func insertText(_ value: String) { delayed = true; text.insertText(value) }
    func deleteBackward() { text.deleteBackward(); if !delayed { acknowledge() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        text.selectedRange = NSRange(location: text.selectedRange.location + offset, length: 0)
        if !delayed { acknowledge() }
    }
    func setMarkedText(_ value: String, selectedRange: NSRange) {
        text.setMarkedText(value, selectedRange: selectedRange)
        if !delayed { acknowledge() }
    }
    func unmarkText() { text.unmarkText(); if !delayed { acknowledge() } }
}
