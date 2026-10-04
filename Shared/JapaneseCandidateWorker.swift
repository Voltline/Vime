import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// The converter and its dictionary caches belong exclusively to this queue.
/// Cancellation skips superseded requests; a running request may finish but
/// the session revision prevents it from changing newer composition state.
@MainActor
final class JapaneseCandidateWorker {
    private nonisolated final class Storage: @unchecked Sendable {
        private var cachedEngine: JapaneseCandidateEngine?
        var engine: JapaneseCandidateEngine {
            if let cachedEngine { return cachedEngine }
            let engine = JapaneseCandidateEngine()
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
    private let storage = Storage()
    private var pending: Request?

    func candidates(for composing: ComposingText, katakana: Bool, revision: Int,
                    completion: @escaping @MainActor @Sendable ([CandidateSnapshot], TimeInterval?) -> Void) {
        pending?.cancel()
        let request = Request()
        pending = request
        let storage = self.storage
        let requestStartedAt = KeyboardPerformance.start()
        queue.async {
            guard !request.isCancelled else { return }
            let computeStartedAt = KeyboardPerformance.start()
            let values = storage.engine.candidates(for: composing, katakana: katakana, revision: revision)
            KeyboardPerformance.record(.candidateCompute, since: computeStartedAt)
            KeyboardPerformance.record(.candidateRequestToResult, since: requestStartedAt)
            let readyAt = KeyboardPerformance.start()
            guard !request.isCancelled else { return }
            DispatchQueue.main.async { completion(values, readyAt) }
        }
    }

    func complete(_ candidate: Candidate) {
        let storage = self.storage
        queue.async { storage.engine.complete(candidate) }
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    func reset() {
        cancelPending()
        let storage = self.storage
        queue.async { storage.engine.reset() }
    }

    deinit { pending?.cancel() }
}
