import UIKit
import os

class KeyboardViewController: UIInputViewController {
    private static let liveControllers = NSHashTable<KeyboardViewController>.weakObjects()
    private let keyboard = KeyboardView()
    private let synchronizationLog = Logger(subsystem: "com.Voltline.Vime", category: "CompositionSync")
    private let lifecycleLog = Logger(subsystem: "com.Voltline.Vime", category: "ExtensionLifecycle")
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var knownDocument: String?
    private var knownBefore: String?
    private var knownAfter: String?
    private var knownSelected: String?
    private var isApplyingEdits = false
    private var partialCommitReceipt: KeyboardPartialCommitReceipt?
    private static let documentIdentifierSelector = NSSelectorFromString("documentIdentifier")
    private let cursorLayout = KeyboardProxyCursorLayout()
    private lazy var host = KeyboardHostConnection(
        setMarkedText: { [weak self] in self?.textDocumentProxy.setMarkedText($0, selectedRange: $1) },
        unmarkText: { [weak self] in self?.textDocumentProxy.unmarkText() },
        insertText: { [weak self] in self?.textDocumentProxy.insertText($0) },
        deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
        moveCursor: { [weak self] in self?.moveCursor(horizontal: $0, vertical: $1) },
        deleteToLineStart: { [weak self] in self?.deleteLinePrefix() ?? "" },
        undoAnchor: { [weak self] in self?.deletionUndoAnchor() }
    )

    // A retained input root belongs to its original controller/host connection.
    override func loadView() { view = KeyboardInputView(keyboard: keyboard) }

    override func viewDidLoad() {
        super.viewDidLoad()
        Self.liveControllers.add(self)
        logLifecycle("loaded")
        VimeExtensionAudit.start()
        VimeExtensionAudit.recordLifecycle(event: .viewDidLoad)
        keyboard.hasFullAccess = hasFullAccess
        keyboard.showsFooter = needsInputModeSwitchKey
        keyboard.needsGlobe = needsInputModeSwitchKey
        keyboard.inputModeListAction = #selector(switchInputMode(_:event:))
        keyboard.inputModeListTarget = self
        keyboard.leftContextProvider = { [weak self] in
            guard let self else { return nil }
            var left = self.textDocumentProxy.documentContextBeforeInput
            if let mark = self.host.markedText, left?.hasSuffix(mark) == true {
                left = left.map { String($0.dropLast(mark.count)) }
            }
            return left
        }
        keyboard.learningContextProvider = { [weak self] in
            guard let self else { return nil }
            let proxy = self.textDocumentProxy
            return KeyboardLearningContext(document: self.documentIdentity(proxy),
                before: self.keyboard.leftContextProvider?(), after: proxy.documentContextAfterInput,
                hasSelection: proxy.selectedText?.isEmpty == false)
        }
        keyboard.deletionAvailabilityProvider = { [weak self] in
            guard let self else { return false }
            let proxy = self.textDocumentProxy
            if proxy.selectedText?.isEmpty == false { return true }
            if let before = proxy.documentContextBeforeInput { return !before.isEmpty }
            // Some hosts redact context. Preserve deletion when UIKit reports
            // text, while an explicitly empty prefix means the caret is at start.
            return proxy.hasText
        }
        keyboard.onEdit = { [weak self] edits in self?.apply(edits) }
        keyboard.onEditsAndPreeditChange = { [weak self] in self?.apply($0, preedit: $1) }
        keyboard.onPreeditChange = { [weak self] in self?.updatePreedit($0) }
        keyboard.onSwitchKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        keyboard.onDismiss = { [weak self] in self?.dismissKeyboard() }
        host.onUndoAvailabilityChange = { [weak self] in self?.keyboard.canUndoLineDeletion = $0 }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboard.reloadPreferences()
        (view as? KeyboardInputView)?.attachKeyboard(keyboard)
        logLifecycle("appearing")
        VimeExtensionAudit.recordLifecycle(event: .viewWillAppear)
        host.abandon()
        keyboard.resetComposition()
        keyboard.hasFullAccess = hasFullAccess
        updateKeyboardGeometry()
        updateTraits()
        rememberContext()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateKeyboardGeometry()
    }

    private func updateKeyboardGeometry() {
        let landscape = view.window?.windowScene?.interfaceOrientation.isLandscape ?? false
        keyboard.compact = traitCollection.userInterfaceIdiom == .phone && landscape
        keyboard.showsFooter = needsInputModeSwitchKey
        keyboard.needsGlobe = needsInputModeSwitchKey
        (view as? KeyboardInputView)?.refreshSizing()
    }

    override func viewWillDisappear(_ animated: Bool) {
        logLifecycle("disappearing")
        VimeExtensionAudit.recordLifecycle(event: .viewWillDisappear)
        keyboard.stopInteractions()
        keyboard.finishLearningFeedback()
        host.abandon()
        keyboard.resetComposition()
        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        keyboard.releaseInactiveResources()
        if let input = view as? KeyboardInputView {
            input.detachKeyboard()
        }
        VimeExtensionAudit.recordLifecycle(event: .viewDidDisappear)
        logLifecycle("hidden-cleanup-enqueued")
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        logLifecycle("memory-warning")
        VimeExtensionAudit.recordLifecycle(event: .memoryWarning)
        keyboard.handleMemoryPressure()
    }

    private func logLifecycle(_ event: String) {
        let seconds = Int(ProcessInfo.processInfo.systemUptime - startedAt)
        let instance = String(describing: ObjectIdentifier(self))
        lifecycleLog.notice("Keyboard \(event, privacy: .public); pid=\(ProcessInfo.processInfo.processIdentifier) instance=\(instance, privacy: .public) liveControllers=\(Self.liveControllers.allObjects.count) age=\(seconds)s footprint=\(VimeLanguageModel.footprintMB())MB")
    }

