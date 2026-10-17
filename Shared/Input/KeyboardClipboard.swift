import UIKit

/// The keyboard keeps only the latest text in memory. No history, persistence,
/// candidate-engine calls or logging are involved in clipboard detection.
@MainActor
final class KeyboardClipboard {
    typealias TextLoader = (@escaping (String?) -> Void) -> Progress?
    static let pollingInterval: TimeInterval = 2
    static let maximumUTF8Bytes = 64 * 1024
    private let changeCount: () -> Int
    private let loadText: TextLoader
    private var attemptedChange: Int?
    private var request = 0
    private var loadingRequest: Int?
    private var pending: Progress?
    private(set) var text: String?
    var onChange: (() -> Void)?

    init(changeCount: @escaping () -> Int = { UIPasteboard.general.changeCount }, loadText: TextLoader? = nil) {
        self.changeCount = changeCount
        self.loadText = loadText ?? Self.loadSystemText
    }

    convenience init(changeCount: @escaping () -> Int, readText: @escaping () -> String?) {
        self.init(changeCount: changeCount, loadText: { complete in complete(readText()); return nil })
    }

    private static func loadSystemText(_ complete: @escaping (String?) -> Void) -> Progress? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings,
              let provider = pasteboard.itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            complete(nil); return nil
        }
        return loadText(from: provider, complete: complete)
    }

    static func loadText(from provider: NSItemProvider, complete: @escaping (String?) -> Void) -> Progress {
        provider.loadObject(ofClass: NSString.self) { value, _ in
            let text = value as? String
            DispatchQueue.main.async { complete(text) }
        }
    }

    func poll(enabled: Bool, hasFullAccess: Bool) {
        guard enabled, hasFullAccess else { clear(); return }
        // Cancellation is advisory for item providers. Wait for completion
        // before starting another load, bounding even slow Handoff transfers.
        guard loadingRequest == nil else { return }
        let version = changeCount()
        guard version != attemptedChange else { return }
        // A denied read must not trigger another prompt every two seconds.
        attemptedChange = version
        request += 1
        let currentRequest = request
        loadingRequest = currentRequest
        pending?.cancel(); pending = nil
        if text != nil { text = nil; onChange?() }
        pending = loadText { [weak self] value in
            guard let self, self.loadingRequest == currentRequest else { return }
            self.loadingRequest = nil
            self.pending = nil
            guard self.request == currentRequest, self.changeCount() == version else { return }
            let accepted = value.flatMap { value -> String? in
                guard value.utf8.prefix(Self.maximumUTF8Bytes + 1).count <= Self.maximumUTF8Bytes,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            if self.text != accepted { self.text = accepted; self.onChange?() }
        }
    }

    /// Forget content and cancel pending reads. Preserve an attempted version
    /// with no usable text, so hiding/reopening cannot repeat a denied prompt.
    func clear() {
        request += 1
        pending?.cancel(); pending = nil
        let hadText = text != nil
        text = nil
        if hadText { attemptedChange = nil; onChange?() }
    }

    func consume() {
        request += 1
        pending?.cancel(); pending = nil
        guard text != nil else { return }
        text = nil
        onChange?()
    }

    deinit { pending?.cancel() }
}
