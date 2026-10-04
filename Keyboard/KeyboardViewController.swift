import UIKit

final class KeyboardViewController: UIInputViewController {
    private let keyboard = KeyboardView()
    private var heightConstraint: NSLayoutConstraint?
    private var knownProxy: ObjectIdentifier?
    private var knownBefore: String?
    private var knownAfter: String?
    private var knownSelected: String?
    private var isApplyingEdits = false
    private lazy var host = KeyboardHostConnection(
        setMarkedText: { [weak self] in self?.textDocumentProxy.setMarkedText($0, selectedRange: $1) },
        unmarkText: { [weak self] in self?.textDocumentProxy.unmarkText() },
        insertText: { [weak self] in self?.textDocumentProxy.insertText($0) },
        deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() }
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        keyboard.hasFullAccess = hasFullAccess
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: view.topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardMetrics(width: 440, compact: false, showsFooter: false).height)
        height.priority = .init(999)
        height.isActive = true
        heightConstraint = height
        keyboard.inputModeListAction = #selector(switchInputMode(_:event:))
        keyboard.inputModeListTarget = self
        keyboard.onEdit = { [weak self] edits in self?.apply(edits) }
        keyboard.onMarkedTextChange = { [weak self] in self?.updateMarkedText($0) }
        keyboard.onSwitchKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        keyboard.onDismiss = { [weak self] in self?.dismissKeyboard() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        host.abandon()
        keyboard.resetComposition()
        keyboard.hasFullAccess = hasFullAccess
        updateTraits()
        rememberContext()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let landscape = view.window?.windowScene?.interfaceOrientation.isLandscape ?? false
        keyboard.compact = traitCollection.userInterfaceIdiom == .phone && landscape
        keyboard.showsFooter = needsInputModeSwitchKey
        keyboard.needsGlobe = needsInputModeSwitchKey
        heightConstraint?.constant = keyboard.preferredHeight(for: view.bounds.width)
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

    private func updateMarkedText(_ text: String?) {
        isApplyingEdits = true
        defer { isApplyingEdits = false }
        host.updateMarkedText(text)
        rememberContext()
    }

    @objc private func switchInputMode(_ sender: UIView, event: UIEvent) {
        keyboard.confirmComposition()
        keyboard.stopInteractions()
        handleInputModeList(from: sender, with: event)
    }
}
