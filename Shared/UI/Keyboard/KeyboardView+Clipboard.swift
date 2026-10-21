import UIKit

// Clipboard monitoring, the paste suggestion and the history panel.
extension KeyboardView {
    func setClipboardActive(_ active: Bool) {
        clipboardActive = active
        updateClipboardMonitoring()
    }

    func updateClipboardMonitoring() {
        let active = clipboardActive && window != nil && preferences.clipboardSuggestions && hasFullAccess
        guard active else {
            if clipboardTimer != nil {
                NotificationCenter.default.removeObserver(self, name: UIPasteboard.changedNotification, object: nil)
                clipboardTimer?.invalidate(); clipboardTimer = nil
            }
            historyRequest += 1
            clipboardHistoryPanel?.present([])
            if panel == .clipboardHistory { panel = .keyboard }
            if preferences.clipboardSuggestions { clipboard.clear() }
            else { clipboard.disable() }
            refresh()
            return
        }
        if clipboardTimer == nil {
            NotificationCenter.default.addObserver(self, selector: #selector(checkClipboard),
                name: UIPasteboard.changedNotification, object: nil)
            let timer = Timer(timeInterval: KeyboardClipboard.fallbackInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkClipboard() }
            }
            timer.tolerance = 0.1
            clipboardTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        checkClipboard()
    }

    @objc func checkClipboard() {
        guard clipboardActive, window != nil, preferences.clipboardSuggestions, hasFullAccess else {
            updateClipboardMonitoring(); return
        }
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        if !clipboardActive || window == nil || !preferences.clipboardSuggestions || !hasFullAccess {
            updateClipboardMonitoring()
        }
    }

    func canUseClipboardSuggestion(_ text: String) -> Bool {
        !clipboardSuggestion.isHidden && panel == .keyboard && !session.isComposing
            && clipboardActive && window != nil && preferences.clipboardSuggestions && hasFullAccess
            && clipboard.text == text && quickCandidateItems().isEmpty
    }

    func insertClipboardText(_ text: String) {
        panel = .keyboard
        let edits = session.confirmAll()
        session.invalidateLearningFeedback()
        session.reset()
        apply(edits + [.insert(text)])
    }

    func openClipboardHistory() {
        panel = .clipboardHistory
        if clipboardHistoryPanel == nil {
            let view = ClipboardHistoryPanel()
            view.onBack = { [weak self] in
                guard let self else { return }
                self.playFeedback(); self.panel = .settings; self.refresh()
            }
            view.onSelect = { [weak self] entry in self?.selectClipboardHistory(entry) }
            view.onClear = { [weak self] in
                guard let self else { return }
                self.historyRequest += 1
                self.clipboardHistoryPanel?.present([], message: String(localized: "正在清空…"))
                Task { [weak self] in
                    guard let self else { return }
                    do { try await self.clipboard.clearHistory(); self.reloadClipboardHistory() }
                    catch { self.clipboardHistoryPanel?.present([], message: String(localized: "清空失败，请重试")) }
                }
            }
            addSubview(view)
            clipboardHistoryPanel = view
        }
        reloadClipboardHistory()
        refresh()
    }

    func reloadClipboardHistory() {
        historyRequest += 1
        let request = historyRequest
        guard panel == .clipboardHistory else { return }
        guard preferences.clipboardSuggestions, hasFullAccess, clipboardActive, window != nil else {
            clipboardHistoryPanel?.present([], message: preferences.clipboardSuggestions
                ? String(localized: "请允许键盘完全访问后查看") : String(localized: "请先在 Vime App 开启剪贴板功能"))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.clipboard.history.entries()
                guard self.panel == .clipboardHistory, self.historyRequest == request else { return }
                self.clipboardHistoryPanel?.present(entries)
            } catch {
                guard self.panel == .clipboardHistory, self.historyRequest == request else { return }
                self.clipboardHistoryPanel?.present([], message: String(localized: "历史暂时无法读取，请稍后重试"))
            }
        }
    }

    func selectClipboardHistory(_ entry: ClipboardHistoryStore.Entry) {
        let request = historyRequest
        Task { [weak self] in
            guard let self else { return }
            let value = try? await self.clipboard.history.text(for: entry.id)
            guard self.panel == .clipboardHistory, self.historyRequest == request,
                  self.clipboardActive, self.window != nil, self.preferences.clipboardSuggestions,
                  self.hasFullAccess, value == entry.text else { return }
            self.playFeedback()
            self.insertClipboardText(entry.text)
            if self.clipboard.text == entry.text { self.clipboard.consume() }
        }
    }
}
