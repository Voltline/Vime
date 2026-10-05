import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// The converter and its dictionary caches belong exclusively to this queue.
/// Cancellation skips superseded requests; a running request may finish but
/// the session revision prevents it from changing newer composition state.
@MainActor
final class JapaneseCandidateWorker {
    private nonisolated final class Storage: @unchecked Sendable {
        private var cachedEngine: JapaneseCandidateEngine?
        let memoryDirectoryURL: URL?
        init(memoryDirectoryURL: URL?) { self.memoryDirectoryURL = memoryDirectoryURL }
        var engine: JapaneseCandidateEngine {
            if let cachedEngine { return cachedEngine }
            let engine = JapaneseCandidateEngine(memoryDirectoryURL: memoryDirectoryURL, learningEnabled: true)
            cachedEngine = engine
            return engine
        }
    }
    private nonisolated final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private let queue = DispatchQueue(label: "com.Voltline.Vime.candidates", qos: .userInitiated)
    private let storage: Storage
    init(memoryDirectoryURL: URL? = nil) { storage = Storage(memoryDirectoryURL: memoryDirectoryURL) }
    private var pending: Request?

    func candidates(for composing: ComposingText, katakana: Bool, revision: Int, leftContext: String?, continuity: CandidateContinuity?,
                    completion: @escaping @MainActor @Sendable ([CandidateSnapshot], TimeInterval?, Bool) -> Void) {
        pending?.cancel()
        let request = Request()
        pending = request
        let storage = self.storage
        let queue = self.queue
        let requestStartedAt = KeyboardPerformance.start()
        queue.async {
            guard !request.isCancelled else { return }
            storage.engine.reconcileContext(leftContext)
            storage.engine.seedContinuity(continuity)
            let computeStartedAt = KeyboardPerformance.start()
            let values = storage.engine.candidates(for: composing, katakana: katakana, revision: revision, includeCorrections: false)
            KeyboardPerformance.record(.candidateCompute, since: computeStartedAt)
            KeyboardPerformance.record(.candidateRequestToResult, since: requestStartedAt)
            let readyAt = KeyboardPerformance.start()
            guard !request.isCancelled else { return }
            DispatchQueue.main.async { completion(values, readyAt, false) }
            // Normal prediction is delivered first. New input cancels this
            // supplementary search before it starts; running search checks every query.
            queue.async {
                guard !request.isCancelled else { return }
                let correctionStartedAt = KeyboardPerformance.start()
                let expanded = storage.engine.addingCorrections(to: values, for: composing, katakana: katakana,
                    revision: revision, cancelled: { request.isCancelled })
                KeyboardPerformance.record(.correctionCompute, since: correctionStartedAt)
                guard !request.isCancelled, expanded.map(\.presentation) != values.map(\.presentation) else { return }
                KeyboardPerformance.record(.correctionRequestToResult, since: requestStartedAt)
                let readyAt = KeyboardPerformance.start()
                DispatchQueue.main.async { completion(expanded, readyAt, true) }
            }
        }
    }

    func complete(_ candidate: CandidateSnapshot) {
        let storage = self.storage
        let queue = self.queue
        queue.async {
            storage.engine.complete(candidate)
            // Persistence occurs on confirmation boundaries, never on keystrokes.
            queue.async { storage.engine.flushLearning() }
        }
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    func reset(preservingContext: Bool = false) {
        cancelPending()
        let storage = self.storage
        queue.async { storage.engine.reset(preservingContext: preservingContext); storage.engine.flushLearning() }
    }

    func clearLearning() {
        cancelPending()
        let storage = self.storage
        queue.async { storage.engine.clearLearning() }
    }

    deinit {
        pending?.cancel()
        let storage = self.storage
        queue.async { storage.engine.flushLearning() }
    }
}
