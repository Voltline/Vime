import Foundation
import os

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
    /// The composition's letters as typed, capitals kept (Rime gets them in
    /// lowercase): those of the input, then the echo's; apostrophes left out.
    private var cased = ""
    /// Space came while the readings keeping capitals were still coming;
    /// the first commits when they arrive.
    private var commitsMixed = false
    private var sent = 0
    private var received = 0
    /// Bumped by reset; results from before it are discarded.
    private var era = 0
    private var generation = 0
    private var presentations: [CandidatePresentation] = []
    /// Display order of the shown candidates, as indices into Rime's list.
    private var order: [Int] = []
    /// What each shown presentation is: Rime's candidate or a correction.
    private enum Slot { case rime(Int), correction(Int), phrase(Int), mixed(Int) }
    /// The user's phrases the whole input spells; they show first.
    private var phrases: [ChineseUserPhrase] = []
    private let userDictionary: ChineseUserDictionaryStore
    private var slots: [Slot] = []
    private var shownCandidates: [RimeCandidate] = []
    /// Phrases for other spellings of the input, when Rime reads it poorly
    /// (typos across syllables); shown second and third, never first.
    private var corrections: [(spelling: String, candidate: RimeCandidate)] = []
    private var correctionInput = ""
    private var correctionRequest: ChineseCandidateRanking.Request?
    static let correctionDelay = 0.08
    /// The model's sentence correction (ChineseSentenceCorrection), first
    /// among `corrections` while it stands; it leads the list when it won clearly.
    private var sentenceRequest: ChineseCandidateRanking.Request?
    private var sentenceInput = ""
    private var correctionLeads = false
    private var sentenceCorrection: (spelling: String, candidate: RimeCandidate)?
    private var sentenceLeads = false
    private var wordCorrections: [(spelling: String, candidate: RimeCandidate)] = []
    static let shownCorrections = 2
    /// Readings that keep letters no pinyin takes as typed (ChineseMixedInput);
    /// the first leads while Rime's best stops short of the input.
    private var mixed: [ChineseMixedInput.Option] = []
    private var mixedInput = ""
    private var mixedRequest: ChineseCandidateRanking.Request?
    /// Rime's candidates waiting for the model before they show.
    private var ranking: (request: ChineseCandidateRanking.Request, candidates: [RimeCandidate])?
    private var chineseModelEnabled = true
    private let exclusions: LearningExclusionList
    private let exclusionsApply: () -> Bool
    private let blocklist: LearningExclusionList
    /// Whether the excluded-terms list applies, read once per composition.
    private var exclusionsActive: Bool
    private var expanded = false
    private var traditional = false
    private var fuzzyPinyin = FuzzyPinyin()
    /// Whether a correction shows the pinyin it was found by. Off by default.
    private var spellingHints = false
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

    init(engine: RimeEngine, exclusions: LearningExclusionList = .shared,
         exclusionsApply: @escaping () -> Bool = { LearningExclusionPolicy.isActive() },
         blocklist: LearningExclusionList = PredictionBlocklist.shared,
         userDictionary: ChineseUserDictionaryStore = ChineseUserDictionaryStore()) {
        self.engine = engine
        self.userDictionary = userDictionary
        self.exclusions = exclusions
        self.exclusionsApply = exclusionsApply
        self.blocklist = blocklist
        exclusionsActive = exclusionsApply()
    }

    /// The bundled pinyin data with the user dictionary in the App Group, or
    /// nil when this build carries no Rime data.
    static func bundled() -> ChineseInputSession? {
        guard let data = RimeEngine.bundledData else { return nil }
        let directory = userDirectory()
        // Only the keyboard's dictionary takes the app's changes.
        let learned = Bundle.main.bundleURL.pathExtension == "appex" ? ChineseLearnedWords.shared() : nil
        return ChineseInputSession(engine: RimeEngine(data: data, userDirectory: directory, learnedWords: learned.map {
            ChineseLearnedWords(userDirectory: directory, pendingDirectory: $0.pendingDirectory, defaults: $0.defaults)
        }))
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
        let text = Self.recased(state.preedit.isEmpty ? state.input : state.preedit, as: casedInput)
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
        // A capital composes too, never as pinyin: it stays as typed (ChineseMixedInput).
        let pinyin = text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ($0 == "'" && isComposing)
        }
        guard pinyin, !text.isEmpty else { return insertLiteral(text) }
        let edits = commitsMixed ? commitCapitals() : []
        commitIsForgettable = false
        inputStartedAt = KeyboardPerformance.start()
        typedAt = inputStartedAt
        echo += text
        cased += text.filter { $0 != "'" }
        enqueue(.type(text.lowercased()), echo: text.count)
        return edits
    }

    func backspace() -> [KeyboardEdit] {
        clearSuggestions()
        commitsMixed = false
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
            if hasCapitals {
                if candidatesAreCurrent, !mixedMayCome, case .mixed(let index)? = slots.first { return chooseMixed(index) }
                if mixedMayCome { commitsMixed = true; return [] }
                return commitCapitals()
            }
            // Space takes the first candidate shown, which the model may have moved.
            if candidatesAreCurrent, case .phrase(let index)? = slots.first { return choosePhrase(index) }
            if candidatesAreCurrent, case .mixed(let index)? = slots.first { return chooseMixed(index) }
            if candidatesAreCurrent, case .correction(let index)? = slots.first {
                let (spelling, candidate) = corrections[index]
                enqueue(.selectSpelling(input: spelling, text: candidate.genuine))
            } else if candidatesAreCurrent, let first = order.first, first != 0 { enqueue(.select(first)) } else { enqueue(.space) }
            return []
        }
        commitIsForgettable = false
        return settle() + [.insert(" ")]
    }

    func enter() -> [KeyboardEdit] {
        clearSuggestions()
        commitsMixed = false
        if isComposing, hasCapitals { return commitTyped() }
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
        case .phrase(let index): return choosePhrase(index)
        case .mixed(let index): return chooseMixed(index)
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
        else { finishRanking(order: nil); ChineseCandidateRanking.release() }
    }

    func retryLanguageModel(requestID: String) {
        guard usesModel, JapaneseCandidateWorker.LanguageModelStorage.shared.retry(requestID: requestID) else { return }
        onCandidatesChange?()
    }

    func handleMemoryPressure() {
        finishRanking(order: nil)
        JapaneseCandidateWorker.LanguageModelStorage.shared.setSuspended(true)
        ChineseCandidateRanking.release()
    }

    /// The reranking model, the sentence scoring package and the score cache.
    func releaseLanguageModels() {
        finishRanking(order: nil)
        ChineseCandidateRanking.release()
    }

    /// The model stays loaded while hidden, as Japanese's does.
    func releaseInactiveResources() {
        finishRanking(order: nil)
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

    func setCorrectionSpellingHints(_ enabled: Bool) { spellingHints = enabled }

    func setExpandedCandidates(_ enabled: Bool) {
        guard enabled != expanded else { return }
        expanded = enabled
        if enabled { enqueue(.setCandidateLimit(Self.expandedCandidateLimit)) }
    }

    func reset(preservingContext: Bool) {
        if !preservingContext { hostEpoch += 1 }
        era += 1
        echo = ""
        commitsMixed = false
        clearSuggestions()
        commitIsForgettable = false
        exclusionsActive = exclusionsApply()
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
        guard LearningExclusionPolicy.allowsLearning(word, active: active, list: exclusions),
              !blocklist.matches(word) else { return }
        let request = suggestionGeneration, list = exclusions, blocklist = blocklist
        engine.continuations(of: word, code: code, limit: Self.suggestionLimit) { [weak self] found in
            MainActor.assumeIsolated {
                guard let self, self.suggestionGeneration == request, self.suggestionsEnabled,
                      !self.english, !self.isComposing else { return }
                let allowed = found.filter {
                    LearningExclusionPolicy.allowsLearning(word + $0.genuine, active: active, list: list)
                        && !blocklist.matches(word + $0.genuine)
                }
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
            // Letters committed or cleared leave only the echo's.
            if result.input.isEmpty { cased = String(cased.suffix(Self.letters(echo).count)) }
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
        let letters = Self.letters(next.input + echo)
        if cased.count > letters.count { cased = String(cased.prefix(letters.count)) }
        if cased.lowercased() != letters { cased = letters }
        if next.input != correctionInput, next.input != sentenceInput { clearCorrections() }
        if mixedKey != mixedInput { clearMixed() }
        // Case alone leaves Rime's candidates as they were.
        guard candidatesChanged else { return scheduleMixed() }
        ranking?.request.cancel()
        ranking = nil
        let context = VimeLanguageModel.sentenceContext(leftContextProvider?() ?? "")
        let active = exclusionsActive, list = exclusions
        let run = ChineseCandidateRanking.sentenceRun(next.candidates)
        let rimeOrder = ChineseCandidateRanking.order(count: next.candidates.count, sentences: run)
        let slots = usesModel ? ChineseCandidateRanking.slots(next.candidates, sentenceLimit: sentenceLimit) {
            LearningExclusionPolicy.allowsLearning($0, active: active, list: list)
        } : ChineseCandidateRanking.Slots()
        guard slots.canReorder else { return show(next.candidates, order: rimeOrder) }
        KeyboardPerformance.record(.candidateModelEligible, since: KeyboardPerformance.start())
        // A cold model loads for later compositions; this one shows at once.
        let warm = JapaneseCandidateWorker.LanguageModelStorage.shared.isReady(for: .chinese)
        let request = ChineseCandidateRanking.Request(
            deadline: ProcessInfo.processInfo.systemUptime + ChineseCandidateRanking.window)
        ChineseCandidateRanking.score(slots.all.map { next.candidates[$0].genuine }, context: context, request: request) {
            [weak self] scores in
            guard let self, self.ranking?.request === request else { return }
            self.finishRanking(order: scores.map {
                ChineseCandidateRanking.order(count: next.candidates.count, sentences: run, slots: slots, scores: $0)
            }, fallback: rimeOrder, weighed: slots.sentences.count)
        }
        guard warm else { return show(next.candidates, order: rimeOrder) }
        ranking = (request, next.candidates)
        rankingStartedAt = KeyboardPerformance.start()
        rankingStartedUptime = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + ChineseCandidateRanking.window) { [weak self] in
            guard let self, self.ranking?.request === request else { return }
            self.finishRanking(order: nil, fallback: rimeOrder, missedWindow: true)
        }
    }

    /// Sentences the model weighs next: all of Rime's, halved each time it
    /// missed its window and doubled again when twice as many would have
    /// come in time; half while memory runs low.
    private var sentenceLimit: Int {
        let limit = os_proc_available_memory() < Self.fullSentenceMemory ? weighedSentences / 2 : weighedSentences
        return max(ChineseCandidateRanking.fewestSentences, limit)
    }
    private var weighedSentences = ChineseCandidateRanking.sentenceLimit
    private var rankingStartedUptime: TimeInterval?
    /// Memory left to the process below which fewer sentences are weighed.
    static let fullSentenceMemory = 48 * 1_048_576

    /// Shows the candidates waiting for the model, in its `order` when it came in time.
    private func finishRanking(order: [Int]?, fallback: [Int]? = nil, missedWindow: Bool = false, weighed: Int = 0) {
        guard let (request, candidates) = ranking else { return }
        let fallback = fallback ?? ChineseCandidateRanking.order(count: candidates.count,
            sentences: ChineseCandidateRanking.sentenceRun(candidates))
        request.cancel()
        ranking = nil
        KeyboardPerformance.record(.chineseRankingWait, since: rankingStartedAt)
        rankingStartedAt = nil
        let elapsed = rankingStartedUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        rankingStartedUptime = nil
        if missedWindow {
            weighedSentences = max(ChineseCandidateRanking.fewestSentences, weighedSentences / 2)
        } else if order != nil, weighed >= weighedSentences, elapsed < ChineseCandidateRanking.window * 0.4 {
            // Twice as many would still have come in time.
            weighedSentences = min(ChineseCandidateRanking.sentenceLimit, weighedSentences * 2)
        }
        if let order {
            KeyboardPerformance.record(.candidateModelUsed, since: KeyboardPerformance.start())
            if order != fallback {
                KeyboardPerformance.record(.candidateModelOrderChanged, since: KeyboardPerformance.start())
            }
        }
        show(candidates, order: order ?? fallback)
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
            if correctionLeads, shown.first == 0 {
                slots.insert(.correction(0), at: 0)
                slots.insert(contentsOf: shown.dropFirst().map(Slot.correction), at: min(2, slots.count))
            } else {
                slots.insert(contentsOf: shown.map(Slot.correction), at: 1)
            }
        }
        if !mixed.isEmpty, hasCapitals {
            // Capitals are no pinyin: the readings keeping them lead.
            slots.insert(contentsOf: mixed.indices.map(Slot.mixed), at: 0)
        } else if !mixed.isEmpty, let first = order.first, !candidates[first].coversInput {
            if corrections.isEmpty {
                // Rime stopped short of the input; the readings that go on lead.
                slots.insert(.mixed(0), at: 0)
                slots.insert(contentsOf: mixed.indices.dropFirst().map(Slot.mixed), at: min(2, slots.count))
            } else {
                // A typo (wixiang), not a word: its correction keeps its place.
                let after = slots.lastIndex { if case .correction = $0 { true } else { false } } ?? 0
                slots.insert(contentsOf: mixed.indices.map(Slot.mixed), at: min(after + 1, slots.count))
            }
        }
        phrases = userPhrases()
        if !phrases.isEmpty {
            let texts = Set(phrases.map(\.text))
            slots.removeAll { if case .rime(let index) = $0 { texts.contains(candidates[index].text) } else { false } }
            slots.insert(contentsOf: phrases.indices.map(Slot.phrase), at: 0)
        }
        self.slots = slots
        presentations = slots.enumerated().map { index, slot in
            let token = CandidateSelectionToken(sessionID: sessionID, generation: generation, index: index, kind: .composition)
            switch slot {
            case .rime(let source):
                let candidate = candidates[source]
                return CandidatePresentation(text: candidate.text, source: .conversion, consumedInputCount: 0, correction: nil,
                    selectionToken: token, detailAnnotation: candidate.comment.flatMap { $0.isEmpty ? nil : $0 })
            case .phrase(let source):
                return CandidatePresentation(text: phrases[source].text, source: .conversion, consumedInputCount: 0,
                    correction: nil, selectionToken: token)
            case .correction(let source):
                let (spelling, candidate) = corrections[source]
                return CandidatePresentation(text: candidate.text, source: .typoCorrection, consumedInputCount: 0, correction: nil,
                    selectionToken: token, detailAnnotation: spellingHints ? spelling : nil)
            case .mixed(let source):
                return CandidatePresentation(text: mixed[source].text, source: .conversion, consumedInputCount: 0,
                    correction: nil, selectionToken: token)
            }
        }
        scheduleMixed()
        scheduleCorrections()
        scheduleSentenceCorrection()
    }

    // MARK: User phrases

    /// Phrases for the whole input, before any part of it was chosen.
    private func userPhrases() -> [ChineseUserPhrase] {
        guard !hasCapitals, !state.preedit.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return [] }
        let letters = state.input.lowercased().filter { ("a"..."z").contains($0) }
        guard !letters.isEmpty, letters.count == state.input.filter({ $0 != "'" }).count else { return [] }
        return userDictionary.phrases(spelledBy: letters)
    }

    /// Commits a phrase in place of the composition; Rime learns nothing from it.
    private func choosePhrase(_ index: Int) -> [KeyboardEdit] {
        guard phrases.indices.contains(index) else { return [] }
        let text = phrases[index].text
        let edits = run(.clear)
        clearSuggestions()
        commitIsForgettable = false
        return edits + [.insert(text)]
    }

    // MARK: Letters no pinyin takes

    private func clearMixed() {
        mixedRequest?.cancel()
        mixedRequest = nil
        mixedInput = ""
        mixed = []
    }

    /// Commits a mixed reading in place of the composition; Rime learns nothing from it.
    private func chooseMixed(_ index: Int) -> [KeyboardEdit] {
        guard mixed.indices.contains(index) else { return [] }
        let text = mixed[index].text
        let edits = run(.clear)
        clearSuggestions()
        commitIsForgettable = false
        return edits + [.insert(text)]
    }

    /// When Rime's best reading stops short of the input at letters no
    /// pinyin takes, converts the pinyin on either side of them on its own
    /// and lets the model choose where the kept letters end.
    private func scheduleMixed() {
        let input = mixedKey
        guard mixedInput != input, isComposing, echo.isEmpty, ranking == nil,
              let (chosen, rest) = casedUnchosen else { return }
        if !hasCapitals {
            guard let first = order.first, shownCandidates.indices.contains(first),
                  !shownCandidates[first].coversInput else { return }
        }
        let splits = ChineseMixedInput.splits(for: rest)
        guard !splits.isEmpty else {
            mixedInput = input
            if commitsMixed { finishPendingSpace() }
            return
        }
        let request = ChineseCandidateRanking.Request(deadline: .infinity)
        mixedRequest?.cancel()
        mixedRequest = request
        mixedInput = input
        let context = VimeLanguageModel.sentenceContext(leftContextProvider?() ?? "")
        engine.lookUp(ChineseMixedInput.spellings(for: splits), limit: 4,
                      isCancelled: { request.isCancelled }) { [weak self] converted in
            MainActor.assumeIsolated {
                guard let self, self.mixedRequest === request, !request.isCancelled, self.mixedKey == input else { return }
                // Text already chosen from the start stays in front of each reading.
                let options = ChineseMixedInput.options(splits, converted: converted).map {
                    ChineseMixedInput.Option(segments: $0.segments, text: chosen + $0.text, genuine: chosen + $0.genuine)
                }
                guard !options.isEmpty else {
                    self.mixedRequest = nil
                    if self.commitsMixed { self.finishPendingSpace() }
                    return
                }
                self.rankMixed(options, context: context, input: input, request: request)
            }
        }
    }

    /// Mixed readings change when the input does, its case included, and
    /// when part of it is chosen.
    private var mixedKey: String {
        casedInput + "\u{0}" + (Self.unchosen(state)?.chosen ?? "")
    }

    /// The input's letters as typed (cased without the echo's).
    private var casedInput: String { String(cased.prefix(Self.letters(state.input).count)) }

    /// Some letter of the composition was typed as a capital.
    private var hasCapitals: Bool {
        isComposing && cased.contains(where: \.isUppercase)
    }

    /// `unchosen` with the letters as typed.
    private var casedUnchosen: (chosen: String, rest: String)? {
        guard let (chosen, rest) = Self.unchosen(state) else { return nil }
        let typed = casedInput
        guard typed.count >= rest.count else { return (chosen, rest) }
        return (chosen, String(typed.suffix(rest.count)))
    }

    private static func letters(_ text: String) -> String { text.filter { $0 != "'" && $0 != " " } }

    /// `text` (a preedit or input) with its trailing letters cased as `typed`
    /// ends, so the capitals typed show; text already chosen stays.
    static func recased(_ text: String, as typed: String) -> String {
        var typed = Array(typed)
        var result: [Character] = []
        for character in text.reversed() {
            if character.isASCII, character.isLetter, let last = typed.last, last.lowercased() == String(character) {
                result.append(last)
                typed.removeLast()
            } else {
                result.append(character)
            }
        }
        return String(result.reversed())
    }

    /// Readings keeping the capitals may still arrive for this input.
    private var mixedMayCome: Bool {
        !echo.isEmpty || received != sent || ranking != nil || mixedRequest != nil || mixedInput != mixedKey
    }

    /// Commits the composition with capitals: the first reading keeping
    /// them when it stands, else the letters as typed after what was chosen.
    private func commitCapitals() -> [KeyboardEdit] {
        commitsMixed = false
        let edits = settle()
        if isComposing, !mixedMayCome, case .mixed(let index)? = slots.first {
            return edits + chooseMixed(index)
        }
        return edits + commitTyped()
    }

    /// Commits the letters as typed, capitals kept, after any chosen text.
    private func commitTyped() -> [KeyboardEdit] {
        let edits = settle()
        guard isComposing else { return edits }
        let text = (Self.unchosen(state)?.chosen ?? "") + (casedUnchosen?.rest ?? Self.recased(state.input, as: casedInput))
        let cleared = run(.clear)
        clearSuggestions()
        commitIsForgettable = false
        return edits + cleared + [.insert(text)]
    }

    /// The Space that waited for the readings keeping capitals.
    private func finishPendingSpace() {
        guard commitsMixed else { return }
        let edits = commitCapitals()
        if !edits.isEmpty { onCommittedEdits?(KeyboardCommitBatch(hostEpoch: hostEpoch, edits: edits)) }
        onCandidatesChange?()
    }

    /// Text chosen from the start of the input (为什么这 of wsm|zhegeshurufavime)
    /// and the letters after it, which Rime's preedit spells with spaces.
    /// Nil unless those letters are what the input ends with.
    static func unchosen(_ state: RimeState) -> (chosen: String, rest: String)? {
        let chosen = String(state.preedit.prefix { !$0.isASCII || !($0.isLetter || $0 == " " || $0 == "'") })
        let rest = String(state.preedit.dropFirst(chosen.count).filter { ("a"..."z").contains($0) })
        guard !rest.isEmpty, state.input.filter({ $0 != "'" }).hasSuffix(rest) else { return nil }
        return (chosen, rest)
    }

    private func rankMixed(_ options: [ChineseMixedInput.Option], context: String, input: String,
                           request: ChineseCandidateRanking.Request) {
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        let weighs = usesModel && options.count > 1 && storage.isReady(for: .chinese) && !storage.isSuspended
        JapaneseCandidateWorker.modelQueue.async { [weak self] in
            var scores: [Double]?
            let stop = { request.isCancelled || storage.isSuspended }
            if weighs, !stop(), let tokenizer = storage.model(for: .chinese)?.tokenizer,
               let model = ChineseSentenceCorrection.Storage.shared.model() {
                scores = try? ChinesePrefixScoring.scores(context: context, candidates: options.map(\.genuine),
                                                          model: model, tokenizer: tokenizer, cancelled: stop)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.mixedRequest === request, !request.isCancelled, self.mixedKey == input else { return }
                    self.mixedRequest = nil
                    self.mixed = Array(ChineseMixedInput.ranked(options, scores: scores).prefix(ChineseMixedInput.shownOptions))
                    guard self.ranking == nil else { return }
                    self.show(self.shownCandidates, order: self.order)
                    if self.commitsMixed { return self.finishPendingSpace() }
                    if self.received == self.sent { self.onCandidatesChange?() }
                }
            }
        }
    }

    // MARK: Spelling corrections

    private func clearCorrections() {
        correctionRequest?.cancel()
        correctionRequest = nil
        correctionInput = ""
        corrections = []
        wordCorrections = []
        sentenceCorrection = nil
        sentenceLeads = false
        sentenceRequest?.cancel()
        sentenceRequest = nil
        sentenceInput = ""
        correctionLeads = false
    }

    /// After a short pause, looks other spellings up when Rime reads the
    /// input poorly; a key typed meanwhile cancels it.
    private func scheduleCorrections() {
        let input = state.input
        guard correctionInput != input, isComposing, echo.isEmpty, !hasCapitals,
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
        let phrases = found.compactMap { item -> (spelling: String, candidate: RimeCandidate)? in
            guard let phrase = PinyinSpellingCorrection.phrase(in: item.candidates),
                  seen.insert(phrase.text).inserted,
                  LearningExclusionPolicy.allowsLearning(phrase.genuine, active: active, list: exclusions),
                  !blocklist.matches(phrase.genuine) else { return nil }
            return (item.spelling, phrase)
        }
        // Commoner words first; equal ones keep the order of their edits.
        wordCorrections = phrases.enumerated().sorted {
            $0.element.candidate.quality == $1.element.candidate.quality
                ? $0.offset < $1.offset : $0.element.candidate.quality > $1.element.candidate.quality
        }.prefix(Self.shownCorrections).map(\.element)
        guard !wordCorrections.isEmpty else { return }
        refreshCorrections()
    }

    /// The sentence correction first, then the word ones, each phrase once.
    private func refreshCorrections() {
        var seen: Set<String> = []
        let all = (sentenceCorrection.map { [$0] } ?? []) + wordCorrections
        corrections = Array(all.filter { seen.insert($0.candidate.text).inserted }.prefix(Self.shownCorrections))
        correctionLeads = sentenceLeads && sentenceCorrection != nil
        guard ranking == nil else { return }
        show(shownCandidates, order: order)
        if received == sent { onCandidatesChange?() }
    }

    // MARK: Sentence correction

    /// After a short pause, scores the shown sentence token by token, looks
    /// up spellings one edit away around its weakest tokens, and weighs what
    /// Rime makes of them against it (ChineseSentenceCorrection). A key typed
    /// meanwhile cancels it.
    private func scheduleSentenceCorrection() {
        let input = state.input
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        guard sentenceInput != input, isComposing, echo.isEmpty, ranking == nil, usesModel, !hasCapitals,
              ChineseSentenceCorrection.isEnabled, ChineseSentenceCorrection.wants(input),
              storage.isReady(for: .chinese), !storage.isSuspended,
              let first = order.first, shownCandidates.indices.contains(first) else { return }
        let literal = shownCandidates[first]
        guard literal.coversInput, literal.genuine.unicodeScalars.contains(where: { $0.properties.isIdeographic })
        else { return }
        let request = ChineseCandidateRanking.Request(deadline: .infinity)
        sentenceRequest?.cancel()
        sentenceRequest = request
        sentenceInput = input
        let context = VimeLanguageModel.sentenceContext(leftContextProvider?() ?? "")
        let text = literal.genuine
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.correctionDelay) { [weak self] in
            guard let self, self.sentenceRequest === request, !request.isCancelled else { return }
            JapaneseCandidateWorker.modelQueue.async {
                var found: (score: Double, spellings: [(spelling: String, edit: ChineseSentenceCorrection.Edit)])?
                if !request.isCancelled, !storage.isSuspended, let model = storage.model(for: .chinese),
                   let lexicon = ChinesePinyinLexicon.bundled,
                   let tokens = try? model.tokenScores(context: context, text: text) {
                    let windows = ChineseSentenceCorrection.windows(tokens: tokens, text: text, input: input, lexicon: lexicon)
                    found = (tokens.reduce(0) { $0 + $1.logProbability },
                             ChineseSentenceCorrection.spellings(for: input, windows: windows))
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.lookUpSentenceSpellings(found, literal: text, input: input, context: context, request: request)
                    }
                }
            }
        }
    }

    private func lookUpSentenceSpellings(_ found: (score: Double, spellings: [(spelling: String, edit: ChineseSentenceCorrection.Edit)])?,
                                         literal: String, input: String, context: String,
                                         request: ChineseCandidateRanking.Request) {
        guard sentenceRequest === request, !request.isCancelled, state.input == input else { return }
        guard let found, !found.spellings.isEmpty else { sentenceRequest = nil; return }
        let edits = Dictionary(found.spellings.map { ($0.spelling, $0.edit) }, uniquingKeysWith: { first, _ in first })
        engine.lookUp(found.spellings.map(\.spelling), limit: ChineseSentenceCorrection.lookupLimit,
                      isCancelled: { request.isCancelled }) { [weak self] converted in
            MainActor.assumeIsolated {
                guard let self, self.sentenceRequest === request, !request.isCancelled, self.state.input == input else { return }
                let active = self.exclusionsActive, list = self.exclusions, blocklist = self.blocklist
                let options = ChineseSentenceCorrection.options(converted, edits: edits, literal: literal) {
                    LearningExclusionPolicy.allowsLearning($0, active: active, list: list) && !blocklist.matches($0)
                }
                guard !options.isEmpty else { self.sentenceRequest = nil; return }
                self.scoreSentenceOptions(options, literal: found.score, context: context, input: input, request: request)
            }
        }
    }

    private func scoreSentenceOptions(_ options: [ChineseSentenceCorrection.Option], literal: Double, context: String,
                                      input: String, request: ChineseCandidateRanking.Request) {
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        JapaneseCandidateWorker.modelQueue.async { [weak self] in
            let stop = { request.isCancelled || storage.isSuspended }
            var scores: [Double]?
            if !stop(), let tokenizer = storage.model(for: .chinese)?.tokenizer,
               let model = ChineseSentenceCorrection.Storage.shared.model() {
                scores = try? ChinesePrefixScoring.scores(
                    context: context, candidates: options.map(\.candidate.genuine),
                    floors: options.map { ChineseSentenceCorrection.floor(literal: literal, option: $0) },
                    model: model, tokenizer: tokenizer, cancelled: stop)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.sentenceRequest === request, !request.isCancelled, self.state.input == input else { return }
                    self.sentenceRequest = nil
                    guard let scores,
                          let decision = ChineseSentenceCorrection.decide(literal: literal, options: options, scores: scores)
                    else { return }
                    self.sentenceCorrection = (decision.option.spelling, decision.option.candidate)
                    self.sentenceLeads = decision.leads
                    self.refreshCorrections()
                }
            }
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
