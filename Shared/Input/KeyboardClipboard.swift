import UIKit
import Darwin

/// A new clipboard value is offered once. Its local 24-hour history and the
/// immediately preceding read survive keyboard/host process changes.
@MainActor
final class KeyboardClipboard {
    typealias TextLoader = (@escaping (String?) -> Void) -> Progress?
    // Cross-process copies do not reliably notify a visible keyboard extension.
    // The fallback checks only changeCount; unchanged text is never reloaded.
    static let fallbackInterval: TimeInterval = 0.5
    nonisolated static let suggestionLifetime: TimeInterval = 30
    static let maximumUTF8Bytes = ClipboardHistoryStore.maximumTextBytes
    let history: ClipboardHistoryStore
    private let changeCount: () -> Int
    private let loadText: TextLoader
    private let boot: String
    private let previewLifetime: TimeInterval
    private let now: () -> Date
    private var expiresAt: Date?
    private var expiration: Task<Void, Never>?
    private var attemptedChange: Int?
    private var request = 0
    private var loadingRequest: Int?
    private var needsRefresh = false
    private var pending: Progress?
    private var preparation: Task<Void, Never>?
    private var erasure: Task<Void, Never>?
    private var disabled = false
    private var nextCleanup = Date.distantPast
    private(set) var text: String?
    var isLoading: Bool { loadingRequest != nil }
    var onChange: (() -> Void)?

    init(changeCount: @escaping () -> Int = { UIPasteboard.general.changeCount }, loadText: TextLoader? = nil,
         history: ClipboardHistoryStore = ClipboardHistoryStore(), boot: String = KeyboardClipboard.deviceBoot,
         previewLifetime: TimeInterval = KeyboardClipboard.suggestionLifetime, now: @escaping () -> Date = Date.init) {
        self.changeCount = changeCount
        self.loadText = loadText ?? Self.loadSystemText
        self.history = history
        self.boot = boot
        self.previewLifetime = previewLifetime
        self.now = now
    }

    convenience init(changeCount: @escaping () -> Int, readText: @escaping () -> String?,
                     history: ClipboardHistoryStore = ClipboardHistoryStore()) {
        self.init(changeCount: changeCount, loadText: { complete in complete(readText()); return nil }, history: history)
    }

    nonisolated private static let deviceBoot: String = {
        var value = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return UUID().uuidString }
        return "\(value.tv_sec).\(value.tv_usec)"
    }()

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

    func checkForChanges(enabled: Bool, hasFullAccess: Bool) {
        guard enabled else { disable(); return }
        guard hasFullAccess else { clear(); return }
        expireIfNeeded()
        disabled = false
        if Date() >= nextCleanup {
            nextCleanup = Date().addingTimeInterval(60)
            Task { [weak self] in
                guard let self else { return }
                try? await self.history.removeExpired()
                self.onChange?()
            }
        }
        // Cancellation is advisory for item providers. Wait for completion
        // before starting another load, bounding even slow Handoff transfers.
        guard loadingRequest == nil else { needsRefresh = true; return }
        let version = changeCount()
        guard version != attemptedChange else { return }
        // Repeated notifications must not retry a denied read.
        attemptedChange = version
        request += 1
        let currentRequest = request
        loadingRequest = currentRequest
        pending?.cancel(); pending = nil
        cancelExpiration()
        if text != nil { text = nil; onChange?() }
        preparation = Task { [weak self] in
            guard let self else { return }
            await self.erasure?.value
            guard self.request == currentRequest else { self.completeRead(currentRequest); return }
            let shouldRead = (try? await self.history.beginRead(version: version, boot: self.boot, at: Date())) ?? true
            guard self.request == currentRequest, self.changeCount() == version, shouldRead else {
                self.completeRead(currentRequest)
                return
            }
            self.pending = self.loadText { [weak self] value in
                self?.finishRead(value, version: version, request: currentRequest)
            }
        }
    }

    private func finishRead(_ value: String?, version: Int, request currentRequest: Int) {
        guard loadingRequest == currentRequest else { return }
        pending = nil
        guard request == currentRequest, changeCount() == version else { completeRead(currentRequest); return }
        let accepted = value.flatMap { ClipboardHistoryStore.accepts($0) ? $0 : nil }
        preparation = Task { [weak self] in
            guard let self else { return }
            guard self.request == currentRequest else { self.completeRead(currentRequest); return }
            let fresh = (try? await self.history.record(accepted, version: version, boot: self.boot, at: Date())) ?? true
            defer { self.completeRead(currentRequest) }
            guard self.request == currentRequest, self.changeCount() == version else { return }
            self.text = fresh ? accepted : nil
            if self.text != nil { self.scheduleExpiration() }
            self.onChange?()
        }
    }

    private func completeRead(_ currentRequest: Int) {
        guard loadingRequest == currentRequest else { return }
        loadingRequest = nil
        guard needsRefresh else { return }
        needsRefresh = false
        checkForChanges(enabled: true, hasFullAccess: true)
    }

    private func scheduleExpiration() {
        cancelExpiration()
        expiresAt = now().addingTimeInterval(previewLifetime)
        expiration = Task { [weak self, previewLifetime] in
            do { try await Task.sleep(for: .seconds(previewLifetime)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.consume()
        }
    }

    private func expireIfNeeded() {
        if let expiresAt, now() >= expiresAt { consume() }
    }

    private func cancelExpiration() {
        expiration?.cancel(); expiration = nil; expiresAt = nil
    }

    /// Clear the transient preview, preserving the attempted version. Hiding a
    /// keyboard is not a new copy operation and must not re-arm its button.
    func clear() {
        cancelExpiration()
        needsRefresh = false
        request += 1
        pending?.cancel(); pending = nil
        let hadText = text != nil
        text = nil
        if hadText { onChange?() }
    }

    func disable() {
        clear()
        guard !disabled else { return }
        disabled = true
        attemptedChange = nil
        erasure = Task { try? await history.clear(includingReadState: true) }
    }

    func clearHistory() async throws {
        clear()
        try await history.clear()
    }

    func consume() {
        cancelExpiration()
        request += 1
        pending?.cancel(); pending = nil
        guard text != nil else { return }
        text = nil
        onChange?()
    }

    deinit { pending?.cancel(); preparation?.cancel(); expiration?.cancel() }
}
