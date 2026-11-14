import Foundation

/// Reorders Rime's first complete conversions with the Chinese model.
///
/// Rime decides what the candidates are; the model only swaps places among
/// the first few, scoring each by its simplified text after the sentence
/// before the caret. Learned phrases, partial conversions and entries that
/// must not be suggested keep their places, so the model never promotes them.
///
/// For an input no dictionary entry covers, Rime makes several sentences,
/// first in its list. The model weighs all of them and the best few show;
/// without the model only Rime's first shows, as before.
nonisolated enum ChineseCandidateRanking {
    /// How many of Rime's first candidates the model may reorder.
    static let candidateLimit = 8
    /// The new list waits this long for the model, then shows Rime's order.
    static let window: TimeInterval = 0.060
    /// Rime's order is the prior: each place further down costs this much
    /// log probability, so the model needs clear evidence to move a word up.
    static let placePenalty = 1.0
    /// Rime's sentences the model weighs (the schema's max_sentences).
    static let sentenceLimit = 16
    /// Short of time, the model weighs half as many sentences, down to this.
    static let fewestSentences = 4
    /// Rime's sentences differ in a word or two, where its order says little,
    /// so each place further down costs only this much.
    static let sentencePlacePenalty = 0.1
    /// Sentences shown once the model has ordered them.
    static let shownSentences = 3

    /// What the model scores: Rime's sentences, then the other candidates it
    /// may reorder, all as indices into the candidates.
    struct Slots: Equatable {
        var sentences: [Int] = []
        var others: [Int] = []
        var all: [Int] { sentences + others }
        /// Whether the model has anything to reorder.
        var canReorder: Bool { sentences.count + others.count > 1 }
    }

    /// Rime's sentences lead its list; all but the first wait for the model.
    static func sentenceRun(_ candidates: [RimeCandidate]) -> Range<Int> {
        0..<(candidates.firstIndex { !$0.sentence } ?? candidates.count)
    }

    /// The candidates the model may reorder: up to `sentenceLimit` of
    /// Rime's sentences, and the others among the first `candidateLimit`
    /// shown when only Rime's first sentence counts.
    static func slots(_ candidates: [RimeCandidate], sentenceLimit: Int = sentenceLimit,
                      allows: (String) -> Bool) -> Slots {
        var seen = Set<String>()
        func eligible(_ index: Int) -> Bool {
            let candidate = candidates[index]
            return candidate.coversInput && !candidate.userPhrase
                && candidate.genuine.unicodeScalars.contains { $0.properties.isIdeographic }
                && allows(candidate.genuine) && allows(candidate.text)
                && seen.insert(candidate.genuine).inserted
        }
        let run = sentenceRun(candidates)
        var slots = Slots()
        // A first sentence the model may not move keeps the others out too.
        if !run.isEmpty, eligible(run.lowerBound) {
            slots.sentences = [run.lowerBound] + run.dropFirst().prefix(max(0, sentenceLimit - 1)).filter(eligible)
        }
        let shown = (run.isEmpty ? [] : [run.lowerBound]) + candidates.indices.dropFirst(run.count)
        slots.others = shown.prefix(candidateLimit).filter { !run.contains($0) && eligible($0) }
        return slots
    }

    /// Rime's order, with only its first sentence.
    static func order(count: Int, sentences: Range<Int>) -> [Int] {
        Array(sentences.prefix(1)) + Array(sentences.upperBound..<max(count, sentences.upperBound))
    }

    /// Display order, as indices into the candidates: `scores` belong to
    /// `slots.all`, in order. The best `shownSentences` of Rime's sentences
    /// lead; the best of them then competes with the other slots under
    /// `placePenalty`, and the other candidates keep their places.
    static func order(count: Int, sentences run: Range<Int>, slots: Slots, scores: [Double]) -> [Int] {
        let fallback = order(count: count, sentences: run)
        let all = slots.all
        guard all.count == scores.count, all.count > 1, scores.allSatisfy(\.isFinite) else { return fallback }
        let score = Dictionary(uniqueKeysWithValues: zip(all, scores))
        func ranked(_ indices: [Int], penalty: Double) -> [Int] {
            indices.indices.sorted { a, b in
                let left = score[indices[a]]! - penalty * Double(a), right = score[indices[b]]! - penalty * Double(b)
                return left != right ? left > right : a < b
            }.map { indices[$0] }
        }
        var order = fallback
        if slots.sentences.count > 1 {
            let best = ranked(slots.sentences, penalty: sentencePlacePenalty).prefix(shownSentences)
            order = Array(best) + Array(run.upperBound..<max(count, run.upperBound))
        }
        let places = order.indices.filter { place in
            place == 0 && slots.sentences.contains(order[0]) || slots.others.contains(order[place])
        }
        guard places.count > 1 else { return order }
        for (place, index) in zip(places, ranked(places.map { order[$0] }, penalty: placePenalty)) { order[place] = index }
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
