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
        /// Commits the raw input, as Return does.
        case commitInput
        case setInput(String)
        case clear
    }

    static let candidateLimit = 60
    static var bundledData: URL? { Bundle.main.url(forResource: "RimeData", withExtension: "bundle") }

    private static let startLock = NSLock()
    nonisolated(unsafe) private static var startedUserDirectory: URL?

    private let queue = DispatchQueue(label: "com.Voltline.Vime.Rime", qos: .userInitiated)
    private let data: URL
    private let userDirectory: URL
    // Touched only on `queue`.
    private var session: VimeRimeSession = 0

    /// `userDirectory` holds the user dictionary. The first engine in a
    /// process decides it; Rime cannot switch directories while running.
    init(data: URL, userDirectory: URL) {
        self.data = data
        self.userDirectory = userDirectory
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

    /// Runs `command` and waits; for tests and tools, never the main thread
    /// of the keyboard.
    func sendAndWait(_ command: Command) -> RimeState {
        queue.sync { run(command) }
    }

    private func run(_ command: Command) -> RimeState {
        let clock = ContinuousClock()
        let start = clock.now
        guard prepare() else { return RimeState(duration: clock.now - start) }
        switch command {
        case .type(let text):
            for scalar in text.unicodeScalars where scalar.isASCII {
                _ = vime_rime_process_key(session, Int32(scalar.value), 0)
            }
        case .backspace: _ = vime_rime_process_key(session, 0xFF08, 0)
        case .select(let index): _ = vime_rime_select_candidate(session, index)
        case .commitInput: _ = vime_rime_process_key(session, 0xFF0D, 0)
        case .setInput(let input): _ = vime_rime_set_input(session, input)
        case .clear: vime_rime_clear(session)
        }
        var state = snapshot()
        state.duration = clock.now - start
        return state
    }

    private func prepare() -> Bool {
        if session != 0 { return true }
        guard Self.start(data: data, userDirectory: userDirectory) else { return false }
        session = vime_rime_create_session()
        return session != 0
    }

    private static func start(data: URL, userDirectory: URL) -> Bool {
        startLock.lock(); defer { startLock.unlock() }
        if startedUserDirectory != nil { return true }
        try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        guard vime_rime_start(data.path, userDirectory.path) else { return false }
        vime_rime_set_learning_filter { text in
            guard let text else { return true }
            return LearningExclusionPolicy.allowsLearning(String(cString: text), active: LearningExclusionPolicy.isActive())
        }
        startedUserDirectory = userDirectory
        return true
    }

    private func snapshot() -> RimeState {
        var raw = vime_rime_snapshot(session, Int32(Self.candidateLimit))
        defer { vime_rime_snapshot_free(&raw) }
        func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }
        let candidates = (0..<Int(raw.candidateCount)).map { index in
            let candidate = raw.candidates[index]
            return RimeCandidate(text: string(candidate.text) ?? "", comment: string(candidate.comment))
        }
        return RimeState(input: string(raw.input) ?? "", preedit: string(raw.preedit) ?? "",
                         commit: string(raw.commit), candidates: candidates)
    }
}
