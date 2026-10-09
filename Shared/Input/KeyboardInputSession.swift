import Foundation

nonisolated enum KeyboardInputLanguage: String, Sendable {
    case japanese, chinese, english
    var glyph: String {
        switch self { case .japanese: "日"; case .chinese: "中"; case .english: "英" }
    }
    var accessibilityName: String {
        switch self { case .japanese: "日语"; case .chinese: "中文"; case .english: "英文" }
    }
}

/// Presentation policy supplied by the active backend, not inferred from kana.
nonisolated struct KeyboardInputTraits: Equatable, Sendable {
    let language: KeyboardInputLanguage
    let modeLabel: String
    var alternateLanguage: KeyboardInputLanguage = .english
    var supportsPrimaryVariant = false
    var primaryVariantAccessibilityLabel = "切换输入方式"
    var prolongedInput: String? = nil
    var compositionInputSymbols: Set<String> = []
    var comma = ","
    var period = "."
    var compositionSpaceTitle = "确认"
    var compositionReturnTitle = "确认"
    var isEnglish: Bool { language == .english }
    var languageSwitchAccessibilityLabel: String {
        (isEnglish ? alternateLanguage : language).accessibilityName + "英文切换"
    }
}

nonisolated enum KeyboardEdit: Equatable, Sendable {
    case insert(String), deleteBackward, returnKey
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
    var inputTraits: KeyboardInputTraits { get }
    var hostEpoch: Int { get }
    var isComposing: Bool { get }
    var composition: String { get }
    var markedText: KeyboardPreedit? { get }
    var candidatePresentations: [CandidatePresentation] { get }
    var stripPresentations: [CandidatePresentation] { get }
    var showsStrip: Bool { get }
    var candidatesAreCurrent: Bool { get }
    var selectedIndex: Int? { get }
    var candidateResultReadyAt: TimeInterval? { get }
    var onCandidatesChange: (() -> Void)? { get set }
    var onCommittedEdits: ((KeyboardCommitBatch) -> Void)? { get set }
    var leftContextProvider: (() -> String?)? { get set }
    var learningContextProvider: (() -> KeyboardLearningContext?)? { get set }

    func type(_ text: String) -> [KeyboardEdit]
    func backspace() -> [KeyboardEdit]
    func space() -> [KeyboardEdit]
    func enter() -> [KeyboardEdit]
    func confirm() -> [KeyboardEdit]
    func confirmAll() -> [KeyboardEdit]
    func insertLiteral(_ text: String) -> [KeyboardEdit]
    func chooseCandidate(_ token: CandidateSelectionToken) -> [KeyboardEdit]
    func activateEnglish() -> [KeyboardEdit]
    func toggleEnglish() -> [KeyboardEdit]
    func togglePrimaryVariant() -> [KeyboardEdit]
    func updateIntelligence(ranking: CandidateRankingMode, suggestionsEnabled: Bool)
    func reset(preservingContext: Bool)
    func didApplyEdits(_ edits: [KeyboardEdit])
    func invalidateLearningFeedback()
    func takeInputTiming() -> TimeInterval?
}

extension KeyboardInputSession {
    func reset() { reset(preservingContext: false) }
}
