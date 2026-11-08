import Foundation

/// Pinyin input on librime behind the keyboard's session protocol.
///
/// Rime keeps state, so every command runs in order on the engine's queue and
/// none is dropped for a newer one. Results come back in that order: a state
/// replaces the shown preedit and candidates, and a commit goes to the host
/// exactly once, as a batch for commands that returned early or as the
/// returned edits for commands that wait (confirming, literals). Letters show
/// at once as an echo after the last preedit until Rime has processed them.
@MainActor
final class ChineseInputSession: KeyboardInputSession {
    static let collapsedCandidateLimit = RimeEngine.candidateLimit
    static let expandedCandidateLimit = 300

    private let engine: RimeEngine
    private let inbox = RimeResultInbox()
    private let sessionID = UUID()
    private(set) var hostEpoch = 0
    private var english = false
    private var state = RimeState()
    /// Letters typed but not yet processed by Rime.
    private var echo = ""
    private var sent = 0
    private var received = 0
    /// Bumped by reset; results from before it are discarded.
    private var era = 0
    private var generation = 0
    private var presentations: [CandidatePresentation] = []
    private var expanded = false
    private var traditional = false
    /// The last thing that reached the host was a Rime commit, so BackSpace
    /// deleting it also takes back what Rime learned from it.
    private var commitIsForgettable = false

    var onCandidatesChange: (() -> Void)?
    var onCommittedEdits: ((KeyboardCommitBatch) -> Void)?
    var leftContextProvider: (() -> String?)?
    var learningContextProvider: (() -> KeyboardLearningContext?)?

    init(engine: RimeEngine) {
        self.engine = engine
    }

    /// The bundled pinyin data with the user dictionary in the App Group, or
    /// nil when this build carries no Rime data.
    static func bundled() -> ChineseInputSession? {
        guard let data = RimeEngine.bundledData else { return nil }
        return ChineseInputSession(engine: RimeEngine(data: data, userDirectory: userDirectory()))
    }

