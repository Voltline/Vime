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
    static let suggestionLimit = 12

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
    /// Display order of the shown candidates, as indices into Rime's list.
    private var order: [Int] = []
    /// What each shown presentation is: Rime's candidate or a correction.
    private enum Slot { case rime(Int), correction(Int) }
    private var slots: [Slot] = []
    private var shownCandidates: [RimeCandidate] = []
    /// Phrases for other spellings of the input, when Rime reads it poorly
    /// (typos across syllables); shown second and third, never first.
    private var corrections: [(spelling: String, candidate: RimeCandidate)] = []
    private var correctionInput = ""
    private var correctionRequest: ChineseCandidateRanking.Request?
    static let correctionDelay = 0.14
    static let shownCorrections = 2
    /// Rime's candidates waiting for the model before they show.
    private var ranking: (request: ChineseCandidateRanking.Request, candidates: [RimeCandidate])?
    private var chineseModelEnabled = true
    /// Whether the excluded-terms list applies, read once per composition.
    private var exclusionsActive = LearningExclusionPolicy.isActive()
    private var expanded = false
    private var traditional = false
    private var fuzzyPinyin = FuzzyPinyin()
    /// Next-word suggestions: dictionary phrases that begin with the word
    /// just committed, shown in the strip while nothing is composing.
    private var suggestionsEnabled = true
    private var suggestions: [RimeContinuation] = []
    private var suggestionPresentations: [CandidatePresentation] = []
    /// Bumped whenever suggestions go away, so late lookups are dropped.
    private var suggestionGeneration = 0
    /// The last word of the latest commit, until suggestions are asked for it.
    private var pendingContinuation: (word: String, code: String)?
    /// The last thing that reached the host was a Rime commit, so BackSpace
    /// deleting it also takes back what Rime learned from it.
    private var commitIsForgettable = false
    /// Opt-in profiling only (nil otherwise): when the latest key was typed,
    /// until its candidates show, and when the waiting for the model began.
    private var inputStartedAt: TimeInterval?
    private var typedAt: TimeInterval?
    private var rankingStartedAt: TimeInterval?
    private(set) var candidateInitialRequestStartedAt: TimeInterval?

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
        KeyboardInputTraits(language: english ? .english : .chinese, modeLabel: traditional ? "繁" : "简",
            alternateLanguage: english ? .chinese : .english,
            supportsPrimaryVariant: !english, traditionalChinese: traditional,
            primaryVariantAccessibilityLabel: String(localized: "切换简体和繁体"), compositionInputSymbols: ["'"],
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
    var stripPresentations: [CandidatePresentation] { isComposing ? presentations : suggestionPresentations }
    var showsStrip: Bool { !stripPresentations.isEmpty }
    var suggestionTexts: [String] { isComposing ? [] : suggestionPresentations.map(\.text) }
    /// Old candidates stay visible while commands run but cannot be chosen.
    var candidatesAreCurrent: Bool { received == sent && ranking == nil }
    var selectedIndex: Int? { nil }
    var candidateResultReadyAt: TimeInterval? { nil }

    // MARK: Commands

    func type(_ text: String) -> [KeyboardEdit] {
        clearSuggestions()
        if english { commitIsForgettable = false; return settle() + [.insert(text)] }
        let pinyin = text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ($0 == "'" && isComposing) }
        guard pinyin, !text.isEmpty else { return insertLiteral(text) }
        commitIsForgettable = false
        inputStartedAt = KeyboardPerformance.start()
        typedAt = inputStartedAt
        echo += text
        enqueue(.type(text), echo: text.count)
        return []
    }

    func backspace() -> [KeyboardEdit] {
        clearSuggestions()
        if isComposing { enqueue(.backspace); return [] }
        let edits = settle()
        if isComposing { enqueue(.backspace); return edits }
        if commitIsForgettable, !english { enqueue(.backspace) }
        commitIsForgettable = false
        return edits + [.deleteBackward]
    }

    func space() -> [KeyboardEdit] {
        clearSuggestions()
        if isComposing {
            // Space takes the first candidate shown, which the model may have moved.
            if candidatesAreCurrent, let first = order.first, first != 0 { enqueue(.select(first)) } else { enqueue(.space) }
            return []
        }
        commitIsForgettable = false
        return settle() + [.insert(" ")]
    }

    func enter() -> [KeyboardEdit] {
        clearSuggestions()
        if isComposing { enqueue(.commitInput); return [] }
        commitIsForgettable = false
        return settle() + [.returnKey]
    }

    func confirm() -> [KeyboardEdit] { confirmAll() }

    func confirmAll() -> [KeyboardEdit] {
        isComposing ? run(.commitComposition) : settle()
    }

    func dismissSuggestions() { clearSuggestions() }

    func insertLiteral(_ text: String) -> [KeyboardEdit] {
        let edits = confirmAll()
        clearSuggestions()
        commitIsForgettable = false
        return edits + [.insert(text)]
    }

    func chooseCandidate(_ token: CandidateSelectionToken) -> [KeyboardEdit] {
        if token.kind == .suggestion { return chooseSuggestion(token) }
        guard token.sessionID == sessionID, token.generation == generation, token.kind == .composition,
              candidatesAreCurrent, isComposing, slots.indices.contains(token.index) else { return [] }
        switch slots[token.index] {
        case .rime(let index): enqueue(.select(index))
        case .correction(let index):
            let (spelling, candidate) = corrections[index]
            enqueue(.selectSpelling(input: spelling, text: candidate.genuine))
        }
        return []
    }

    func activateEnglish() -> [KeyboardEdit] {
        guard !english else { return [] }
        let edits = confirmAll()
        clearSuggestions()
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

    /// The 简/繁 button, where Japanese has the kana toggle.
    func togglePrimaryVariant() -> [KeyboardEdit] {
        guard !english else { return [] }
        setTraditionalChinese(!traditional)
        return []
    }
    /// Japanese ranking is ignored: Chinese has its own switch,
    /// setChineseLanguageModel. Next-word suggestions follow the shared one.
    func updateIntelligence(ranking: CandidateRankingMode, suggestionsEnabled: Bool) {
        self.suggestionsEnabled = suggestionsEnabled
        if !suggestionsEnabled { clearSuggestions() }
    }

    func setChineseLanguageModel(_ enabled: Bool) {
        let wasRanking = usesModel
        chineseModelEnabled = enabled
        modelRankingChanged(from: wasRanking)
    }

    /// The model reorders candidates: Chinese smart ranking is on (Japanese
    /// ranking is a separate setting), and memory pressure has not paused it.
    private var usesModel: Bool { chineseModelEnabled }
    var neuralModeSuspendedForMemoryPressure: Bool {
        usesModel && JapaneseCandidateWorker.LanguageModelStorage.shared.isSuspended
    }

    private func modelRankingChanged(from wasRanking: Bool) {
        guard usesModel != wasRanking else { return }
        if usesModel { JapaneseCandidateWorker.LanguageModelStorage.shared.setSuspended(false) }
        else { finishRanking(scores: nil); ChineseCandidateRanking.release() }
    }

    func retryLanguageModel(requestID: String) {
        guard usesModel, JapaneseCandidateWorker.LanguageModelStorage.shared.retry(requestID: requestID) else { return }
        onCandidatesChange?()
    }

    func handleMemoryPressure() {
        finishRanking(scores: nil)
        JapaneseCandidateWorker.LanguageModelStorage.shared.setSuspended(true)
        ChineseCandidateRanking.release()
    }

    /// The model stays loaded while hidden, as Japanese's does.
    func releaseInactiveResources() {
        finishRanking(scores: nil)
    }

    func setTraditionalChinese(_ enabled: Bool) {
        guard enabled != traditional else { return }
        traditional = enabled
        enqueue(.setTraditional(enabled))
    }

    func setFuzzyPinyin(_ groups: FuzzyPinyin) {
        guard groups != fuzzyPinyin else { return }
        fuzzyPinyin = groups
        enqueue(.setFuzzy(groups))
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
        clearSuggestions()
        commitIsForgettable = false
        exclusionsActive = LearningExclusionPolicy.isActive()
        typedAt = nil
        publish(RimeState())
        enqueue(.clear)
        enqueue(.finishLearning)
        if !expanded { enqueue(.setCandidateLimit(Self.collapsedCandidateLimit)) }
    }

    func didApplyEdits(_ edits: [KeyboardEdit]) {}
    func invalidateLearningFeedback() {}
    func takeInputTiming() -> TimeInterval? {
        defer { inputStartedAt = nil }
        return inputStartedAt
    }

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
        let edits = receive()
        requestSuggestions()
        return edits
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
        requestSuggestions()
        announceCandidates()
    }

    // MARK: Next-word suggestions

    private func clearSuggestions() {
        suggestionGeneration += 1
        pendingContinuation = nil
        guard !suggestionPresentations.isEmpty else { return }
        suggestions = []
        suggestionPresentations = []
        generation += 1
    }

    /// Asks for phrases continuing the latest commit once every command has
    /// answered and nothing is being typed.
    private func requestSuggestions() {
        guard let (word, code) = pendingContinuation, received == sent else { return }
        pendingContinuation = nil
        guard suggestionsEnabled, !english, !isComposing else { return }
        lookUpContinuations(of: word, code: code)
    }

    private func lookUpContinuations(of word: String, code: String) {
        let active = exclusionsActive
        // Text the learning filter excludes gets no suggestions, and suggestions never produce it.
        guard LearningExclusionPolicy.allowsLearning(word, active: active) else { return }
        let request = suggestionGeneration
        engine.continuations(of: word, code: code, limit: Self.suggestionLimit) { [weak self] found in
            MainActor.assumeIsolated {
                guard let self, self.suggestionGeneration == request, self.suggestionsEnabled,
                      !self.english, !self.isComposing else { return }
                let allowed = found.filter { LearningExclusionPolicy.allowsLearning(word + $0.genuine, active: active) }
                guard !allowed.isEmpty else { return }
                self.showSuggestions(allowed)
            }
        }
    }

    private func showSuggestions(_ found: [RimeContinuation]) {
        generation += 1
        suggestions = found
        suggestionPresentations = found.enumerated().map { index, item in
            CandidatePresentation(text: item.text, source: .contextPrediction, consumedInputCount: 0, correction: nil,
                selectionToken: CandidateSelectionToken(sessionID: sessionID, generation: generation, index: index, kind: .suggestion))
        }
        onCandidatesChange?()
    }

    /// Inserts a suggestion and offers what may follow it in turn.
    private func chooseSuggestion(_ token: CandidateSelectionToken) -> [KeyboardEdit] {
        guard token.sessionID == sessionID, token.generation == generation, !isComposing, !english,
              suggestions.indices.contains(token.index) else { return [] }
        let item = suggestions[token.index]
        let edits = settle()
        clearSuggestions()
        commitIsForgettable = false
        lookUpContinuations(of: item.genuine, code: item.code)
        return edits + [.insert(item.text)]
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
                pendingContinuation = result.commitWord.flatMap { word in result.commitCode.map { (word, $0) } }
            }
            latest = result
        }
        if let latest { publish(latest) }
        return edits
    }

    private func publish(_ next: RimeState) {
        let previous = ranking?.candidates ?? state.candidates
        let candidatesChanged = next.candidates != previous || presentations.isEmpty != next.candidates.isEmpty
        state = next
        if next.input != correctionInput { clearCorrections() }
        guard candidatesChanged else { return }
        ranking?.request.cancel()
        ranking = nil
        let context = VimeLanguageModel.sentenceContext(leftContextProvider?() ?? "")
        let active = exclusionsActive
        let slots = usesModel ? ChineseCandidateRanking.slots(next.candidates) {
            LearningExclusionPolicy.allowsLearning($0, active: active)
        } : []
        guard slots.count > 1 else { return show(next.candidates, order: Array(next.candidates.indices)) }
        KeyboardPerformance.record(.candidateModelEligible, since: KeyboardPerformance.start())
        // A cold model loads for later compositions; this one shows at once.
        let warm = JapaneseCandidateWorker.LanguageModelStorage.shared.isReady(for: .chinese)
        let request = ChineseCandidateRanking.Request(
            deadline: ProcessInfo.processInfo.systemUptime + ChineseCandidateRanking.window)
        ChineseCandidateRanking.score(slots.map { next.candidates[$0].genuine }, context: context, request: request) {
            [weak self] scores in
            guard let self, self.ranking?.request === request else { return }
            self.finishRanking(scores: scores.map { (slots, $0) })
        }
        guard warm else { return show(next.candidates, order: Array(next.candidates.indices)) }
        ranking = (request, next.candidates)
        rankingStartedAt = KeyboardPerformance.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + ChineseCandidateRanking.window) { [weak self] in
            guard let self, self.ranking?.request === request else { return }
            self.finishRanking(scores: nil)
        }
    }

    /// Shows the candidates waiting for the model, in its order when `scores` came in time.
    private func finishRanking(scores: (slots: [Int], values: [Double])?) {
        guard let (request, candidates) = ranking else { return }
        request.cancel()
        ranking = nil
        let order = scores.map { ChineseCandidateRanking.order(count: candidates.count, slots: $0.slots, scores: $0.values) }
        KeyboardPerformance.record(.chineseRankingWait, since: rankingStartedAt)
        rankingStartedAt = nil
        if let order {
            KeyboardPerformance.record(.candidateModelUsed, since: KeyboardPerformance.start())
            if order != Array(candidates.indices) {
                KeyboardPerformance.record(.candidateModelOrderChanged, since: KeyboardPerformance.start())
            }
        }
        show(candidates, order: order ?? Array(candidates.indices))
        if received == sent { announceCandidates() }
    }

    /// Tells the keyboard; once the latest key's candidates are final, it
    /// measures from that key until they can be chosen.
    private func announceCandidates() {
        if candidatesAreCurrent, let typedAt {
            candidateInitialRequestStartedAt = typedAt
            self.typedAt = nil
        }
        defer { candidateInitialRequestStartedAt = nil }
        onCandidatesChange?()
    }

    private func show(_ candidates: [RimeCandidate], order: [Int]) {
        generation += 1
        self.order = order
        shownCandidates = candidates
        var slots = order.map(Slot.rime)
        if !corrections.isEmpty, !slots.isEmpty {
            // A correction moves its phrase up instead of showing it twice.
            let moved = Set(corrections.map(\.candidate.text))
            slots.removeAll { if case .rime(let index) = $0 { index != order.first && moved.contains(candidates[index].text) } else { false } }
            let shown = corrections.indices.filter { corrections[$0].candidate.text != candidates[order[0]].text }
            slots.insert(contentsOf: shown.map(Slot.correction), at: 1)
        }
        self.slots = slots
        presentations = slots.enumerated().map { index, slot in
            let token = CandidateSelectionToken(sessionID: sessionID, generation: generation, index: index, kind: .composition)
            switch slot {
            case .rime(let source):
                let candidate = candidates[source]
                return CandidatePresentation(text: candidate.text, source: .conversion, consumedInputCount: 0, correction: nil,
                    selectionToken: token, detailAnnotation: candidate.comment.flatMap { $0.isEmpty ? nil : $0 })
            case .correction(let source):
                let (spelling, candidate) = corrections[source]
                return CandidatePresentation(text: candidate.text, source: .typoCorrection, consumedInputCount: 0, correction: nil,
                    selectionToken: token, detailAnnotation: spelling)
            }
        }
        scheduleCorrections()
    }

    // MARK: Spelling corrections

    private func clearCorrections() {
        correctionRequest?.cancel()
        correctionRequest = nil
        correctionInput = ""
        corrections = []
    }

    /// After a short pause, looks other spellings up when Rime reads the
    /// input poorly; a key typed meanwhile cancels it.
    private func scheduleCorrections() {
        let input = state.input
        guard correctionInput != input, isComposing, echo.isEmpty,
              PinyinSpellingCorrection.wantsCorrection(input, top: state.candidates.first) else { return }
        let request = ChineseCandidateRanking.Request(deadline: .infinity)
        correctionRequest = request
        correctionInput = input
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.correctionDelay) { [weak self] in
            guard let self, self.correctionRequest === request, !request.isCancelled else { return }
            let spellings = PinyinSpellingCorrection.spellings(for: input)
            guard !spellings.isEmpty else { self.correctionRequest = nil; return }
            self.engine.lookUp(spellings, limit: 4, isCancelled: { request.isCancelled }) { [weak self] found in
                MainActor.assumeIsolated { self?.finishCorrections(found, input: input, request: request) }
            }
        }
    }

    private func finishCorrections(_ found: [(spelling: String, candidates: [RimeCandidate])], input: String,
                                   request: ChineseCandidateRanking.Request) {
        guard correctionRequest === request, !request.isCancelled, state.input == input else { return }
        correctionRequest = nil
        let active = exclusionsActive
        var seen: Set<String> = []
        corrections = found.compactMap { item in
            guard let phrase = PinyinSpellingCorrection.phrase(in: item.candidates),
                  seen.insert(phrase.text).inserted,
                  LearningExclusionPolicy.allowsLearning(phrase.genuine, active: active) else { return nil }
            return (item.spelling, phrase)
        }.prefix(Self.shownCorrections).map { $0 }
        guard !corrections.isEmpty, ranking == nil else { return }
        show(shownCandidates, order: order)
        if received == sent { onCandidatesChange?() }
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
