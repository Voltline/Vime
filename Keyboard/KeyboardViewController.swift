import UIKit

final class KeyboardViewController: UIInputViewController {
    private let keyboard = KeyboardView()
    private var heightConstraint: NSLayoutConstraint?
    private var knownProxy: ObjectIdentifier?
    private var knownBefore: String?
    private var knownAfter: String?
    private var knownSelected: String?
    private var isApplyingEdits = false
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

    override func loadView() { inputView = KeyboardInputView(keyboard: keyboard) }

    override func viewDidLoad() {
        super.viewDidLoad()
        VimeExtensionAudit.start()
        keyboard.hasFullAccess = hasFullAccess
        keyboard.showsFooter = needsInputModeSwitchKey
        keyboard.needsGlobe = needsInputModeSwitchKey
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        // Seed the host with the actual preferred height, including the saved
        // factor/footer, rather than a different temporary keyboard height.
        let height = view.heightAnchor.constraint(equalToConstant: keyboard.preferredHeight(for: view.bounds.width))
        height.identifier = "vime.keyboard.height"
        height.priority = .init(999)
        height.isActive = true
        heightConstraint = height
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
            return KeyboardLearningContext(document: String(describing: ObjectIdentifier(proxy as AnyObject)),
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
        keyboard.onPreeditChange = { [weak self] in self?.updatePreedit($0) }
        keyboard.onSwitchKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        keyboard.onDismiss = { [weak self] in self?.dismissKeyboard() }
        host.onUndoAvailabilityChange = { [weak self] in self?.keyboard.canUndoLineDeletion = $0 }
        keyboard.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host.abandon()
        keyboard.resetComposition()
        keyboard.hasFullAccess = hasFullAccess
        keyboard.reloadHeightPreference()
        updateTraits()
        rememberContext()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let landscape = view.window?.windowScene?.interfaceOrientation.isLandscape ?? false
        keyboard.compact = traitCollection.userInterfaceIdiom == .phone && landscape
        keyboard.showsFooter = needsInputModeSwitchKey
        keyboard.needsGlobe = needsInputModeSwitchKey
        let preferred = keyboard.preferredHeight(for: view.bounds.width)
        if heightConstraint?.constant != preferred { heightConstraint?.constant = preferred }
    }

    override func viewWillDisappear(_ animated: Bool) {
        keyboard.stopInteractions()
        host.abandon()
        keyboard.resetComposition()
        super.viewWillDisappear(animated)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if !isApplyingEdits && contextChanged {
            host.abandon()
            keyboard.resetComposition()
        }
        updateTraits()
        rememberContext()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        if !isApplyingEdits && contextChanged { host.abandon(); keyboard.resetComposition() }
        rememberContext()
    }

    private func updateTraits() {
        keyboard.hasFullAccess = hasFullAccess
        keyboard.returnKeyType = textDocumentProxy.returnKeyType ?? .default
        keyboard.keyboardType = textDocumentProxy.keyboardType ?? .default
    }

    private func rememberContext() {
        // UIKit's disconnected proxy can return nil for documentIdentifier,
        // despite its nonoptional Swift UUID signature. Never bridge that value.
        knownProxy = ObjectIdentifier(textDocumentProxy as AnyObject)
        knownBefore = textDocumentProxy.documentContextBeforeInput
        knownAfter = textDocumentProxy.documentContextAfterInput
        knownSelected = textDocumentProxy.selectedText
    }

    private var contextChanged: Bool {
        knownProxy != ObjectIdentifier(textDocumentProxy as AnyObject) ||
        knownBefore != textDocumentProxy.documentContextBeforeInput ||
        knownAfter != textDocumentProxy.documentContextAfterInput ||
        knownSelected != textDocumentProxy.selectedText
    }

    private func apply(_ edits: [KeyboardEdit]) {
        isApplyingEdits = true
        defer { isApplyingEdits = false }
        host.apply(edits)
        rememberContext()
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
        return KeyboardUndoAnchor(document: String(describing: ObjectIdentifier(proxy as AnyObject)),
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
