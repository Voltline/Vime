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
    case moveCursor(horizontal: Int, vertical: Int)
    case deleteToLineStart
    case undoLineDeletion
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
    /// Host supplies the actual left context excluding its owned marked range.
    var leftContextProvider: (() -> String?)?
    private var committedLeftContext = ""
    private var lastPublishedInput = ""
    private var composing = ComposingText()
    var raw: String { composing.input.compactMap { if case .character(let c) = $0.piece { return String(c) }; return nil }.joined() }
    private(set) var mode: InputMode = .hiragana
    private(set) var candidateSnapshots: [CandidateSnapshot] = []
    var candidates: [String] { candidateSnapshots.map(\.text) }
    var candidatePresentations: [CandidatePresentation] { candidateSnapshots.map(\.presentation) }
    var candidatesAreCurrent: Bool { !candidatesPending }
    private(set) var selectedIndex: Int?
    private var previousJapaneseMode: InputMode = .hiragana
    /// Set by the view from KeyboardPreferences.
    var candidateRanking: CandidateRankingMode = .languageModel
    var phraseSuggestions = false
    func updateIntelligence(ranking: CandidateRankingMode, suggestionsEnabled: Bool) {
        guard ranking != candidateRanking || suggestionsEnabled != phraseSuggestions else { return }
        candidateRanking = ranking
        phraseSuggestions = suggestionsEnabled
        clearSuggestions()
        if ranking == .engine && !suggestionsEnabled { worker?.disableLanguageModel() }
        if isComposing { refresh() }
        else { onCandidatesChange?() }
    }
    /// LM continuations shown in the candidate strip while nothing is composing.
    private(set) var suggestions: [String] = []
    private var suggestionGeneration = 0
    var stripPresentations: [CandidatePresentation] {
        isComposing ? candidatePresentations : suggestions.map {
            CandidatePresentation(text: $0, source: .prediction, consumedInputCount: 0, correction: nil)
        }
    }
    var showsStrip: Bool { isComposing || !suggestions.isEmpty }

    // Synchronous mode is used by deterministic conversion tests only.
    init(asynchronousCandidates: Bool = false, memoryDirectoryURL: URL? = nil) {
        engine = asynchronousCandidates ? nil : JapaneseCandidateEngine(memoryDirectoryURL: memoryDirectoryURL,
            learningEnabled: memoryDirectoryURL != nil)
        worker = asynchronousCandidates ? JapaneseCandidateWorker(memoryDirectoryURL: memoryDirectoryURL) : nil
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
        clearSuggestions()
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
        clearSuggestions()
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
        guard isComposing else { clearSuggestions(); return [.insert(" ")] }
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
        worker?.cancelPending()
        return []
    }

    func enter() -> [KeyboardEdit] {
        guard isComposing else { clearSuggestions(); return [.returnKey] }
        return confirm()
    }

    func choose(_ index: Int) -> [KeyboardEdit] {
        guard candidatesAreCurrent, candidates.indices.contains(index) else { return [] }
        let snapshot = candidateSnapshots[index]
        guard snapshot.revision == revision else { return [] }
        engine?.complete(snapshot)
        worker?.complete(snapshot)
        committedLeftContext = String((committedLeftContext + snapshot.text).suffix(96))
        composing = snapshot.remainingComposition
        if composing.isEmpty { reset(preservingContext: true); requestSuggestions() }
        else { refresh(leftContextOverride: committedLeftContext) }
        engine?.flushLearning()
        return [.insert(snapshot.text)]
    }

    func chooseStrip(_ index: Int) -> [KeyboardEdit] {
        isComposing ? choose(index) : chooseSuggestion(index)
    }

    func chooseSuggestion(_ index: Int) -> [KeyboardEdit] {
        guard !isComposing, suggestions.indices.contains(index) else { return [] }
        let text = suggestions[index]
        committedLeftContext = String((committedLeftContext + text).suffix(96))
        clearSuggestions()
        requestSuggestions()
        return [.insert(text)]
    }

    func confirm() -> [KeyboardEdit] {
        guard isComposing else { return [] }
        if let selectedIndex { return choose(selectedIndex) }
        let text = selectedText ?? PreeditPresentation.kana(for: PreeditPresentation.finalized(composing), mode: mode)
        committedLeftContext = String((committedLeftContext + text).suffix(96))
        reset(preservingContext: true)
        requestSuggestions()
        return [.insert(text)]
    }

    func insertLiteral(_ text: String) -> [KeyboardEdit] {
        let edits = confirmAll()
        committedLeftContext = String((committedLeftContext + text).suffix(96))
        clearSuggestions()
        requestSuggestions()
        return edits + [.insert(text)]
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
        if mode == .english { clearSuggestions() }
        return edits
    }

    func toggleEnglish() -> [KeyboardEdit] {
        setMode(mode == .english ? previousJapaneseMode : .english)
    }

    func toggleKana() -> [KeyboardEdit] {
        setMode(mode == .katakana ? .hiragana : .katakana)
    }

    func reset(preservingContext: Bool = false) {
        clearSuggestions()
        revision += 1
        candidatesPending = false
        pendingSpaces = 0
        composing = ComposingText()
        if !preservingContext { committedLeftContext = "" }
        engine?.reset(preservingContext: preservingContext)
        worker?.reset(preservingContext: preservingContext)
        candidateSnapshots = []
        lastPublishedInput = ""
        selectedIndex = nil
    }

    func clearLearning() {
        reset()
        engine?.clearLearning(); worker?.clearLearning()
    }

    private func clearSuggestions() {
        worker?.cancelPending()
        suggestionGeneration += 1
        suggestions = []
    }

    /// Continue the unfinished sentence after a commit. A sentence-final commit
    /// leaves no prompt, so nothing is requested.
    private func requestSuggestions() {
        guard phraseSuggestions, mode != .english, !isComposing, let worker else { return }
        let prompt = VimeLanguageModel.sentenceContext(committedLeftContext)
        guard !prompt.isEmpty else { return }
        let generation = suggestionGeneration
        worker.suggestions(prompt: prompt) { [weak self] texts in
            guard let self, self.suggestionGeneration == generation, !self.isComposing, self.mode != .english else { return }
            self.suggestions = texts
            self.onCandidatesChange?()
        }
    }

    private func refresh(boundary: Bool = false, leftContextOverride: String? = nil) {
        revision += 1
        pendingSpaces = 0
        selectedIndex = nil
        // Partial confirmation requests its remainder before the host applies the
        // returned insert edit. Use the expected committed prefix for that request.
        let leftContext: String?
        if let leftContextOverride { leftContext = leftContextOverride }
        else if let provider = leftContextProvider { leftContext = provider() }
        else { leftContext = committedLeftContext }
        committedLeftContext = String((leftContext ?? "").suffix(96))
        guard let worker else {
            engine?.reconcileContext(leftContext)
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
        let requestedInput = raw
        let continuity = candidateSnapshots.first.map { CandidateContinuity(surface: $0.text, reading: $0.reading, input: lastPublishedInput) }
        worker.candidates(for: boundary ? PreeditPresentation.finalized(composing) : composing,
                          katakana: mode == .katakana, revision: requestedRevision, leftContext: leftContext, continuity: continuity,
                          ranking: candidateRanking) { [weak self] values, resultReadyAt, supplementary in
            if let self, self.revision == requestedRevision { self.lastPublishedInput = requestedInput }
            self?.acceptCandidateUpdate(values, revision: requestedRevision, readyAt: resultReadyAt, supplementary: supplementary)
        }
    }

    func acceptCandidateUpdate(_ values: [CandidateSnapshot], revision requestedRevision: Int,
                               readyAt: TimeInterval? = nil, supplementary: Bool) {
        guard revision == requestedRevision, isComposing,
              values.allSatisfy({ $0.revision == requestedRevision }) else { return }
        // Selection freezes the complete list, including metadata and order.
        // A queued late correction can never change the user's selected text.
        if supplementary && (candidatesPending || selectedIndex != nil || pendingSpaces > 0) { return }
        candidatesPending = false
        candidateResultReadyAt = readyAt
        candidateSnapshots = values
        if !supplementary {
            if pendingSpaces > 0, !values.isEmpty { selectedIndex = (pendingSpaces - 1) % values.count }
            pendingSpaces = 0
        }
        onCandidatesChange?()
    }
}
