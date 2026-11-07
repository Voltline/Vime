import CRime
import Foundation

nonisolated struct RimeCandidate: Sendable, Equatable {
    let text: String
    let comment: String?
}

/// What the engine shows after a command. `commit` is text for the host; the
/// engine hands it out once.
nonisolated struct RimeState: Sendable, Equatable {
    var input = ""
    var preedit = ""
    var commit: String?
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
    }

    static let candidateLimit = 60
    static var bundledData: URL? { Bundle.main.url(forResource: "RimeData", withExtension: "bundle") }

    private static let startLock = NSLock()
    nonisolated(unsafe) private static var startedUserDirectory: URL?
    /// Bumped when Rime restarts, which ends every session.
    nonisolated(unsafe) private static var startCount = 0

    private let queue = DispatchQueue(label: "com.Voltline.Vime.Rime", qos: .userInitiated)
    private let data: URL
    private let userDirectory: URL
    private let resetRequests: KeyboardLearningResetRequests
    // Touched only on `queue`.
    private var session: VimeRimeSession = 0
    private var sessionStart = 0
    private var limit = RimeEngine.candidateLimit
    /// Rime's index for each candidate the last state shows.
    private var shown: [Int] = []

    /// `userDirectory` holds the user dictionary. The first engine in a
    /// process decides it; Rime cannot switch directories while running.
    /// A pending request in `resetRequests` deletes what was learned there.
    init(data: URL, userDirectory: URL, resetRequests: KeyboardLearningResetRequests = KeyboardLearningResetRequests()) {
        self.data = data
        self.userDirectory = userDirectory
        self.resetRequests = resetRequests
    }

    deinit {
        let session = session
        if session != 0 { queue.async { vime_rime_destroy_session(session) } }
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
        return session != 0
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
        let reset = resetRequests?.pendingID(for: store)
        if startedUserDirectory != nil, reset == nil { return startCount }
        if let reset {
            if startedUserDirectory != nil {
                vime_rime_stop()
                startedUserDirectory = nil
            }
            // A failed deletion leaves the request for a later try.
            if deleteUserDictionaries(in: userDirectory) { resetRequests?.complete(reset, for: store) }
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
        var raw = vime_rime_snapshot(session, Int32(limit))
        defer { vime_rime_snapshot_free(&raw) }
        func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }
        let preedit = string(raw.preedit) ?? ""
        let syllables = Self.syllableCount(preedit)
        shown = []
        var candidates: [RimeCandidate] = []
        for index in 0..<Int(raw.candidateCount) {
            let candidate = raw.candidates[index]
            let text = string(candidate.text) ?? ""
            if candidate.completion, !Self.completionFits(text, syllables: syllables) { continue }
            shown.append(index)
            candidates.append(RimeCandidate(text: text, comment: string(candidate.comment)))
        }
        return RimeState(input: string(raw.input) ?? "", preedit: preedit,
                         commit: string(raw.commit), candidates: candidates)
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
