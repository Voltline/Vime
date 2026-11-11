import Foundation

/// Reorders Rime's first complete conversions with the Chinese model.
///
/// Rime decides what the candidates are; the model only swaps places among
/// the first few, scoring each by its simplified text after the sentence
/// before the caret. Learned phrases, partial conversions and entries that
/// must not be suggested keep their places, so the model never promotes them.
nonisolated enum ChineseCandidateRanking {
    /// How many of Rime's first candidates the model may reorder.
    static let candidateLimit = 8
    /// The new list waits this long for the model, then shows Rime's order.
    static let window: TimeInterval = 0.060
    /// Rime's order is the prior: each place further down costs this much
    /// log probability, so the model needs clear evidence to move a word up.
    static let placePenalty = 1.0

    /// Indices the model may reorder among themselves.
    static func slots(_ candidates: [RimeCandidate], allows: (String) -> Bool) -> [Int] {
        var seen = Set<String>()
        return candidates.indices.prefix(candidateLimit).filter { index in
            let candidate = candidates[index]
            return candidate.coversInput && !candidate.userPhrase
                && candidate.genuine.unicodeScalars.contains { $0.properties.isIdeographic }
                && allows(candidate.genuine) && allows(candidate.text)
                && seen.insert(candidate.genuine).inserted
        }
    }

    /// Display order, as indices into the candidates: `scores` belong to
    /// `slots`, in order. Other candidates keep their places.
    static func order(count: Int, slots: [Int], scores: [Double]) -> [Int] {
        var order = Array(0..<count)
        guard slots.count == scores.count, slots.count > 1, scores.allSatisfy(\.isFinite) else { return order }
        let ranked = slots.indices.sorted { a, b in
            let left = scores[a] - placePenalty * Double(a), right = scores[b] - placePenalty * Double(b)
            return left != right ? left > right : a < b
        }
        for (place, slot) in zip(slots, ranked) { order[place] = slots[slot] }
        return order
    }

    /// One reordering request; cancelled when Rime's candidates change.
    final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        let deadline: TimeInterval
        init(deadline: TimeInterval) { self.deadline = deadline }
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled || ProcessInfo.processInfo.systemUptime >= deadline
        }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    /// Scores `texts` after `context` on the model queue and reports on the
    /// main queue: nil when the model is not ready in time. A cold model
    /// loads for later requests but never holds this one.
    static func score(_ texts: [String], context: String, request: Request,
                      completion: @escaping @MainActor ([Double]?) -> Void) {
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        let warm = storage.isReady(for: .chinese)
        JapaneseCandidateWorker.modelQueue.async {
            var scores: [Double]?
            if !request.isCancelled, !storage.isSuspended, let model = storage.model(for: .chinese), warm {
                let cache = ScoreCache.shared.cache(for: model)
                scores = try? model.scores(context: context, candidates: texts, conversionCache: cache,
                                           cancelled: { request.isCancelled || storage.isSuspended })
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(scores) } }
        }
    }

    /// Releases the Chinese model, for example when ranking is turned off.
    static func release() {
        JapaneseCandidateWorker.modelQueue.async {
            JapaneseCandidateWorker.LanguageModelStorage.shared.release(.chinese)
            ScoreCache.shared.clear()
        }
    }

    /// Prefix rows of recent scores, for the loaded model only. Model queue.
    private final class ScoreCache: @unchecked Sendable {
        static let shared = ScoreCache()
        private var owner: ObjectIdentifier?
        private var value = VimeLanguageModel.ConversionScoreCache()
        func cache(for model: VimeLanguageModel) -> VimeLanguageModel.ConversionScoreCache {
            dispatchPrecondition(condition: .onQueue(JapaneseCandidateWorker.modelQueue))
            if owner != ObjectIdentifier(model) {
                owner = ObjectIdentifier(model)
                value = VimeLanguageModel.ConversionScoreCache()
            }
            return value
        }
        func clear() {
            dispatchPrecondition(condition: .onQueue(JapaneseCandidateWorker.modelQueue))
            owner = nil
            value = VimeLanguageModel.ConversionScoreCache()
        }
    }
}