    deinit {
        let instance = String(describing: ObjectIdentifier(self))
        lifecycleLog.notice("Keyboard deallocated; instance=\(instance, privacy: .public) footprint=\(VimeLanguageModel.footprintMB())MB")
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if !isApplyingEdits && contextChanged {
            partialCommitReceipt = nil
            host.abandon()
            keyboard.resetComposition()
        }
        updateTraits()
        rememberContext()
        if !isApplyingEdits { keyboard.hostContextDidChange() }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        if !isApplyingEdits && contextChanged {
            partialCommitReceipt = nil
            host.abandon(); keyboard.resetComposition()
        }
        rememberContext()
        if !isApplyingEdits { keyboard.hostContextDidChange() }
    }

    private func updateTraits() {
        keyboard.hasFullAccess = hasFullAccess
        keyboard.returnKeyType = textDocumentProxy.returnKeyType ?? .default
        keyboard.keyboardType = textDocumentProxy.keyboardType ?? .default
    }

    private func rememberContext() {
        // UIKit's disconnected proxy can return nil for documentIdentifier,
        // despite its nonoptional Swift UUID signature. Never bridge that value.
        let proxy = textDocumentProxy
        knownDocument = documentIdentity(proxy)
        knownBefore = proxy.documentContextBeforeInput
        knownAfter = proxy.documentContextAfterInput
        knownSelected = proxy.selectedText
    }

    private var contextChanged: Bool {
        let proxy = textDocumentProxy
        if partialCommitReceipt?.acknowledges(document: documentIdentity(proxy), before: proxy.documentContextBeforeInput,
            after: proxy.documentContextAfterInput, selection: proxy.selectedText) == true { return false }
        let documentChanged = knownDocument != documentIdentity(proxy)
        let beforeChanged = knownBefore != proxy.documentContextBeforeInput
        let afterChanged = knownAfter != proxy.documentContextAfterInput
        let selectionChanged = knownSelected != proxy.selectedText
        let changed = documentChanged || beforeChanged || afterChanged || selectionChanged
        if changed && host.markedText != nil {
            // Counts/flags only: never expose host text or the user's candidates.
            synchronizationLog.notice("Composition reset: document=\(documentChanged) before=\(beforeChanged) after=\(afterChanged) selection=\(selectionChanged) partial=\(self.partialCommitReceipt != nil) markedLength=\(self.host.markedText?.utf16.count ?? 0)")
        }
        return changed
    }

    private func apply(_ edits: [KeyboardEdit]) {
        partialCommitReceipt = nil
        isApplyingEdits = true
        defer { isApplyingEdits = false }
        host.apply(edits)
        rememberContext()
    }

    private func apply(_ edits: [KeyboardEdit], preedit: KeyboardPreedit?) {
        let proxy = textDocumentProxy
        partialCommitReceipt = KeyboardPartialCommitReceipt(document: documentIdentity(proxy),
            before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
            selection: proxy.selectedText, ownedMark: host.markedText, edits: edits, preedit: preedit)
        isApplyingEdits = true
        defer { isApplyingEdits = false }
        host.apply(edits, preedit: preedit)
        rememberContext()
    }

    private func documentIdentity(_ proxy: any UITextDocumentProxy) -> String {
        // Read the Objective-C object before bridging: a disconnected UIKit
        // proxy sometimes returns nil despite the Swift UUID signature.
        if let object = proxy as? NSObject,
           object.responds(to: Self.documentIdentifierSelector),
           let identifier = object.perform(Self.documentIdentifierSelector)?.takeUnretainedValue() as? NSUUID {
            return identifier.uuidString
        }
        return String(describing: ObjectIdentifier(proxy as AnyObject))
    }

    private func moveCursor(horizontal: Int, vertical: Int) {
        let proxy = textDocumentProxy
        if horizontal == 0 && vertical == 0 {
            cursorLayout.beginGesture(before: proxy.documentContextBeforeInput ?? "",
                after: proxy.documentContextAfterInput ?? "", width: keyboard.bounds.width - 48)
            return
        }
        let offset = cursorLayout.moveInGesture(horizontal: horizontal, vertical: vertical)
        if offset != 0 { proxy.adjustTextPosition(byCharacterOffset: offset) }
    }

    private func deletionUndoAnchor() -> KeyboardUndoAnchor {
        let proxy = textDocumentProxy
        return KeyboardUndoAnchor(document: documentIdentity(proxy),
            before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput, selection: proxy.selectedText)
    }

    private func deleteLinePrefix() -> String {
        var deleted = textDocumentProxy.selectedText ?? ""
        if !deleted.isEmpty { textDocumentProxy.deleteBackward() }
        // Re-read after each bounded context chunk so long explicit lines are
        // handled without crossing a newline or reconstructing host content.
        for _ in 0..<64 {
            guard let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty else { break }
            let prefix = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last ?? ""
            guard !prefix.isEmpty else { break }
            for _ in prefix { textDocumentProxy.deleteBackward() }
            deleted = prefix + deleted
            if before.contains(where: \.isNewline) { break }
        }
        return deleted
    }

    private func updatePreedit(_ preedit: KeyboardPreedit?) {
        if let preedit { partialCommitReceipt?.updatePreedit(preedit) }
        else { partialCommitReceipt = nil }
        isApplyingEdits = true
        defer { isApplyingEdits = false }
        host.updatePreedit(preedit)
        rememberContext()
    }

    @objc private func switchInputMode(_ sender: UIView, event: UIEvent) {
        keyboard.confirmComposition()
        keyboard.stopInteractions()
        handleInputModeList(from: sender, with: event)
    }
}
