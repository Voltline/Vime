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
    /// Space came before the candidates were final; the first of them
    /// commits when they are.
    private var spaceWaits = false
    private var sent = 0
    private var received = 0
    /// Bumped by reset; results from before it are discarded.
    private var era = 0
    private var generation = 0
    private var presentations: [CandidatePresentation] = []
    /// Display order of the shown candidates, as indices into Rime's list.
    private var order: [Int] = []
    /// What each shown presentation is: Rime's candidate or a correction.
    private typealias Slot = ChineseCandidateList.Slot
    /// The user's phrases the open input spells; they show first.
    private var phrases: [ChineseUserPhrase] = []
    private let userDictionary: ChineseUserDictionaryStore
    private var slots: [Slot] = []
    private var shownCandidates: [RimeCandidate] = []
    /// Phrases for other spellings of the open input, when Rime reads it
    /// poorly (typos across syllables); shown second and third, never first.
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
    /// Readings of the open input that keep letters no pinyin takes as typed
    /// (ChineseMixedInput), placed by `mixedPlacement`.
    private var mixed: [ChineseMixedInput.Option] = []
    private var mixedPlacement = ChineseCandidateList.MixedPlacement.none
    /// The candidates of the latest result on their way to the list.
    private var round: Round?
    /// What the shown list, or the one on its way, was made from.
    private var roundKey: RoundKey?
    /// A round shown without the model when it missed the window, and the
    /// commands sent then: its scores may still reorder that list once.
    private var late: (round: Round, sent: Int)?
    /// How long a new list waits for the model; tests shorten it.
    var rankingWindow = ChineseCandidateRanking.window
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
    /// Special conversion candidates (date/time/weekday/lunar) appended after normal candidates.
    private var specials: [ChineseSpecialConversions.Candidate] = []
    /// Local `v`-prefixed numeric buffer (bypasses Rime so digits/`.` compose RMB uppercase directly).
    private var vBuffer = ""
    private var specialDateFormat: ChineseSpecialConversions.DateFormat = .chinese
    private var specialTimeFormat: ChineseSpecialConversions.TimeFormat = .colon
    var specialConversionsNow: () -> Date = { Date() }
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
    var isComposing: Bool { !vBuffer.isEmpty || state.isComposing || !echo.isEmpty }
    private(set) var suppressesEnglishCompletions = false
    var composition: String { markedText?.text ?? "" }
    var raw: String { !vBuffer.isEmpty ? vBuffer : (isComposing ? state.input + echo : "") }
    /// Rime separates syllables with a space; a full space reads as a gap
    /// between words, so the preedit shows a narrow one instead.
    static let syllableGap = "\u{2006}"

    var markedText: KeyboardPreedit? {
        if !vBuffer.isEmpty { return KeyboardPreedit(text: vBuffer) }
        guard isComposing else { return nil }
        let text = Self.recased(state.preedit.isEmpty ? state.input : state.preedit, as: casedInput)
        return KeyboardPreedit(text: text.replacingOccurrences(of: " ", with: Self.syllableGap) + echo)
    }
    var candidatePresentations: [CandidatePresentation] { isComposing ? presentations : [] }
    var stripPresentations: [CandidatePresentation] { isComposing ? presentations : suggestionPresentations }
    var showsStrip: Bool { !stripPresentations.isEmpty }
    var suggestionTexts: [String] { isComposing ? [] : suggestionPresentations.map(\.text) }
    /// Old candidates stay visible while commands run but cannot be chosen.
    var candidatesAreCurrent: Bool { !vBuffer.isEmpty || (received == sent && round == nil) }
    var selectedIndex: Int? { nil }
    var candidateResultReadyAt: TimeInterval? { nil }

    // MARK: Commands

    private static func isEnglishWordText(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    func acceptsCompositionSymbol(_ text: String) -> Bool {
        guard !english else { return false }
        let candidateBuffer = !vBuffer.isEmpty ? vBuffer : (raw == "v" ? "v" : "")
        return ChineseSpecialConversions.canAppendToVBuffer(candidateBuffer, text: text)
    }

    func type(_ text: String) -> [KeyboardEdit] {
        clearSuggestions()
        if english {
            commitIsForgettable = false
            if isComposing {
                let edits = commitTyped()
                suppressesEnglishCompletions = Self.isEnglishWordText(text)
                return edits + [.insert(text)]
            }
            if !Self.isEnglishWordText(text) { suppressesEnglishCompletions = false }
            return settle() + [.insert(text)]
        }
        // `v` numeric mode (bypasses Rime so digits/`.` build RMB uppercase candidates directly).
        if !vBuffer.isEmpty {
            if ChineseSpecialConversions.canAppendToVBuffer(vBuffer, text: text) {
                vBuffer += ChineseSpecialConversions.normalizedVCharacter(text)
                refreshVBufferCandidates()
                return []
            }
            let committed = commitVBuffer(lead: false)
            return committed + type(text)
        }
        if raw == "v", ChineseSpecialConversions.canAppendToVBuffer("v", text: text) {
            let edits = run(.clear)
            vBuffer = "v" + ChineseSpecialConversions.normalizedVCharacter(text)
            refreshVBufferCandidates()
            return edits
        }
        // A capital composes too, never as pinyin: it stays as typed (ChineseMixedInput).
        let pinyin = text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ($0 == "'" && isComposing)
        }
        guard pinyin, !text.isEmpty else { return insertLiteral(text) }
        let edits = spaceWaits ? commitWaitingSpace() : []
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
        spaceWaits = false
        if !vBuffer.isEmpty {
            vBuffer.removeLast()
            refreshVBufferCandidates()
            return []
        }
        if isComposing { enqueue(.backspace); return [] }
        let edits = settle()
        if isComposing { enqueue(.backspace); return edits }
        if commitIsForgettable, !english { enqueue(.backspace) }
        commitIsForgettable = false
        return edits + [.deleteBackward]
    }

    func space() -> [KeyboardEdit] {
        clearSuggestions()
        if !vBuffer.isEmpty { return commitVBuffer(lead: true) }
        if isComposing {
            // Space takes the first candidate of the final list.
            if candidatesAreCurrent { return takeLead() }
            spaceWaits = true
            return []
        }
        commitIsForgettable = false
        suppressesEnglishCompletions = false
        return settle() + [.insert(" ")]
    }

    func enter() -> [KeyboardEdit] {
        clearSuggestions()
        spaceWaits = false
        if !vBuffer.isEmpty { return commitVBuffer(lead: false) }
        if isComposing, hasCapitals { return commitTyped() }
        if isComposing { enqueue(.commitInput); return [] }
        commitIsForgettable = false
        suppressesEnglishCompletions = false
        return settle() + [.returnKey]
    }

    func confirm() -> [KeyboardEdit] { confirmAll() }

    func confirmAll() -> [KeyboardEdit] {
        spaceWaits = false
        if !vBuffer.isEmpty { return commitVBuffer(lead: false) }
        return isComposing ? run(.commitComposition) : settle()
    }

    func dismissSuggestions() { clearSuggestions() }

    func insertLiteral(_ text: String) -> [KeyboardEdit] {
        let edits = confirmAll()
        clearSuggestions()
        commitIsForgettable = false
        suppressesEnglishCompletions = false
        return edits + [.insert(text)]
    }

    func chooseCandidate(_ token: CandidateSelectionToken) -> [KeyboardEdit] {
        if token.kind == .suggestion { return chooseSuggestion(token) }
        guard token.sessionID == sessionID, token.generation == generation, token.kind == .composition,
              candidatesAreCurrent, isComposing, slots.indices.contains(token.index) else { return [] }
        switch slots[token.index] {
        case .phrase(let index): return choosePhrase(index)
        case .mixed(let index): return chooseMixed(index)
        case .correction(let index): return chooseCorrection(index)
        case .special(let index): return chooseSpecial(index)
        case .rime(let index): enqueue(.select(index))
        }
        return []
    }

    /// Commits the first candidate shown, which the model may have moved;
    /// with capitals and no reading keeping them, the letters as typed.
    private func takeLead() -> [KeyboardEdit] {
        spaceWaits = false
        switch slots.first {
        case .phrase(let index)?: return choosePhrase(index)
        case .mixed(let index)?: return chooseMixed(index)
        case .correction(let index)?: return chooseCorrection(index)
        case .special(let index)?: return chooseSpecial(index)
        case _ where hasCapitals: return commitTyped()
        case .rime(let index)? where index != 0: enqueue(.select(index))
        default: enqueue(.space)
        }
        return []
    }

    /// The Space still waiting when the next key comes: the list of the
    /// latest result is made at once, without the model, and its first commits.
    private func commitWaitingSpace() -> [KeyboardEdit] {
        spaceWaits = false
        let edits = settle()
        guard isComposing else { return edits }
        if let round { finishRound(round, scores: nil) }
        return edits + takeLead()
    }

    /// The Space that waited for the final list.
    private func finishPendingSpace() {
        guard spaceWaits, candidatesAreCurrent else { return }
        guard isComposing else { spaceWaits = false; return }
        let edits = takeLead()
        if !edits.isEmpty { onCommittedEdits?(KeyboardCommitBatch(hostEpoch: hostEpoch, edits: edits)) }
        onCandidatesChange?()
    }

    func activateEnglish() -> [KeyboardEdit] {
        guard !english else { return [] }
        let edits = confirmAll()
        clearSuggestions()
        english = true
        suppressesEnglishCompletions = false
        hostEpoch += 1
        return edits
    }

    func toggleEnglish() -> [KeyboardEdit] {
        spaceWaits = false
        if !english {
            clearSuggestions()
            english = true
            suppressesEnglishCompletions = false
            if !isComposing { hostEpoch += 1 }
            return []
        }
        english = false
        suppressesEnglishCompletions = false
        let edits = isComposing ? commitTyped() : []
        hostEpoch += 1
        return edits
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
        else { settleRound(); ChineseCandidateRanking.release() }
    }

    func retryLanguageModel(requestID: String) {
        guard usesModel, JapaneseCandidateWorker.LanguageModelStorage.shared.retry(requestID: requestID) else { return }
        onCandidatesChange?()
    }

    func handleMemoryPressure() {
        settleRound()
        JapaneseCandidateWorker.LanguageModelStorage.shared.setSuspended(true)
        ChineseCandidateRanking.release()
    }

    /// The reranking model, the sentence scoring package and the score cache.
    func releaseLanguageModels() {
        settleRound()
        ChineseCandidateRanking.release()
    }

    /// The model stays loaded while hidden, as Japanese's does, but its cached
    /// prefix KV is dropped so it does not linger in memory.
    func releaseInactiveResources() {
        settleRound()
        ChineseCandidateRanking.forgetPrefix()
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

    func setSpecialConversionFormats(date: ChineseSpecialConversions.DateFormat, time: ChineseSpecialConversions.TimeFormat) {
        specialDateFormat = date
        specialTimeFormat = time
    }

    func setExpandedCandidates(_ enabled: Bool) {
        guard enabled != expanded else { return }
        expanded = enabled
        if enabled { enqueue(.setCandidateLimit(Self.expandedCandidateLimit)) }
    }

    func reset(preservingContext: Bool) {
        if !preservingContext { hostEpoch += 1; suppressesEnglishCompletions = false }
        era += 1
        echo = ""
        vBuffer = ""
        specials = []
        spaceWaits = false
        leadingPick = nil
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
        dropLate()
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
        dropLate()
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
        finishPendingSpace()
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
                if !english {
                    ChinesePersonalRankingCache.shared.record(
                        prevText: leftContextProvider?() ?? "",
                        committed: commit,
                        exclusionsActive: exclusionsActive,
                        exclusionList: exclusions
                    )
                }
            }
            latest = result
        }
        if let latest { publish(latest) }
        return edits
    }

    private func publish(_ next: RimeState) {
        state = next
        let letters = Self.letters(next.input + echo)
        if cased.count > letters.count { cased = String(cased.prefix(letters.count)) }
        if cased.lowercased() != letters { cased = letters }
        if openKey != correctionInput, openKey != sentenceInput { clearCorrections() }
        // Later results are on their way: the list waits for the last.
        if received != sent, next.isComposing {
            if let round { round.cancel(); self.round = nil; roundKey = nil }
            return
        }
        let key = RoundKey(candidates: next.candidates, mixed: mixedKey)
        guard key != roundKey else { return }
        startRound(next, key: key)
    }

    /// What a list is made from: Rime's candidates, and the open input as
    /// typed (case included) with the text chosen before it.
    private struct RoundKey: Equatable {
        let candidates: [RimeCandidate]
        let mixed: String
    }

    /// One result's candidates on their way to the list. Every source comes
    /// in before the list shows, once: Rime's candidates, the readings that
    /// keep typed words (looked up in Rime), and the model's scores of both
    /// in one call. Until then the previous list stays, not to be chosen.
    /// When the model misses the window the list shows without it, and its
    /// scores, if they come within `lateWindow` and before any other key,
    /// reorder that list once (`refine`), as other keyboards refine theirs.
    private final class Round {
        let candidates: [RimeCandidate]
        let run: Range<Int>
        let rimeOrder: [Int]
        let slots: ChineseCandidateRanking.Slots
        let splits: [[ChineseMixedInput.Segment]]
        let context: String
        let scores: Bool
        /// How much of what the last key's first sentence settled each
        /// sentence keeps.
        let kept: [Int: Double]
        /// The model's part may run past the window, to refine the list
        /// late (`late`); the lookup has no deadline.
        let model = ChineseCandidateRanking.Request(
            deadline: ProcessInfo.processInfo.systemUptime + ChineseCandidateRanking.lateWindow)
        let lookup = ChineseCandidateRanking.Request(deadline: .infinity)
        /// Nil until looked up.
        var options: [ChineseMixedInput.Option]?
        var missedWindow = false
        let startedAt = ProcessInfo.processInfo.systemUptime
        init(candidates: [RimeCandidate], run: Range<Int>, rimeOrder: [Int], slots: ChineseCandidateRanking.Slots,
             splits: [[ChineseMixedInput.Segment]], context: String, scores: Bool, kept: [Int: Double]) {
            (self.candidates, self.run, self.rimeOrder, self.slots) = (candidates, run, rimeOrder, slots)
            (self.splits, self.context, self.scores, self.kept) = (splits, context, scores, kept)
        }
        func cancel() { model.cancel(); lookup.cancel() }
    }

    /// The first sentence shown and the input it was shown for.
    private var shownSentence: (input: String, text: String)?

    /// How much of what the shown first sentence settled (all of it but its
    /// last character, the syllable being typed) each of Rime's sentences
    /// keeps, when this input only adds to the one it was shown for.
    private func kept(_ next: RimeState, run: Range<Int>) -> [Int: Double] {
        guard let shown = shownSentence, next.input.count > shown.input.count, next.input.hasPrefix(shown.input)
        else { return [:] }
        return ChineseCandidateRanking.kept(shown.text.dropLast(), by: next.candidates, run: run)
    }

    private func startRound(_ next: RimeState, key: RoundKey) {
        round?.cancel()
        round = nil
        dropLate()
        roundKey = key
        let active = exclusionsActive, list = exclusions
        let run = ChineseCandidateRanking.sentenceRun(next.candidates)
        let rimeOrder = ChineseCandidateRanking.order(count: next.candidates.count, sentences: run)
        let slots = usesModel ? ChineseCandidateRanking.slots(next.candidates, sentenceLimit: sentenceLimit) {
            LearningExclusionPolicy.allowsLearning($0, active: active, list: list)
        } : ChineseCandidateRanking.Slots()
        let splits = next.isComposing ? casedUnchosen.map { ChineseMixedInput.splits(for: $0.rest) } ?? [] : []
        let context = modelContext
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        let warm = usesModel && storage.isReady(for: .chinese) && !storage.isSuspended
        if slots.canReorder {
            KeyboardPerformance.record(.candidateModelEligible, since: KeyboardPerformance.start())
            // A cold model loads for later compositions; this one shows at once.
            if usesModel, !warm {
                ChineseCandidateRanking.warmUp()
            }
        }
        guard !splits.isEmpty || (warm && slots.canReorder) else {
            mixed = []
            mixedPlacement = .none
            return show(next.candidates, order: rimeOrder)
        }
        let round = Round(candidates: next.candidates, run: run, rimeOrder: rimeOrder, slots: slots,
                          splits: splits, context: context, scores: warm, kept: kept(next, run: run))
        self.round = round
        rankingStartedAt = KeyboardPerformance.start()
        if warm {
            DispatchQueue.main.asyncAfter(deadline: .now() + rankingWindow) { [weak self] in
                guard let self, self.round === round else { return }
                round.missedWindow = true
                // Still looking up: the list shows once the readings are in.
                if round.options != nil { self.finishRound(round, scores: nil) }
            }
        }
        guard !splits.isEmpty else {
            round.options = []
            return scoreRound(round)
        }
        let rime = Set(next.candidates.map(\.genuine))
        engine.lookUp(ChineseMixedInput.spellings(for: splits), limit: 4,
                      isCancelled: { round.lookup.isCancelled }) { [weak self] converted in
            MainActor.assumeIsolated {
                guard let self, self.round === round else { return }
                round.options = ChineseMixedInput.options(splits, converted: converted).filter {
                    !rime.contains($0.genuine) && !self.blocklist.matches($0.genuine)
                }
                if round.scores, !round.missedWindow { return self.scoreRound(round) }
                self.finishRound(round, scores: nil)
                // Too late for the window: the model may still refine the list.
                if self.late?.round === round { self.scoreRound(round) }
            }
        }
    }

    /// Scores Rime's candidates the model may reorder and the readings
    /// keeping typed words together, so they compare.
    private func scoreRound(_ round: Round) {
        let texts = round.slots.all.map { round.candidates[$0].genuine } + (round.options ?? []).map(\.genuine)
        guard round.scores, texts.count > 1 else { return finishRound(round, scores: nil) }
        ChineseCandidateRanking.score(texts, context: round.context, request: round.model) { [weak self] scores in
            guard let self else { return }
            if self.round === round, !round.missedWindow { return self.finishRound(round, scores: scores) }
            guard let late = self.late, late.round === round else { return }
            self.late = nil
            guard let scores else {
                // Not even late: weigh fewer sentences next time.
                self.weighedSentences = max(ChineseCandidateRanking.fewestSentences, self.weighedSentences / 2)
                return
            }
            guard late.sent == self.sent, self.received == self.sent, self.round == nil, self.echo.isEmpty,
                  self.isComposing else { return }
            self.refine(round, scores: scores)
        }
    }

    /// Stops a late refinement: a key or command came first.
    private func dropLate() {
        late?.round.cancel()
        late = nil
    }

    /// Makes the list of a round still on its way at once, without the model
    /// and without readings not yet looked up.
    private func settleRound() {
        guard let round else { return }
        if round.options == nil { round.options = [] }
        finishRound(round, scores: nil)
    }

    /// Sentences the model weighs next: all of Rime's, halved each time it
    /// missed its window and doubled again when twice as many would have
    /// come in time; half while memory runs low.
    private var sentenceLimit: Int {
        let limit = os_proc_available_memory() < Self.fullSentenceMemory ? weighedSentences / 2 : weighedSentences
        return max(ChineseCandidateRanking.fewestSentences, limit)
    }
    private var weighedSentences = ChineseCandidateRanking.sentenceLimit
    /// Memory left to the process below which fewer sentences are weighed.
    static let fullSentenceMemory = 48 * 1_048_576

    /// Shows a round's list: `scores` (for Rime's slots, then the readings)
    /// when the model came in time, else the order without it.
    private func finishRound(_ round: Round, scores: [Double]?) {
        guard self.round === round else { return }
        self.round = nil
        // Shown without the model in time: its scores may still come late.
        let goesLate = scores == nil && round.missedWindow && round.scores && !round.model.isCancelled
            && round.slots.all.count + (round.options?.count ?? 0) > 1
        if goesLate {
            round.lookup.cancel()
            late = (round, sent)
        } else {
            round.cancel()
        }
        KeyboardPerformance.record(.chineseRankingWait, since: rankingStartedAt)
        rankingStartedAt = nil
        let elapsed = ProcessInfo.processInfo.systemUptime - round.startedAt
        let weighed = round.slots.sentences.count
        if round.missedWindow, !goesLate {
            weighedSentences = max(ChineseCandidateRanking.fewestSentences, weighedSentences / 2)
        } else if scores != nil, weighed >= weighedSentences, elapsed < ChineseCandidateRanking.window * 0.4 {
            // Twice as many would still have come in time.
            weighedSentences = min(ChineseCandidateRanking.sentenceLimit, weighedSentences * 2)
        }
        let order: [Int]
        (order, mixedPlacement, mixed) = arrange(round, scores: scores)
        show(round.candidates, order: order)
        if received == sent { announceCandidates() }
        finishPendingSpace()
    }

    /// A round's display order and readings, with the model's `scores`
    /// (for Rime's slots, then the readings) or without them.
    private func arrange(_ round: Round, scores: [Double]?)
        -> (order: [Int], placement: ChineseCandidateList.MixedPlacement, mixed: [ChineseMixedInput.Option]) {
        let options = round.options ?? []
        let count = round.slots.all.count
        let scores = scores.flatMap { $0.count == count + options.count && $0.allSatisfy(\.isFinite) ? $0 : nil }
        let rimeScores = scores.map { Array($0.prefix(count)) }
        let mixedScores = scores.map { Array($0.dropFirst(count)) }
        let order = rimeScores.map {
            ChineseCandidateRanking.order(count: round.candidates.count, sentences: round.run, slots: round.slots, scores: $0,
                                          kept: round.kept)
        } ?? round.rimeOrder
        if scores != nil {
            KeyboardPerformance.record(.candidateModelUsed, since: KeyboardPerformance.start())
            if order != round.rimeOrder { KeyboardPerformance.record(.candidateModelOrderChanged, since: KeyboardPerformance.start()) }
        }
        let lead = order.first
        let rival = lead.flatMap { lead in round.slots.all.firstIndex(of: lead).flatMap { rimeScores?[$0] } }
        let placement = ChineseCandidateList.placement(
            readings: options.count, capitals: hasCapitals,
            rimeShort: lead.map { !round.candidates[$0].coversInput } ?? true,
            best: mixedScores?.max(), rival: rival)
        let mixed = Array(ChineseMixedInput.ranked(options, scores: mixedScores)
            .prefix(placement == .overRime ? 1 : ChineseMixedInput.shownOptions))
        return (order, placement, mixed)
    }

    /// The model's scores for a list shown without them, come late: the list
    /// takes their order once, when they change it. A sentence correction
    /// weighed against the old first sentence is weighed again.
    private func refine(_ round: Round, scores: [Double]) {
        let (order, placement, mixed) = arrange(round, scores: scores)
        guard order != self.order || placement != mixedPlacement || mixed.map(\.genuine) != self.mixed.map(\.genuine)
        else { return }
        if order.first != self.order.first {
            sentenceRequest?.cancel()
            sentenceRequest = nil
            sentenceCorrection = nil
            sentenceLeads = false
            sentenceInput = ""
            collectCorrections()
        }
        (mixedPlacement, self.mixed) = (placement, mixed)
        show(round.candidates, order: order)
        onCandidatesChange?()
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
        shownSentence = order.first.flatMap { candidates[$0].sentence ? (state.input, candidates[$0].genuine) : nil }
        phrases = userPhrases()
        specials = specialConversionCandidates()
        let slots = ChineseCandidateList.slots(
            rime: candidates.map(\.text), order: order, corrections: corrections.map(\.candidate.text),
            correctionLeads: correctionLeads, mixed: mixed.count, placement: mixedPlacement,
            phrases: phrases.map(\.text), specials: specials.map(\.text))
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
            case .special(let source):
                let item = specials[source]
                return CandidatePresentation(text: item.text, source: .specialConversion, consumedInputCount: 0,
                    correction: nil, selectionToken: token, detailAnnotation: item.annotation)
            }
        }
        scheduleCorrections()
        scheduleSentenceCorrection()
    }

    // MARK: The open input

    /// The text chosen from the start of the composition, and the input left
    /// after it, which every source reads; the chosen text goes out in front
    /// of whatever is chosen for the rest.
    private var open: (chosen: String, input: String) {
        guard let (chosen, rest) = Self.unchosen(state), !chosen.isEmpty else { return ("", state.input) }
        return (chosen, rest)
    }

    private var openKey: String {
        let (chosen, input) = open
        return chosen + "\u{0}" + input
    }

    /// The sentence before the caret, with the text chosen so far.
    private var modelContext: String {
        VimeLanguageModel.sentenceContext((leftContextProvider?() ?? "") + open.chosen)
    }

    /// Commits `text` (for the open input) after the chosen text, in place
    /// of the composition; Rime learns nothing from it.
    private func commitInstead(_ text: String) -> [KeyboardEdit] {
        let chosen = open.chosen
        let edits = run(.clear)
        clearSuggestions()
        commitIsForgettable = false
        return edits + [.insert(chosen + text)]
    }

    // MARK: User phrases

    /// Phrases for the whole open input.
    private func userPhrases() -> [ChineseUserPhrase] {
        guard !hasCapitals else { return [] }
        let input = open.input
        let letters = input.lowercased().filter { ("a"..."z").contains($0) }
        guard !letters.isEmpty, letters.count == input.filter({ $0 != "'" }).count else { return [] }
        var combined = userDictionary.phrases(spelledBy: letters)
        var seen = Set(combined.map(\.text))
        for text in ChineseSystemLexicon.matches(for: letters) where seen.insert(text).inserted {
            combined.append(ChineseUserPhrase(pinyin: letters, text: text))
        }
        return combined
    }

    private func choosePhrase(_ index: Int) -> [KeyboardEdit] {
        guard phrases.indices.contains(index) else { return [] }
        return commitInstead(phrases[index].text)
    }

    // MARK: Special conversions (date/time/weekday/lunar/RMB)

    private func specialConversionCandidates() -> [ChineseSpecialConversions.Candidate] {
        guard !hasCapitals else { return [] }
        let options = ChineseSpecialConversions.Options(
            dateFormat: specialDateFormat,
            timeFormat: specialTimeFormat,
            traditional: traditional
        )
        return ChineseSpecialConversions.candidates(for: open.input, now: specialConversionsNow(), options: options)
    }

    private func chooseSpecial(_ index: Int) -> [KeyboardEdit] {
        guard specials.indices.contains(index) else { return [] }
        let text = specials[index].text
        if !vBuffer.isEmpty {
            vBuffer = ""
            specials = []
            slots = []
            presentations = []
            generation += 1
            commitIsForgettable = false
            return [.insert(text)]
        }
        return commitInstead(text)
    }

    private func refreshVBufferCandidates() {
        generation += 1
        if vBuffer.isEmpty {
            specials = []
            slots = []
            presentations = []
            return
        }
        specials = ChineseSpecialConversions.vModeCandidates(for: vBuffer, traditional: traditional)
        slots = specials.indices.map(ChineseCandidateList.Slot.special)
        presentations = specials.enumerated().map { index, item in
            let token = CandidateSelectionToken(sessionID: sessionID, generation: generation, index: index, kind: .composition)
            return CandidatePresentation(text: item.text, source: .specialConversion, consumedInputCount: 0,
                correction: nil, selectionToken: token, detailAnnotation: item.annotation)
        }
    }

    private func commitVBuffer(lead: Bool) -> [KeyboardEdit] {
        let text: String
        if lead, let first = specials.first {
            text = first.text
        } else {
            let digits = String(vBuffer.dropFirst())
            text = digits.isEmpty ? vBuffer : digits
        }
        vBuffer = ""
        specials = []
        slots = []
        presentations = []
        generation += 1
        commitIsForgettable = false
        return [.insert(text)]
    }

    // MARK: Letters no pinyin takes

    private func chooseMixed(_ index: Int) -> [KeyboardEdit] {
        guard mixed.indices.contains(index) else { return [] }
        return commitInstead(mixed[index].text)
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

    /// Text chosen from the start of the input (为什么这 of wsm|zhegeshurufavime)
    /// and the letters after it, which Rime's preedit spells with spaces.
    /// Nil unless those letters are what the input ends with.
    static func unchosen(_ state: RimeState) -> (chosen: String, rest: String)? {
        let chosen = String(state.preedit.prefix { !$0.isASCII || !($0.isLetter || $0 == " " || $0 == "'") })
        let rest = String(state.preedit.dropFirst(chosen.count).filter { ("a"..."z").contains($0) })
        guard !rest.isEmpty, state.input.filter({ $0 != "'" }).hasSuffix(rest) else { return nil }
        return (chosen, rest)
    }

    // MARK: Leading syllable

    /// The open input before a syllable was picked, Rime's first syllable
    /// for it, and the input the pick made; kept while that input stands.
    private var leadingPick: (original: String, natural: String?, picked: String)?

    /// The input the syllable column reads: from before a pick while it stands.
    private var leadingBase: (input: String, natural: String?) {
        if let leadingPick, leadingPick.picked == state.input, Self.unchosen(state)?.chosen.isEmpty != false {
            return (leadingPick.original, leadingPick.natural)
        }
        return (open.input, currentLeadingSyllable)
    }

    /// The input's own readings of its start, then other spellings of the
    /// one in use (fuzzy sounds, neighbouring keys) as corrections.
    private var leadingColumn: (exact: [String], corrections: [String], anchor: String?) {
        guard isComposing, echo.isEmpty, !hasCapitals else { return ([], [], nil) }
        let base = leadingBase
        // A single option still shows, so the column stays put while the
        // input is chosen piece by piece.
        let exact = PinyinLeadingSyllable.options(for: Self.letters(base.input))
        guard let anchor = base.natural.flatMap({ exact.contains($0) ? $0 : nil }) ?? exact.first else { return ([], [], nil) }
        return (exact, PinyinLeadingSyllable.alternatives(to: anchor, excluding: Set(exact)), anchor)
    }

    var leadingSyllables: [String] {
        let column = leadingColumn
        return column.exact + column.corrections
    }

    var correctedLeadingSyllables: Set<String> { Set(leadingColumn.corrections) }

    var currentLeadingSyllable: String? {
        guard isComposing else { return nil }
        let chosen = Self.unchosen(state)?.chosen ?? ""
        return PinyinLeadingSyllable.first(ofPreedit: String(state.preedit.dropFirst(chosen.count)))
    }

    /// Reads the open input as starting with `syllable`, so the list shows
    /// what starts with it; a correction respells the syllable in use.
    /// Text chosen before it is committed first, since Rime takes a new input
    /// whole; Rime's own reading restores the input.
    func chooseLeadingSyllable(_ syllable: String) -> [KeyboardEdit] {
        let column = leadingColumn
        guard candidatesAreCurrent, let anchor = column.anchor,
              column.exact.contains(syllable) || column.corrections.contains(syllable) else { return [] }
        let base = leadingBase
        let input = syllable == base.natural ? base.input
            : column.exact.contains(syllable) ? PinyinLeadingSyllable.input(base.input, leadingWith: syllable)
            : PinyinLeadingSyllable.input(base.input, replacing: anchor.count, with: syllable)
        let chosen = open.chosen
        leadingPick = input == base.input ? nil : (base.input, base.natural, input)
        guard !chosen.isEmpty else {
            if input != state.input { enqueue(.setInput(input)) }
            return []
        }
        // The new input goes in before returning, so the keyboard sees the
        // composition go on and keeps the panel open.
        let edits = run(.clear) + [.insert(chosen)]
        clearSuggestions()
        commitIsForgettable = false
        return edits + run(.setInput(input))
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

    /// A correction is for the open input: with nothing chosen Rime takes
    /// its spelling and learns it; after a chosen start both go out together.
    private func chooseCorrection(_ index: Int) -> [KeyboardEdit] {
        guard corrections.indices.contains(index) else { return [] }
        let (spelling, candidate) = corrections[index]
        guard open.chosen.isEmpty else { return commitInstead(candidate.text) }
        enqueue(.selectSpelling(input: spelling, text: candidate.genuine))
        return []
    }

    /// After a short pause, looks other spellings of the open input up when
    /// Rime reads it poorly; a key typed meanwhile cancels it.
    private func scheduleCorrections() {
        let input = open.input, key = openKey
        guard correctionInput != key, isComposing, echo.isEmpty, !hasCapitals,
              PinyinSpellingCorrection.wantsCorrection(input, top: state.candidates.first) else { return }
        let request = ChineseCandidateRanking.Request(deadline: .infinity)
        correctionRequest = request
        correctionInput = key
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.correctionDelay) { [weak self] in
            guard let self, self.correctionRequest === request, !request.isCancelled else { return }
            let spellings = PinyinSpellingCorrection.spellings(for: input)
            guard !spellings.isEmpty else { self.correctionRequest = nil; return }
            self.engine.lookUp(spellings, limit: 4, isCancelled: { request.isCancelled }) { [weak self] found in
                MainActor.assumeIsolated { self?.finishCorrections(found, key: key, request: request) }
            }
        }
    }

    private func finishCorrections(_ found: [(spelling: String, candidates: [RimeCandidate])], key: String,
                                   request: ChineseCandidateRanking.Request) {
        guard correctionRequest === request, !request.isCancelled, openKey == key else { return }
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
    /// They come after the list shows, so they go after its first unless the
    /// model clearly prefers the sentence correction.
    private func refreshCorrections() {
        collectCorrections()
        guard round == nil else { return }
        show(shownCandidates, order: order)
        if received == sent { onCandidatesChange?() }
    }

    private func collectCorrections() {
        var seen: Set<String> = []
        let all = (sentenceCorrection.map { [$0] } ?? []) + wordCorrections
        corrections = Array(all.filter { seen.insert($0.candidate.text).inserted }.prefix(Self.shownCorrections))
        correctionLeads = sentenceLeads && sentenceCorrection != nil
    }

    // MARK: Sentence correction

    /// After a short pause, scores the shown sentence token by token, looks
    /// up spellings one edit away around its weakest tokens, and weighs what
    /// Rime makes of them against it (ChineseSentenceCorrection). A key typed
    /// meanwhile cancels it.
    private func scheduleSentenceCorrection() {
        let input = open.input, key = openKey
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        guard sentenceInput != key, isComposing, echo.isEmpty, round == nil, usesModel, !hasCapitals,
              ChineseSentenceCorrection.isEnabled, ChineseSentenceCorrection.wants(input),
              storage.isReady(for: .chinese), !storage.isSuspended,
              let first = order.first, shownCandidates.indices.contains(first) else { return }
        let literal = shownCandidates[first]
        guard literal.coversInput, literal.genuine.unicodeScalars.contains(where: { $0.properties.isIdeographic })
        else { return }
        let request = ChineseCandidateRanking.Request(deadline: .infinity)
        sentenceRequest?.cancel()
        sentenceRequest = request
        sentenceInput = key
        let context = modelContext
        let text = literal.genuine
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.correctionDelay) { [weak self] in
            guard let self, self.sentenceRequest === request, !request.isCancelled else { return }
            JapaneseCandidateWorker.modelQueue.async {
                var found: (score: Double, spellings: [(spelling: String, edit: ChineseSentenceCorrection.Edit)])?
                if !request.isCancelled, !storage.isSuspended, let model = storage.chineseModel,
                   let lexicon = ChinesePinyinLexicon.bundled,
                   let tokens = try? model.tokenScores(context: context, text: text) {
                    let windows = ChineseSentenceCorrection.windows(tokens: tokens, text: text, input: input, lexicon: lexicon)
                    found = (tokens.reduce(0) { $0 + $1.logProbability },
                             ChineseSentenceCorrection.spellings(for: input, windows: windows))
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.lookUpSentenceSpellings(found, literal: text, key: key, context: context, request: request)
                    }
                }
            }
        }
    }

    private func lookUpSentenceSpellings(_ found: (score: Double, spellings: [(spelling: String, edit: ChineseSentenceCorrection.Edit)])?,
                                         literal: String, key: String, context: String,
                                         request: ChineseCandidateRanking.Request) {
        guard sentenceRequest === request, !request.isCancelled, openKey == key else { return }
        guard let found, !found.spellings.isEmpty else { sentenceRequest = nil; return }
        let edits = Dictionary(found.spellings.map { ($0.spelling, $0.edit) }, uniquingKeysWith: { first, _ in first })
        engine.lookUp(found.spellings.map(\.spelling), limit: ChineseSentenceCorrection.lookupLimit,
                      isCancelled: { request.isCancelled }) { [weak self] converted in
            MainActor.assumeIsolated {
                guard let self, self.sentenceRequest === request, !request.isCancelled, self.openKey == key else { return }
                let active = self.exclusionsActive, list = self.exclusions, blocklist = self.blocklist
                let options = ChineseSentenceCorrection.options(converted, edits: edits, literal: literal) {
                    LearningExclusionPolicy.allowsLearning($0, active: active, list: list) && !blocklist.matches($0)
                }
                guard !options.isEmpty else { self.sentenceRequest = nil; return }
                self.scoreSentenceOptions(options, literal: found.score, text: literal, context: context, key: key, request: request)
            }
        }
    }

    private func scoreSentenceOptions(_ options: [ChineseSentenceCorrection.Option], literal: Double, text: String, context: String,
                                      key: String, request: ChineseCandidateRanking.Request) {
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        JapaneseCandidateWorker.modelQueue.async { [weak self] in
            let stop = { request.isCancelled || storage.isSuspended }
            var scores: [Double]?
            if !stop(), let model = storage.chineseModel {
                scores = try? ChinesePrefixScoring.scores(
                    context: context, candidates: options.map(\.candidate.genuine),
                    model: model.batch, tokenizer: model.tokenizer, cancelled: stop)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.sentenceRequest === request, !request.isCancelled, self.openKey == key else { return }
                    self.sentenceRequest = nil
                    guard let scores,
                          let decision = ChineseSentenceCorrection.decide(literal: literal, text: text, options: options, scores: scores)
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
