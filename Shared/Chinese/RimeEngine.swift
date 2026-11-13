import CRime
import Foundation

nonisolated struct RimeCandidate: Sendable, Equatable {
    let text: String
    let comment: String?
    /// The text before the simplifier: simplified even while traditional
    /// characters show.
    var genuine: String
    /// Converts the whole input, not only its first syllables.
    var coversInput = true
    /// Learned from earlier input.
    var userPhrase = false
    /// Several dictionary words joined, not one entry.
    var sentence = false
    /// Rime's ranking score; higher is likelier.
    var quality = 0.0

    init(text: String, comment: String?, genuine: String? = nil, coversInput: Bool = true, userPhrase: Bool = false,
         sentence: Bool = false, quality: Double = 0) {
        self.text = text
        self.comment = comment
        self.genuine = genuine ?? text
        self.coversInput = coversInput
        self.userPhrase = userPhrase
        self.sentence = sentence
        self.quality = quality
    }
}

/// A dictionary word that the text so far begins: `text` is what follows.
nonisolated struct RimeContinuation: Sendable, Equatable {
    let text: String
    /// Simplified, as the dictionary has it.
    let genuine: String
    /// Rime's syllable code for `genuine`, to continue from it in turn.
    let code: String
}

/// What the engine shows after a command. `commit` is text for the host; the
/// engine hands it out once.
nonisolated struct RimeState: Sendable, Equatable {
    var input = ""
    var preedit = ""
    var commit: String?
    /// The last dictionary word of `commit` (simplified) and its syllable
    /// code, when the commit ended with one.
    var commitWord: String?
    var commitCode: String?
    var candidates: [RimeCandidate] = []
    /// Time the engine spent on the command, including a cold start.
    var duration: Duration = .zero

    var isComposing: Bool { !input.isEmpty }
}

