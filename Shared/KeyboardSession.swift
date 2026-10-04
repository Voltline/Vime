import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

enum InputMode: String, CaseIterable {
    case hiragana, katakana, english
    var label: String {
        switch self {
        case .hiragana: "あ"
        case .katakana: "ア"
        case .english: "英"
        }
    }
}

enum KeyboardEdit: Equatable {
    case insert(String)
    case deleteBackward
    case returnKey
}

/// Owns conversion state independently of the host's marked-text range.
/// Only confirmation or literal input emits committed document edits.
@MainActor
final class KeyboardSession {
    private let engine: JapaneseCandidateEngine?
    private let worker: JapaneseCandidateWorker?
    private(set) var revision = 0
    private(set) var candidateRequestCount = 0
    private(set) var inputStartedAt: TimeInterval?
    private(set) var candidateResultReadyAt: TimeInterval?
    private var candidatesPending = false
    private var pendingSpaces = 0
    var onCandidatesChange: (() -> Void)?
    private var composing = ComposingText()
    var raw: String { composing.input.compactMap { if case .character(let c) = $0.piece { return String(c) }; return nil }.joined() }
    private(set) var mode: InputMode = .hiragana
    private(set) var candidateSnapshots: [CandidateSnapshot] = []
    var candidates: [String] { candidateSnapshots.map(\.text) }
    var candidatesAreCurrent: Bool { !candidatesPending }
    private(set) var selectedIndex: Int?
    private var previousJapaneseMode: InputMode = .hiragana

    // Synchronous mode is used by deterministic conversion tests only.
    init(asynchronousCandidates: Bool = false) {
        engine = asynchronousCandidates ? nil : JapaneseCandidateEngine()
        worker = asynchronousCandidates ? JapaneseCandidateWorker() : nil
    }

    var isComposing: Bool { !composing.isEmpty }
    var composition: String { PreeditPresentation.kana(for: composing, mode: mode) }
    var preedit: String? {
        let selection = selectedIndex.map {
            candidateSnapshots[$0].text + PreeditPresentation.kana(for: candidateSnapshots[$0].remainingComposition, mode: mode)
        }
        return PreeditPresentation.text(for: composing, mode: mode, selected: selection)
    }
    var selectedText: String? { selectedIndex.map { candidates[$0] } }

    func takeInputTiming() -> TimeInterval? {
        defer { inputStartedAt = nil }
        return inputStartedAt
    }

    func type(_ text: String) -> [KeyboardEdit] {
        inputStartedAt = KeyboardPerformance.start()
        if mode == .english { return [.insert(text)] }
        var edits: [KeyboardEdit] = []
        // Preserve the word boundary even when typing resumes before a queued
        // space conversion finishes; current kana is a safe immediate fallback.
        if selectedIndex != nil || pendingSpaces > 0 || raw.count + text.count > 96 { edits += confirm() }
        RomajiConverter.insert(text.lowercased().replacingOccurrences(of: "-", with: "ー"), into: &composing)
        refresh()
        return edits
    }

    func backspace() -> [KeyboardEdit] {
        if selectedIndex != nil || pendingSpaces > 0 {
            selectedIndex = nil
            pendingSpaces = 0
            return []
        }
        guard !composing.isEmpty else { return [.deleteBackward] }
        composing.deleteBackwardFromCursorPosition(count: 1)
        refresh()
        return []
    }

    func space() -> [KeyboardEdit] {
        guard isComposing else { return [.insert(" ")] }
        // Only an explicit conversion boundary resolves ambiguous n. Normal
        // per-key requests never add a separator or mutate the live composition.
        if composing.convertTarget.hasSuffix("n"), selectedIndex == nil {
            refresh(boundary: true)
        }
        if candidatesPending {
            pendingSpaces += 1
            return []
        }
        guard !candidates.isEmpty else { return confirm() }
        selectedIndex = selectedIndex.map { ($0 + 1) % candidates.count } ?? 0
        return []
    }

    func enter() -> [KeyboardEdit] {
        isComposing ? confirm() : [.returnKey]
    }

    func choose(_ index: Int) -> [KeyboardEdit] {
        guard candidatesAreCurrent, candidates.indices.contains(index) else { return [] }
        let snapshot = candidateSnapshots[index]
        guard snapshot.revision == revision else { return [] }
        composing = snapshot.remainingComposition
        if composing.isEmpty { reset() }
        else {
            engine?.complete(snapshot.candidate)
            worker?.complete(snapshot.candidate)
            refresh()
        }
        return [.insert(snapshot.text)]
    }

    func confirm() -> [KeyboardEdit] {
        guard isComposing else { return [] }
        if let selectedIndex { return choose(selectedIndex) }
        let text = selectedText ?? PreeditPresentation.kana(for: PreeditPresentation.finalized(composing), mode: mode)
        reset()
        return [.insert(text)]
    }

    func insertLiteral(_ text: String) -> [KeyboardEdit] {
        confirmAll() + [.insert(text)]
    }

    func confirmAll() -> [KeyboardEdit] {
        var edits = confirm()
        if isComposing { edits += confirm() }
        return edits
    }

    func setMode(_ newMode: InputMode) -> [KeyboardEdit] {
        if mode != .english && newMode != .english {
            mode = newMode
            previousJapaneseMode = newMode
            refresh()
            return []
        }
        let edits = confirmAll()
        if newMode != .english { previousJapaneseMode = newMode }
        mode = newMode
        return edits
    }

    func toggleEnglish() -> [KeyboardEdit] {
        setMode(mode == .english ? previousJapaneseMode : .english)
    }

    func toggleKana() -> [KeyboardEdit] {
        setMode(mode == .katakana ? .hiragana : .katakana)
    }

    func reset() {
        revision += 1
        candidatesPending = false
        pendingSpaces = 0
        composing = ComposingText()
        engine?.reset()
        worker?.reset()
        candidateSnapshots = []
        selectedIndex = nil
    }

    private func refresh(boundary: Bool = false) {
        revision += 1
        pendingSpaces = 0
        selectedIndex = nil
        guard let worker else {
            if isComposing { candidateRequestCount += 1 }
            candidateSnapshots = engine?.candidates(for: boundary ? PreeditPresentation.finalized(composing) : composing,
                katakana: mode == .katakana, revision: revision) ?? []
            return
        }
        guard isComposing else {
            candidatesPending = false
            candidateSnapshots = []
            worker.reset()
            return
        }
        // Every Roman key requests prediction, even with an unresolved suffix.
        // Retain the old presentation only until this revision's result arrives.
        candidatesPending = true
        candidateRequestCount += 1
        let requestedRevision = revision
        worker.candidates(for: boundary ? PreeditPresentation.finalized(composing) : composing,
                          katakana: mode == .katakana, revision: requestedRevision) { [weak self] values, resultReadyAt in
            guard let self, self.revision == requestedRevision, self.isComposing else { return }
            self.candidatesPending = false
            self.candidateResultReadyAt = resultReadyAt
            self.candidateSnapshots = values
            if self.pendingSpaces > 0, !values.isEmpty {
                self.selectedIndex = (self.pendingSpaces - 1) % values.count
            }
            self.pendingSpaces = 0
            self.onCandidatesChange?()
        }
    }
}
