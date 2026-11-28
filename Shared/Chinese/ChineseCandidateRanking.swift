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
    /// Scores that come after the window but within this much of the key
    /// still reorder the list it showed, once; a later key cancels them.
    static let lateWindow: TimeInterval = 0.300
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
    /// What the last key's first sentence settled (all of it but the
    /// syllable being typed) resists change: a sentence keeping it
    /// gains up to this much, in proportion to how much of it it keeps, so
    /// the first sentence flips less between readings from key to key.
    static let keepBonus = 2.0
    /// When none of Rime's sentences keeps all the last key's first sentence
    /// settled, that settled text with the rest of the input converted after
    /// it competes too: it keeps all of it, and pays this much for not being
    /// Rime's reading.
    nonisolated(unsafe) static var stitchCost = 1.0

    /// The best value a sentence reaches in `order`: its score (with
    /// `personal`), less its place's cost, plus its share of `keepBonus`.
    static func bestSentenceValue(slots: Slots, scores: [Double], kept: [Int: Double],
                                  personal: [Int: Double]) -> Double? {
        guard scores.count == slots.all.count else { return nil }
        return slots.sentences.indices.map { place in
            let index = slots.sentences[place]
            return scores[place] + (personal[index] ?? 0) - sentencePlacePenalty * Double(place)
                + keepBonus * (kept[index] ?? 0)
        }.max()
    }

    /// Whether the stitched sentence, scored `stitched`, beats the best of
    /// Rime's sentences, `best`.
    static func stitchLeads(stitched: Double, best: Double) -> Bool {
        stitched.isFinite && stitched + keepBonus - stitchCost > best
    }

    /// How much of `settled` each of Rime's sentences keeps, as its share of
    /// `keepBonus`: the characters it shares from the start, of all of them.
    static func kept(_ settled: Substring, by candidates: [RimeCandidate], run: Range<Int>) -> [Int: Double] {
        guard !settled.isEmpty else { return [:] }
        var kept: [Int: Double] = [:]
        for index in run {
            let shared = zip(candidates[index].genuine, settled).prefix { $0 == $1 }.count
            if shared > 0 { kept[index] = Double(shared) / Double(settled.count) }
        }
        return kept
    }

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
    /// Learned `userPhrase` entries keep their places unless the user has
    /// explicitly given negative feedback (`penalized`).
    static func slots(_ candidates: [RimeCandidate], sentenceLimit: Int = sentenceLimit,
                      penalized: (String) -> Bool = { _ in false },
                      allows: (String) -> Bool) -> Slots {
        var seen = Set<String>()
        func eligible(_ index: Int) -> Bool {
            let candidate = candidates[index]
            return candidate.coversInput && (!candidate.userPhrase || penalized(candidate.text))
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

    /// Personal ranking adjustment (positive collocation bonus minus negative feedback penalty)
    /// from `ChinesePersonalRankingCache`, omitting neutral zero slots.
    static func personal(_ candidates: [RimeCandidate], slots: Slots, before prevText: String,
                         input: String = "",
                         cache: ChinesePersonalRankingCache = .shared) -> [Int: Double] {
        var adjustments: [Int: Double] = [:]
        for index in slots.all {
            let delta = cache.adjustment(prevText: prevText, input: input, candidate: candidates[index].text)
            if delta != 0 { adjustments[index] = delta }
        }
        return adjustments
    }

    /// Rime's order, with only its first sentence.
    static func order(count: Int, sentences: Range<Int>) -> [Int] {
        Array(sentences.prefix(1)) + Array(sentences.upperBound..<max(count, sentences.upperBound))
    }

    /// Display order, as indices into the candidates: `scores` belong to
    /// `slots.all`, in order. The best `shownSentences` of Rime's sentences
    /// lead; the best of them then competes with the other slots under
    /// `placePenalty`, and the other candidates keep their places. Sentences
    /// in `kept` gain their share (0...1) of `keepBonus`; candidates in
    /// `personal` add theirs (ChinesePersonalRankingCache.adjustment, in log
    /// probability) to the model's score.
    static func order(count: Int, sentences run: Range<Int>, slots: Slots, scores: [Double],
                      kept: [Int: Double] = [:], personal: [Int: Double] = [:]) -> [Int] {
        let fallback = order(count: count, sentences: run)
        let all = slots.all
        guard all.count == scores.count, all.count > 1, scores.allSatisfy(\.isFinite) else { return fallback }
        let score = Dictionary(uniqueKeysWithValues: zip(all, scores).map { ($0, $1 + (personal[$0] ?? 0)) })
        func ranked(_ indices: [Int], penalty: Double, bonus: [Int: Double] = [:]) -> [Int] {
            func value(_ place: Int) -> Double {
                score[indices[place]]! - penalty * Double(place) + keepBonus * (bonus[indices[place]] ?? 0)
            }
            return indices.indices.sorted { a, b in
                let left = value(a), right = value(b)
                return left != right ? left > right : a < b
            }.map { indices[$0] }
        }
        var order = fallback
        if slots.sentences.count > 1 {
            let best = ranked(slots.sentences, penalty: sentencePlacePenalty, bonus: kept).prefix(shownSentences)
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
            let cancelled = { request.isCancelled || storage.isSuspended }
            if !cancelled(), let model = storage.chineseModel, warm, !texts.isEmpty {
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let result = try model.scores(context: context, candidates: texts, cancelled: cancelled)
                    let elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    if result.count == texts.count, !result.isEmpty, result.allSatisfy(\.isFinite) {
                        scores = result
                        if model.version == .v2,
                           ChineseModelFallback.shared.recordKeyLatency(milliseconds: elapsedMS) {
                            storage.release(.chinese)
                            ChineseSentenceGeneration.Storage.shared.release()
                        }
                    } else if model.version == .v2 {
                        scores = fallbackScoreToV1(texts, context: context, reason: "invalid_scores",
                                                   storage: storage, cancelled: cancelled)
                    }
                } catch VimeLanguageModel.Failure.cancelled, VimeLanguageModel.Failure.ineligible {
                    scores = nil
                } catch {
                    if model.version == .v2 {
                        scores = fallbackScoreToV1(texts, context: context, reason: "runtime_error: \(error)",
                                                   storage: storage, cancelled: cancelled)
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(scores) } }
        }
    }

    private static func fallbackScoreToV1(
        _ texts: [String], context: String, reason: String,
        storage: JapaneseCandidateWorker.LanguageModelStorage, cancelled: () -> Bool
    ) -> [Double]? {
        ChineseModelFallback.shared.recordRuntimeFailure(reason: reason)
        storage.release(.chinese)
        ChineseSentenceGeneration.Storage.shared.release()
        guard !cancelled(), let v1 = storage.chineseModel, v1.version == .v1 else { return nil }
        return try? v1.scores(context: context, candidates: texts, cancelled: cancelled)
    }

    /// Warms up a cold Chinese model on the model queue for later requests.
    static func warmUp() {
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        guard !storage.isReady(for: .chinese), !storage.isSuspended else { return }
        JapaneseCandidateWorker.modelQueue.async {
            guard !storage.isSuspended else { return }
            _ = storage.chineseModel
        }
    }

    /// Releases the Chinese model, for example when ranking is turned off.
    static func release() {
        JapaneseCandidateWorker.modelQueue.async {
            JapaneseCandidateWorker.LanguageModelStorage.shared.release(.chinese)
            ChineseSentenceGeneration.Storage.shared.release()
        }
    }

    /// Drops the cached prefix KV and transient row buffers while keeping the model loaded.
    static func forgetPrefix() {
        JapaneseCandidateWorker.modelQueue.async {
            JapaneseCandidateWorker.LanguageModelStorage.shared.chineseModel?.batch.releaseTransientBuffers()
        }
    }
}