/// librime for Chinese input. Rime keeps state, so every command runs on one
/// serial queue in the order it was sent; none is skipped for a newer one.
/// One engine owns one Rime session; Rime itself starts once per process.
nonisolated final class RimeEngine: @unchecked Sendable {
    enum Command: Sendable, Equatable {
        /// Letters, an apostrophe as a syllable break.
        case type(String)
        case backspace
        /// Index into the whole candidate list.
        case select(Int)
        /// Selects the highlighted candidate, as Space does.
        case space
        /// Commits the raw input, as Return does.
        case commitInput
        /// Commits the whole composition with its current selections.
        case commitComposition
        case setInput(String)
        case clear
        /// Ends Rime's learning transaction, so it is written now and a later
        /// BackSpace cannot take it back.
        case finishLearning
        /// How many candidates later states carry.
        case setCandidateLimit(Int)
        /// Traditional characters through the schema's simplifier; an open
        /// composition is looked up again so its candidates follow.
        case setTraditional(Bool)
        /// Fuzzy pinyin, through the schema built for these groups; an open
        /// composition is looked up again.
        case setFuzzy(FuzzyPinyin)
        /// Replaces the input with `input` and selects its candidate whose
        /// simplified text is `text`; nothing changes when there is none.
        case selectSpelling(input: String, text: String)
        /// Commits `text` for the whole input, choosing Rime's words for it
        /// from the left so Rime learns them; `text` is simplified and must
        /// read as the input. When Rime has no such words, `text` is committed
        /// as it is.
        case selectText(String)
    }

    static let candidateLimit = 60
    static var bundledData: URL? { Bundle.main.url(forResource: "RimeData", withExtension: "bundle") }

    private static let startLock = NSLock()
    nonisolated(unsafe) private static var startedUserDirectory: URL?
    /// Bumped when Rime restarts, which ends every session.
    nonisolated(unsafe) private static var startCount = 0

    /// Shared by every engine: Rime's sessions live in one process-wide table,
    /// so an old engine destroying its session must not race a new one.
    private static let queue = DispatchQueue(label: "com.Voltline.Vime.Rime", qos: .userInitiated)
    private var queue: DispatchQueue { Self.queue }
    private let data: URL
    private let userDirectory: URL
    private let resetRequests: KeyboardLearningResetRequests
    // Touched only on `queue`.
    private var session: VimeRimeSession = 0
    private var sessionStart = 0
    private var limit = RimeEngine.candidateLimit
    /// Set again on every new session, which starts with options off.
    private var traditional = false
    /// Selected again on every new session, which starts with vime_pinyin.
    private var fuzzy = FuzzyPinyin()
    /// Rime's index for each candidate the last state shows.
    private var shown: [Int] = []
    /// A second session for looking up other spellings, so the one being
    /// typed keeps its composition and selections.
    private var lookupSession: VimeRimeSession = 0
    private var lookupStart = 0
    /// The lookup session's schema and simplifier option, set when they change.
    private var lookupOptions: (schema: String, traditional: Bool)?

    /// `userDirectory` holds the user dictionary. The first engine in a
    /// process decides it; Rime cannot switch directories while running.
    /// A pending request in `resetRequests`, or in its `chinese` requests,
    /// deletes what was learned there.
    init(data: URL, userDirectory: URL, resetRequests: KeyboardLearningResetRequests = KeyboardLearningResetRequests()) {
        self.data = data
        self.userDirectory = userDirectory
        self.resetRequests = resetRequests
    }

    deinit {
        let sessions = [session, lookupSession].filter { $0 != 0 }
        if !sessions.isEmpty { queue.async { sessions.forEach(vime_rime_destroy_session) } }
    }

    /// Runs `command` after every command sent before it and reports the
    /// state on the main queue.
    func send(_ command: Command, completion: @escaping @Sendable (RimeState) -> Void) {
        queue.async { [self] in
            let state = run(command)
            DispatchQueue.main.async { completion(state) }
        }
    }

    /// Runs `command` after every command sent before it and hands the state
    /// to `deliver` on the engine's queue, in command order.
    func submit(_ command: Command, deliver: @escaping @Sendable (RimeState) -> Void) {
        queue.async { [self] in deliver(run(command)) }
    }

    /// Runs `command` after every command sent before it and waits.
    func sendAndWait(_ command: Command) -> RimeState {
        queue.sync { run(command) }
    }

    /// Dictionary words beginning with `word` read as `code` (from a state or
    /// an earlier continuation), likeliest first; handed to `deliver` on the
    /// main queue after every command sent before.
    func continuations(of word: String, code: String, limit: Int,
                       deliver: @escaping @Sendable ([RimeContinuation]) -> Void) {
        queue.async { [self] in
            let found = continuations(word, code: code, limit: limit)
            DispatchQueue.main.async { deliver(found) }
        }
    }

    func continuationsAndWait(of word: String, code: String, limit: Int) -> [RimeContinuation] {
        queue.sync { continuations(word, code: code, limit: limit) }
    }

    private func continuations(_ word: String, code: String, limit: Int) -> [RimeContinuation] {
        guard prepare(checkingReset: false) else { return [] }
        var raw = vime_rime_continuations(session, word, code, Int32(limit), traditional)
        defer { vime_rime_continuations_free(&raw) }
        return (0..<Int(raw.count)).map { index in
            let item = raw.items[index]
            return RimeContinuation(text: String(cString: item.text), genuine: String(cString: item.genuine),
                                    code: String(cString: item.code))
        }
    }

    /// Looks each spelling up in a second session and hands its candidates to
    /// `deliver` on the main queue. One spelling runs per turn on the queue,
    /// so keys sent meanwhile wait for at most one lookup; once `isCancelled`
    /// returns true the rest are skipped and nothing is delivered.
    func lookUp(_ spellings: [String], limit: Int, isCancelled: @escaping @Sendable () -> Bool,
                deliver: @escaping @Sendable ([(spelling: String, candidates: [RimeCandidate])]) -> Void) {
        @Sendable func step(_ index: Int, _ found: [(spelling: String, candidates: [RimeCandidate])]) {
            queue.async { [self] in
                guard !isCancelled() else { return }
                guard index < spellings.count else {
                    if lookupSession != 0 { vime_rime_clear(lookupSession) }
                    DispatchQueue.main.async { deliver(found) }
                    return
                }
                step(index + 1, found + [(spellings[index], lookUp(spellings[index], limit: limit))])
            }
        }
        step(0, [])
    }

    /// Looks each spelling up in the second session and waits.
    func lookUpAndWait(_ spellings: [String], limit: Int) -> [[RimeCandidate]] {
        queue.sync {
            defer { if lookupSession != 0 { vime_rime_clear(lookupSession) } }
            return spellings.map { lookUp($0, limit: limit) }
        }
    }

    private func lookUp(_ spelling: String, limit: Int) -> [RimeCandidate] {
        guard prepare(checkingReset: false) else { return [] }
        if lookupSession == 0 || lookupStart != sessionStart {
            lookupSession = vime_rime_create_session()
            lookupStart = sessionStart
            lookupOptions = nil
            guard lookupSession != 0 else { return [] }
        }
        // Follows the typing session's schema and options.
        if lookupOptions?.schema != fuzzy.schema || lookupOptions?.traditional != traditional {
            if !vime_rime_select_schema(lookupSession, fuzzy.schema) { _ = vime_rime_select_schema(lookupSession, "vime_pinyin") }
            vime_rime_set_option(lookupSession, "traditionalization", traditional)
            lookupOptions = (fuzzy.schema, traditional)
        }
        _ = vime_rime_set_input(lookupSession, spelling)
        let (state, _) = Self.snapshot(lookupSession, limit: limit)
        return state.candidates
    }

    private func run(_ command: Command) -> RimeState {
        let clock = ContinuousClock()
        let start = clock.now
        // The keyboard clears on every show, a cheap moment to look for a reset.
        guard prepare(checkingReset: command == .clear) else { return RimeState(duration: clock.now - start) }
        switch command {
        case .type(let text):
            for scalar in text.unicodeScalars where scalar.isASCII {
                _ = vime_rime_process_key(session, Int32(scalar.value), 0)
            }
        case .backspace: _ = vime_rime_process_key(session, 0xFF08, 0)
        case .select(let index):
            if shown.indices.contains(index) { _ = vime_rime_select_candidate(session, shown[index]) }
        case .space:
            // A hidden first candidate is not what Space should take.
            if let first = shown.first, first != 0, vime_rime_is_composing(session) {
                _ = vime_rime_select_candidate(session, first)
            } else {
                _ = vime_rime_process_key(session, 0x20, 0)
            }
        case .commitInput: _ = vime_rime_process_key(session, 0xFF0D, 0)
        case .commitComposition: _ = vime_rime_commit_composition(session)
        case .setInput(let input): _ = vime_rime_set_input(session, input)
        case .clear: vime_rime_clear(session)
        case .finishLearning:
            // Escape outside a composition is unhandled, which closes the transaction.
            if !vime_rime_is_composing(session) { _ = vime_rime_process_key(session, 0xFF1B, 0) }
        case .setCandidateLimit(let value): limit = max(1, value)
        case .setTraditional(let value):
            traditional = value
            vime_rime_set_option(session, "traditionalization", value)
            lookUpAgain(currentInput())
        case .selectText(let text):
            var rest = Substring(text)
            while !rest.isEmpty, vime_rime_is_composing(session) {
                let candidates = snapshot().candidates
                // The whole rest at once, else the longest word it begins with.
                let found = candidates.firstIndex { $0.coversInput && $0.genuine == rest }
                    ?? candidates.indices.filter { !candidates[$0].coversInput && rest.hasPrefix(candidates[$0].genuine)
                        && !candidates[$0].genuine.isEmpty }
                        .max { candidates[$0].genuine.count < candidates[$1].genuine.count }
                guard let found else { break }
                _ = vime_rime_select_candidate(session, shown[found])
                rest = rest.dropFirst(candidates[found].genuine.count)
            }
            if vime_rime_is_composing(session) || !rest.isEmpty {
                vime_rime_clear(session)
                var state = snapshot()
                state.commit = text
                state.duration = clock.now - start
                return state
            }
        case .selectSpelling(let input, let text):
            let original = currentInput()
            _ = vime_rime_set_input(session, input)
            let found = snapshot().candidates.firstIndex { $0.genuine == text && $0.coversInput }
            if let found { _ = vime_rime_select_candidate(session, shown[found]) }
            else if let original { _ = vime_rime_set_input(session, original) }
        case .setFuzzy(let value):
            guard value != fuzzy else { break }
            let input = currentInput()
            fuzzy = value
            // A new schema starts with options off and nothing typed.
            selectSchema()
            lookUpAgain(input)
        }
        var state = snapshot()
        state.duration = clock.now - start
        return state
    }

    private func prepare(checkingReset: Bool) -> Bool {
        if session != 0, !checkingReset, sessionStart == Self.currentStart { return true }
        guard let started = Self.start(data: data, userDirectory: userDirectory,
                                       resetRequests: session == 0 || checkingReset ? resetRequests : nil) else { return false }
        if session != 0, sessionStart == started { return true }
        session = vime_rime_create_session()
        sessionStart = started
        if session != 0 { selectSchema() }
        return session != 0
    }

    private func selectSchema() {
        // A missing fuzzy schema (older data) leaves the plain one.
        if !fuzzy.isEmpty, !vime_rime_select_schema(session, fuzzy.schema) { fuzzy = [] }
        if fuzzy.isEmpty { _ = vime_rime_select_schema(session, FuzzyPinyin().schema) }
        vime_rime_set_option(session, "traditionalization", traditional)
    }

    private func currentInput() -> String? {
        guard vime_rime_is_composing(session) else { return nil }
        var raw = vime_rime_snapshot(session, 0)
        defer { vime_rime_snapshot_free(&raw) }
        return raw.input.map { String(cString: $0) }
    }

    private func lookUpAgain(_ input: String?) {
        if let input { _ = vime_rime_set_input(session, input) }
    }

    private static var currentStart: Int {
        startLock.lock(); defer { startLock.unlock() }
        return startCount
    }

    /// Starts Rime unless it runs, first carrying out a pending reset of the
    /// user dictionary. Returns the start the sessions belong to.
    private static func start(data: URL, userDirectory: URL, resetRequests: KeyboardLearningResetRequests?) -> Int? {
        startLock.lock(); defer { startLock.unlock() }
        let store = "rime." + userDirectory.lastPathComponent
        // A reset of every language or of Chinese alone.
        let resets = [resetRequests, resetRequests?.chinese].compactMap { requests in
            requests.flatMap { requests in requests.pendingID(for: store).map { (requests, $0) } }
        }
        if startedUserDirectory != nil, resets.isEmpty { return startCount }
        if !resets.isEmpty {
            if startedUserDirectory != nil {
                vime_rime_stop()
                startedUserDirectory = nil
            }
            // A failed deletion leaves the requests for a later try.
            if deleteUserDictionaries(in: userDirectory) {
                for (requests, id) in resets { requests.complete(id, for: store) }
            }
        }
        try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        guard vime_rime_start(data.path, userDirectory.path) else { return nil }
        vime_rime_set_learning_filter { text in
            guard let text else { return true }
            return LearningExclusionPolicy.allowsLearning(String(cString: text), active: LearningExclusionPolicy.isActive())
        }
        startedUserDirectory = userDirectory
        startCount += 1
        return startCount
    }

    private static func deleteUserDictionaries(in directory: URL) -> Bool {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: directory.path) else { return true }
        var deleted = true
        for name in names where name.hasSuffix(".userdb") || name.hasSuffix(".userdb.txt") {
            do { try files.removeItem(at: directory.appendingPathComponent(name)) } catch { deleted = false }
        }
        return deleted
    }

    private func snapshot() -> RimeState {
        let (state, shown) = Self.snapshot(session, limit: limit)
        self.shown = shown
        return state
    }

    /// The session's state and Rime's index for each candidate it shows.
    private static func snapshot(_ session: VimeRimeSession, limit: Int) -> (RimeState, [Int]) {
        var raw = vime_rime_snapshot(session, Int32(limit))
        defer { vime_rime_snapshot_free(&raw) }
        func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }
        let preedit = string(raw.preedit) ?? ""
        let syllables = syllableCount(preedit)
        var shown: [Int] = []
        var candidates: [RimeCandidate] = []
        for index in 0..<Int(raw.candidateCount) {
            let candidate = raw.candidates[index]
            let text = string(candidate.text) ?? ""
            if candidate.completion, !completionFits(text, syllables: syllables) { continue }
            shown.append(index)
            candidates.append(RimeCandidate(text: text, comment: string(candidate.comment), genuine: string(candidate.genuine),
                                            coversInput: candidate.coversInput, userPhrase: candidate.userPhrase,
                                            sentence: candidate.sentence, quality: candidate.quality))
        }
        return (RimeState(input: string(raw.input) ?? "", preedit: preedit, commit: string(raw.commit),
                          commitWord: string(raw.commitWord), commitCode: string(raw.commitCode),
                          candidates: candidates), shown)
    }

    /// Syllables still being typed: Rime separates them with spaces, and text
    /// already chosen has no letters.
    static func syllableCount(_ preedit: String) -> Int {
        preedit.split(whereSeparator: { $0 == " " || $0 == "'" })
            .filter { $0.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) } }.count
    }

    /// Completion may add up to two characters to the syllables typed. Longer
    /// phrases sharing only the first letters are seldom what was meant.
    static func completionFits(_ text: String, syllables: Int) -> Bool {
        guard syllables > 0 else { return true }
        let hanzi = text.unicodeScalars.filter { $0.properties.isIdeographic }.count
        return hanzi <= syllables + 2
    }
}
