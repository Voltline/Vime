import Foundation

nonisolated enum KeyboardInputLanguage: String, Sendable {
    case japanese, chinese, english
    var glyph: String {
        switch self { case .japanese: "あ"; case .chinese: "中"; case .english: "A" }
    }
    var accessibilityName: String {
        switch self { case .japanese: String(localized: "日语"); case .chinese: String(localized: "中文"); case .english: String(localized: "英文") }
    }
}

/// Presentation policy supplied by the active backend, not inferred from kana.
nonisolated struct KeyboardInputTraits: Equatable, Sendable {
    let language: KeyboardInputLanguage
    let modeLabel: String
    var alternateLanguage: KeyboardInputLanguage = .english
    var supportsPrimaryVariant = false
    var primaryVariantAccessibilityLabel = String(localized: "切换输入方式")
    var prolongedInput: String? = nil
    var compositionInputSymbols: Set<String> = []
    var convertsNumbers = false
    var comma = ","
    var period = "."
    var compositionSpaceTitle = String(localized: "确认")
    var compositionReturnTitle = String(localized: "确认")
    var isEnglish: Bool { language == .english }
    var languageSwitchAccessibilityLabel: String {
        String(localized: "\((isEnglish ? alternateLanguage : language).accessibilityName)英文切换")
    }
}

nonisolated enum KeyboardEdit: Equatable, Sendable {
    case insert(String), deleteBackward, returnKey
    case insertPair(opening: String, closing: String)
    case moveCursor(horizontal: Int, vertical: Int)
    case deleteToLineStart, undoLineDeletion
}

/// Commands/commits remain ordered; only replaceable candidate snapshots use
/// latest-wins. A backend returns edits OR emits a batch, never both for one commit.
nonisolated struct KeyboardCommitBatch: Sendable {
    let hostEpoch: Int
    let edits: [KeyboardEdit]
}

/// Tokens identify one published list. The backend resolves its own native
/// candidate; UI order is never treated as an engine pointer/selection identity.
nonisolated struct CandidateSelectionToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case composition, suggestion }
    let sessionID: UUID
    let generation: Int
    let index: Int
    let kind: Kind
}

@MainActor
protocol KeyboardInputSession: AnyObject {
    var conversionRangeDescription: String? { get }
    func adjustConversionRange(by delta: Int)
    func resetConversionRange()
    func setExpandedCandidates(_ enabled: Bool)
    var inputTraits: KeyboardInputTraits { get }
    var hostEpoch: Int { get }
    var isComposing: Bool { get }
    var composition: String { get }
    /// The keys typed for the composition, before kana conversion.
    var raw: String { get }
    var markedText: KeyboardPreedit? { get }
    var candidatePresentations: [CandidatePresentation] { get }
    var candidateCount: Int { get }
    func candidatePage(offset: Int, limit: Int) -> [CandidatePresentation]
    var stripPresentations: [CandidatePresentation] { get }
    var showsStrip: Bool { get }
    var candidatesAreCurrent: Bool { get }
    var selectedIndex: Int? { get }
    var candidateResultReadyAt: TimeInterval? { get }
    var candidateInitialRequestStartedAt: TimeInterval? { get }
    var neuralModeSuspendedForMemoryPressure: Bool { get }
    var onCandidatesChange: (() -> Void)? { get set }
    var onCommittedEdits: ((KeyboardCommitBatch) -> Void)? { get set }
    var leftContextProvider: (() -> String?)? { get set }
    var learningContextProvider: (() -> KeyboardLearningContext?)? { get set }

    func type(_ text: String) -> [KeyboardEdit]
    func backspace() -> [KeyboardEdit]
    func space() -> [KeyboardEdit]
    /// Shift picks the other space width in Japanese mode.
    func space(alternateWidth: Bool) -> [KeyboardEdit]
    func enter() -> [KeyboardEdit]
    func confirm() -> [KeyboardEdit]
    func confirmAll() -> [KeyboardEdit]
    /// Hides next-word suggestions without committing anything.
    func dismissSuggestions()
    func insertLiteral(_ text: String) -> [KeyboardEdit]
    /// Kana layouts edit the last composed character in place (repeated taps,
    /// dakuten and small kana). nil: nothing to edit; type a new character.
    func replaceLastKana(_ transform: (Character) -> Character?) -> [KeyboardEdit]?
    func chooseCandidate(_ token: CandidateSelectionToken) -> [KeyboardEdit]
    func activateEnglish() -> [KeyboardEdit]
    func toggleEnglish() -> [KeyboardEdit]
    func togglePrimaryVariant() -> [KeyboardEdit]
    func updateIntelligence(ranking: CandidateRankingMode, suggestionsEnabled: Bool)
    /// Backspace right after a conversion returns it to its reading.
    func setUndoesCommitOnBackspace(_ enabled: Bool)
    /// Japanese mode inserts a full-width space outside a composition.
    func setFullWidthSpace(_ enabled: Bool)
    /// The preedit shows the best conversion while typing (ライブ変換).
    func setLiveConversion(_ enabled: Bool)
    /// The conversion just committed, which the toolbar offers to reconvert.
    var reconvertibleCommit: (text: String, reading: String)? { get }
    /// Deletes that conversion and restores its reading.
    func reconvertCommit() -> [KeyboardEdit]
    /// The text of a candidate whose learning a long press can remove.
    func forgettableCandidate(_ token: CandidateSelectionToken) -> String?
    func forgetCandidate(_ token: CandidateSelectionToken)
    func retryLanguageModel(requestID: String)
    func prepareForInput()
    func setCandidatePresentationPreparation(_ prepare: @escaping @Sendable (CandidatePresentation, Bool) -> Void)
    func reset(preservingContext: Bool)
    func handleMemoryPressure()
    func releaseInactiveResources()
    func didApplyEdits(_ edits: [KeyboardEdit])
    func finishLearningFeedback()
    func invalidateLearningFeedback()
    func takeInputTiming() -> TimeInterval?
}

extension KeyboardInputSession {
    func retryLanguageModel(requestID: String) {}
    func setUndoesCommitOnBackspace(_ enabled: Bool) {}
    func space(alternateWidth: Bool) -> [KeyboardEdit] { space() }
    func setFullWidthSpace(_ enabled: Bool) {}
    func setLiveConversion(_ enabled: Bool) {}
    var reconvertibleCommit: (text: String, reading: String)? { nil }
    func reconvertCommit() -> [KeyboardEdit] { [] }
    func forgettableCandidate(_ token: CandidateSelectionToken) -> String? { nil }
    func forgetCandidate(_ token: CandidateSelectionToken) {}
    var raw: String { "" }
    func prepareForInput() {}
    func setCandidatePresentationPreparation(_ prepare: @escaping @Sendable (CandidatePresentation, Bool) -> Void) {}
    var candidateInitialRequestStartedAt: TimeInterval? { nil }
    func finishLearningFeedback() {}
    var neuralModeSuspendedForMemoryPressure: Bool { false }
    func handleMemoryPressure() {}
    func releaseInactiveResources() {}
    func reset() { reset(preservingContext: false) }
    var conversionRangeDescription: String? { nil }
    func adjustConversionRange(by delta: Int) {}
    func resetConversionRange() {}
    func setExpandedCandidates(_ enabled: Bool) {}
    func replaceLastKana(_ transform: (Character) -> Character?) -> [KeyboardEdit]? { nil }
    var candidateCount: Int { candidatePresentations.count }
    func candidatePage(offset: Int, limit: Int) -> [CandidatePresentation] {
        Array(candidatePresentations.dropFirst(max(0, offset)).prefix(max(0, limit)))
    }
}