    /// The keyboard extension owns the learned dictionary in the App Group.
    /// The app keeps its own, so two processes never write one database.
    nonisolated static func userDirectory() -> URL {
        let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard Bundle.main.bundleURL.pathExtension == "appex" else {
            return local.appendingPathComponent("Vime/RimeApp", isDirectory: true)
        }
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup) ?? local
#if DEBUG && targetEnvironment(simulator)
        // Installed-extension UI tests use their own dictionary, never normal history.
        if let id = UserDefaults(suiteName: KeyboardPreferences.appGroup)?.string(forKey: "VimeExtensionLearningTestID"),
           let uuid = UUID(uuidString: id) {
            return root.appendingPathComponent("Vime/Testing/Rime/" + uuid.uuidString, isDirectory: true)
        }
#endif
        return root.appendingPathComponent("Vime/Rime", isDirectory: true)
    }

    // MARK: State

    var inputTraits: KeyboardInputTraits {
        KeyboardInputTraits(language: english ? .english : .chinese, modeLabel: KeyboardInputLanguage.chinese.accessibilityName,
            alternateLanguage: english ? .chinese : .english, compositionInputSymbols: ["'"],
            comma: english ? "," : "，", period: english ? "." : "。")
    }
    var isComposing: Bool { !english && (state.isComposing || !echo.isEmpty) }
    var composition: String { markedText?.text ?? "" }
    var raw: String { isComposing ? state.input + echo : "" }
    /// Rime separates syllables with a space; a full space reads as a gap
    /// between words, so the preedit shows a narrow one instead.
    static let syllableGap = "\u{2006}"

    var markedText: KeyboardPreedit? {
        guard isComposing else { return nil }
        let text = state.preedit.isEmpty ? state.input : state.preedit
        return KeyboardPreedit(text: text.replacingOccurrences(of: " ", with: Self.syllableGap) + echo)
    }
    var candidatePresentations: [CandidatePresentation] { isComposing ? presentations : [] }
    var stripPresentations: [CandidatePresentation] { candidatePresentations }
    var showsStrip: Bool { !candidatePresentations.isEmpty }
    /// Old candidates stay visible while commands run but cannot be chosen.
    var candidatesAreCurrent: Bool { received == sent }
    var selectedIndex: Int? { nil }
    var candidateResultReadyAt: TimeInterval? { nil }

    // MARK: Commands

    func type(_ text: String) -> [KeyboardEdit] {
        if english { commitIsForgettable = false; return settle() + [.insert(text)] }
        let pinyin = text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ($0 == "'" && isComposing) }
        guard pinyin, !text.isEmpty else { return insertLiteral(text) }
        commitIsForgettable = false
        echo += text
        enqueue(.type(text), echo: text.count)
        return []
    }

    func backspace() -> [KeyboardEdit] {
        if isComposing { enqueue(.backspace); return [] }
        let edits = settle()
        if isComposing { enqueue(.backspace); return edits }
        if commitIsForgettable, !english { enqueue(.backspace) }
        commitIsForgettable = false
        return edits + [.deleteBackward]
    }

    func space() -> [KeyboardEdit] {
        if isComposing { enqueue(.space); return [] }
        commitIsForgettable = false
        return settle() + [.insert(" ")]
    }

    func enter() -> [KeyboardEdit] {
        if isComposing { enqueue(.commitInput); return [] }
        commitIsForgettable = false
        return settle() + [.returnKey]
    }

    func confirm() -> [KeyboardEdit] { confirmAll() }

    func confirmAll() -> [KeyboardEdit] {
        isComposing ? run(.commitComposition) : settle()
    }

    func dismissSuggestions() {}

    func insertLiteral(_ text: String) -> [KeyboardEdit] {
        let edits = confirmAll()
        commitIsForgettable = false
        return edits + [.insert(text)]
    }

    func chooseCandidate(_ token: CandidateSelectionToken) -> [KeyboardEdit] {
        guard token.sessionID == sessionID, token.generation == generation, token.kind == .composition,
              candidatesAreCurrent, isComposing, presentations.indices.contains(token.index) else { return [] }
        enqueue(.select(token.index))
        return []
    }

    func activateEnglish() -> [KeyboardEdit] {
        guard !english else { return [] }
        let edits = confirmAll()
        english = true
        hostEpoch += 1
        return edits
    }

    func toggleEnglish() -> [KeyboardEdit] {
        guard english else { return activateEnglish() }
        english = false
        hostEpoch += 1
        return []
    }

    func togglePrimaryVariant() -> [KeyboardEdit] { [] }
    func updateIntelligence(ranking: CandidateRankingMode, suggestionsEnabled: Bool) {}

    func setTraditionalChinese(_ enabled: Bool) {
        guard enabled != traditional else { return }
        traditional = enabled
        enqueue(.setTraditional(enabled))
    }

    func setExpandedCandidates(_ enabled: Bool) {
        guard enabled != expanded else { return }
        expanded = enabled
        if enabled { enqueue(.setCandidateLimit(Self.expandedCandidateLimit)) }
    }

    func reset(preservingContext: Bool) {
        if !preservingContext { hostEpoch += 1 }
        era += 1
        echo = ""
        commitIsForgettable = false
        publish(RimeState())
        enqueue(.clear)
        enqueue(.finishLearning)
        if !expanded { enqueue(.setCandidateLimit(Self.collapsedCandidateLimit)) }
    }

    func didApplyEdits(_ edits: [KeyboardEdit]) {}
    func invalidateLearningFeedback() {}
    func takeInputTiming() -> TimeInterval? { nil }

    // MARK: Engine results

    /// Sends a command and returns at once; its result arrives in order.
    private func enqueue(_ command: RimeEngine.Command, echo count: Int = 0) {
        sent += 1
        let ticket = RimeResultInbox.Ticket(sequence: sent, era: era, echo: count)
        let inbox = inbox
        engine.submit(command) { state in
            inbox.append(ticket, state)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.deliver() }
            }
        }
    }

    /// Runs a command and waits, returning its commit and any earlier one.
    private func run(_ command: RimeEngine.Command) -> [KeyboardEdit] {
        sent += 1
        let ticket = RimeResultInbox.Ticket(sequence: sent, era: era, echo: 0)
        // Earlier commands have delivered by the time this one runs.
        inbox.append(ticket, engine.sendAndWait(command))
        return receive()
    }

    /// Waits for commands still running, so host edits keep their order.
    private func settle() -> [KeyboardEdit] {
        guard received != sent else { return [] }
        return run(.setCandidateLimit(expanded ? Self.expandedCandidateLimit : Self.collapsedCandidateLimit))
    }

    /// A result arrived after its command returned: commits go out as a batch.
    private func deliver() {
        let pending = received
        let edits = receive()
        guard received != pending else { return }
        if !edits.isEmpty { onCommittedEdits?(KeyboardCommitBatch(hostEpoch: hostEpoch, edits: edits)) }
        onCandidatesChange?()
    }

    /// Applies every result that has arrived, in command order.
    private func receive() -> [KeyboardEdit] {
        var edits: [KeyboardEdit] = []
        var latest: RimeState?
        for (ticket, result) in inbox.take() {
            received = max(received, ticket.sequence)
            guard ticket.era == era else { continue }
            echo.removeFirst(min(ticket.echo, echo.count))
            if let commit = result.commit, !commit.isEmpty {
                edits.append(.insert(commit))
                commitIsForgettable = true
            }
            latest = result
        }
        if let latest { publish(latest) }
        return edits
    }

    private func publish(_ next: RimeState) {
        let candidatesChanged = next.candidates != state.candidates || presentations.isEmpty != next.candidates.isEmpty
        state = next
        guard candidatesChanged else { return }
        generation += 1
        presentations = next.candidates.enumerated().map { index, candidate in
            CandidatePresentation(text: candidate.text, source: .conversion, consumedInputCount: 0, correction: nil,
                selectionToken: CandidateSelectionToken(sessionID: sessionID, generation: generation, index: index, kind: .composition),
                detailAnnotation: candidate.comment.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}

/// Results handed from the engine's queue to the main thread, in order.
nonisolated final class RimeResultInbox: @unchecked Sendable {
    struct Ticket: Sendable {
        let sequence: Int
        let era: Int
        /// Echoed letters this command consumes.
        let echo: Int
    }

    private let lock = NSLock()
    private var items: [(Ticket, RimeState)] = []

    func append(_ ticket: Ticket, _ state: RimeState) {
        lock.lock(); defer { lock.unlock() }
        items.append((ticket, state))
    }

    func take() -> [(Ticket, RimeState)] {
        lock.lock(); defer { lock.unlock() }
        defer { items.removeAll() }
        return items.sorted { $0.0.sequence < $1.0.sequence }
    }
}
