import Foundation
import os
import KanaKanjiConverterModuleWithDefaultDictionary

/// Converter state stays on candidateQueue; the shared model and tokenizer stay
/// on modelQueue. Only immutable request snapshots cross between the two.
@MainActor
final class JapaneseCandidateWorker {
    static var isLanguageModelSuspendedForMemoryPressure: Bool { LanguageModelStorage.shared.isSuspended }
    // Neural ranking can participate before the first display, but never hold
    // dictionary candidates behind a cold model or a long scoring request.
    nonisolated static let initialRankingWindow: TimeInterval = 0.040
    nonisolated static let initialRankingCandidateLimit = 8

    nonisolated struct ResourceState: Equatable, Sendable {
        let engineLoaded: Bool
        let modelLoaded: Bool
        let modelSuspendedForMemoryPressure: Bool
        let modelLoadCount: Int
    }
    nonisolated static let candidateQueue = DispatchQueue(
        label: "com.Voltline.Vime.candidates", qos: .userInitiated, autoreleaseFrequency: .workItem)
    /// Shared by every worker: one model, with serialized Core ML/tokenizer use.
    /// Internal visibility also allows deterministic queue-isolation tests.
    nonisolated static let modelQueue = DispatchQueue(
        label: "com.Voltline.Vime.languageModel", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private nonisolated final class LanguageModelStorage: @unchecked Sendable {
        static let shared = LanguageModelStorage()
        // Readiness and the pressure gate cross queues; model access remains
        // confined to modelQueue. Never wait for cold initialization to publish.
        private let lock = NSLock()
        private var suspended = false
        private var ready = false
        var isSuspended: Bool { lock.lock(); defer { lock.unlock() }; return suspended }
        var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready && !suspended }
        func setSuspended(_ value: Bool) { lock.lock(); suspended = value; lock.unlock() }
        private func setReady(_ value: Bool) { lock.lock(); ready = value; lock.unlock() }
        private var cachedModel: VimeLanguageModel?
        private var attempted = false
        private var loadCount = 0
        func release() {
            dispatchPrecondition(condition: .onQueue(JapaneseCandidateWorker.modelQueue))
            setReady(false)
            cachedModel = nil; attempted = false
        }
        func resourceState(engineLoaded: Bool) -> ResourceState {
            dispatchPrecondition(condition: .onQueue(JapaneseCandidateWorker.modelQueue))
            return ResourceState(engineLoaded: engineLoaded, modelLoaded: cachedModel != nil,
                modelSuspendedForMemoryPressure: isSuspended, modelLoadCount: loadCount)
        }
        var model: VimeLanguageModel? {
            dispatchPrecondition(condition: .onQueue(JapaneseCandidateWorker.modelQueue))
            guard !isSuspended else { return nil }
            if !attempted {
                attempted = true
                let log = Logger(subsystem: "com.Voltline.Vime", category: "LanguageModel")
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let model = try autoreleasepool { try VimeLanguageModel() }
                    loadCount += 1
                    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    VimeExtensionAudit.recordModelLoad(version: model.modelVersion, milliseconds: milliseconds)
                    log.notice("Model \(model.modelVersion, privacy: .public) loaded in \(milliseconds) ms; footprint \(VimeLanguageModel.footprintMB()) MB")
                    // A warning received during synchronous loading must not
                    // publish the new model or start its first prediction.
                    guard !isSuspended else { return nil }
                    cachedModel = model
                    setReady(true)
                } catch {
                    log.error("Model unavailable (\(String(describing: error), privacy: .public)); retaining dictionary candidates.")
                }
            }
            return isSuspended ? nil : cachedModel
        }
    }
    private nonisolated final class Storage: @unchecked Sendable {
        private var cachedEngine: JapaneseCandidateEngine?
        var engineLoaded: Bool { cachedEngine != nil }
        func handleMemoryPressure() {
            cachedEngine?.discardTransientCaches()
        }
        func releaseInactiveResources() {
            // Persist before dropping the converter, dictionary and every
            // session lattice, even if UIKit keeps the hidden controller alive.
            resetCachedEngine(preservingContext: false)
            cachedEngine = nil
        }
        let memoryDirectoryURL: URL?
        init(memoryDirectoryURL: URL?) { self.memoryDirectoryURL = memoryDirectoryURL }
        var engine: JapaneseCandidateEngine {
            if let cachedEngine { return cachedEngine }
            let engine = JapaneseCandidateEngine(memoryDirectoryURL: memoryDirectoryURL, learningEnabled: true)
            cachedEngine = engine
            return engine
        }
        // Reset/teardown of an unused keyboard must not initialize dictionaries
        // or learning storage merely to clear/flush an empty session.
        func resetCachedEngine(preservingContext: Bool) {
            cachedEngine?.reset(preservingContext: preservingContext)
            flushCachedLearning()
        }
        func flushCachedLearning() { cachedEngine?.flushLearning() }
    }
    /// Captured across pipeline hops, but only read or mutated on modelQueue.
    /// The converter queue personalizes scored values, never the mutable cache.
    private nonisolated final class SuggestionScoring: @unchecked Sendable {
        private let scoreCache = VimeLanguageModel.SuggestionScoreCache()
        var cache: VimeLanguageModel.SuggestionScoreCache {
            dispatchPrecondition(condition: .onQueue(JapaneseCandidateWorker.modelQueue))
            return scoreCache
        }
    }
    private nonisolated final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var initiallyPublished = false
        private var refinement: [CandidateSnapshot]?
        private let startedAt: TimeInterval?
        init(startedAt: TimeInterval? = nil) { self.startedAt = startedAt }
        func cancel() {
            lock.lock()
            let unpublished = !cancelled && !initiallyPublished
            cancelled = true; refinement = nil
            lock.unlock()
            if unpublished { KeyboardPerformance.record(.candidateRequestCancelled, since: startedAt) }
        }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func refine(_ values: [CandidateSnapshot], before deadline: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled, !initiallyPublished, ProcessInfo.processInfo.systemUptime < deadline else { return }
            refinement = values
        }
        func claimInitialPublication(fallback: [CandidateSnapshot]) -> [CandidateSnapshot]? {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled, !initiallyPublished else { return nil }
            initiallyPublished = true
            defer { refinement = nil }
            return refinement ?? fallback
        }
    }
    // Drain Foundation/Core ML temporaries at every request, including cancelled
    // work, instead of relying on the long-lived queue's inherited pool policy
    private let queue = JapaneseCandidateWorker.candidateQueue
    private let storage: Storage
    init(memoryDirectoryURL: URL? = nil) { storage = Storage(memoryDirectoryURL: memoryDirectoryURL) }
    private var pending: Request?
    private var preparation: Request?

    /// Called only when a keyboard becomes visible. Hidden/unused controllers
    /// keep no converter, and queued preparation is cancelled during teardown.
    func prepareForInput() {
        guard preparation == nil else { return }
        let request = Request()
        preparation = request
        let storage = self.storage
        queue.async {
            guard !request.isCancelled, !storage.engineLoaded else { return }
            let engine = storage.engine
            guard !request.isCancelled else { return }
            engine.prepareForInput()
        }
    }

    private func cancelPreparation() {
        preparation?.cancel()
        preparation = nil
    }

    func candidates(for composing: ComposingText, katakana: Bool, revision: Int, leftContext: String?, continuity: CandidateContinuity?,
                    ranking: CandidateRankingMode = .languageModel, conversionLength: Int? = nil, expanded: Bool = false,
                    completion: @escaping @MainActor @Sendable ([CandidateSnapshot], TimeInterval?, Bool) -> Void) {
        pending?.cancel()
        // The budget includes queueing, context reconciliation and dictionary
        // work, even when performance instrumentation is disabled.
        let initialDeadline = ProcessInfo.processInfo.systemUptime + Self.initialRankingWindow
        let requestStartedAt = KeyboardPerformance.start()
        let request = Request(startedAt: requestStartedAt)
        pending = request
        let storage = self.storage
        let queue = self.queue
        queue.async {
            KeyboardPerformance.record(.candidateQueueWait, since: requestStartedAt)
            guard !request.isCancelled else { return }
            storage.engine.reconcileContext(leftContext)
            guard !request.isCancelled else { return }
            storage.engine.seedContinuity(continuity)
            let computeStartedAt = KeyboardPerformance.start()
            let values = storage.engine.candidates(for: composing, katakana: katakana, revision: revision,
                includeCorrections: false, conversionLength: conversionLength, cancelled: { request.isCancelled })
            KeyboardPerformance.record(.candidateCompute, since: computeStartedAt)
            KeyboardPerformance.record(.candidateRequestToResult, since: requestStartedAt)
            let readyAt = KeyboardPerformance.start()
            guard !request.isCancelled else { return }
            let sentence = VimeLanguageModel.sentenceContext(leftContext ?? "")
            // Sentence-initial ranking currently adds a publication window
            // for little measured gain. Keep native/personal evidence there.
            let neuralRanking = ranking == .languageModel && !sentence.isEmpty && !LanguageModelStorage.shared.isSuspended
                && CandidateCompetitionPolicy.plan(values, katakana: katakana, maximumCandidates: Self.initialRankingCandidateLimit).slots.count > 1
            let waitForRanking = neuralRanking && LanguageModelStorage.shared.isReady
                && ProcessInfo.processInfo.systemUptime < initialDeadline
            // Both the timer and model completion enter this gate on MainActor.
            // Supplementary work starts only after the initial publication, so
            // fast corrections cannot arrive too early and be discarded.
            let publishInitial: @MainActor @Sendable (TimeInterval?) -> Void = { resultReadyAt in
                guard let result = request.claimInitialPublication(fallback: values) else { return }
                completion(result, resultReadyAt, false)
                let supplementaryQueuedAt = KeyboardPerformance.start()
                queue.async {
                    KeyboardPerformance.record(.supplementaryQueueWait, since: supplementaryQueuedAt)
                    guard !request.isCancelled else { return }
                    let formatted = expanded
                        ? storage.engine.addingWidthCandidates(to: values, for: composing, katakana: katakana,
                            revision: revision, conversionLength: conversionLength, cancelled: { request.isCancelled }) : values
                    let enriched = expanded && conversionLength == nil
                        ? storage.engine.addingPrefixCandidates(to: formatted, for: composing, katakana: katakana,
                            revision: revision, cancelled: { request.isCancelled }) : formatted
                    guard !request.isCancelled else { return }
                    // Publish prefix/format choices separately from the slower
                    // correction search, retaining their native consumption payloads.
                    if enriched.map(\.presentation) != values.map(\.presentation) {
                        let readyAt = KeyboardPerformance.start()
                        DispatchQueue.main.async { if !request.isCancelled { completion(enriched, readyAt, true) } }
                    }
                    guard conversionLength == nil else { return }
                    let correctionStartedAt = KeyboardPerformance.start()
                    let corrected = storage.engine.addingCorrections(to: enriched, for: composing, katakana: katakana,
                        revision: revision, cancelled: { request.isCancelled })
                    KeyboardPerformance.record(.correctionCompute, since: correctionStartedAt)
                    guard !request.isCancelled, corrected.map(\.presentation) != enriched.map(\.presentation) else { return }
                    KeyboardPerformance.record(.correctionRequestToResult, since: requestStartedAt)
                    let readyAt = KeyboardPerformance.start()
                    DispatchQueue.main.async { if !request.isCancelled { completion(corrected, readyAt, true) } }
                }
            }
            if waitForRanking {
                let remaining = max(0, initialDeadline - ProcessInfo.processInfo.systemUptime)
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { publishInitial(readyAt) }
            } else {
                DispatchQueue.main.async { publishInitial(readyAt) }
            }
            if neuralRanking {
                let modelQueuedAt = KeyboardPerformance.start()
                Self.modelQueue.async {
                    KeyboardPerformance.record(.modelQueueWait, since: modelQueuedAt)
                    guard !request.isCancelled, !LanguageModelStorage.shared.isSuspended else { return }
                    // Cold work warms later requests while this one's dictionary
                    // list is already visible. Expired warm work never predicts.
                    if LanguageModelStorage.shared.isReady,
                       !waitForRanking || ProcessInfo.processInfo.systemUptime >= initialDeadline { return }
                    let model = LanguageModelStorage.shared.model
                    guard waitForRanking, !request.isCancelled,
                          ProcessInfo.processInfo.systemUptime < initialDeadline else { return }
                    _ = model?.rerank(values, context: sentence,
                        katakana: katakana, maximumCandidates: Self.initialRankingCandidateLimit, onRefinement: {
                            request.refine($0, before: initialDeadline)
                        }, cancelled: {
                            request.isCancelled || LanguageModelStorage.shared.isSuspended
                                || ProcessInfo.processInfo.systemUptime >= initialDeadline
                        }) ?? values
                    let rankedReadyAt = KeyboardPerformance.start()
                    DispatchQueue.main.async { publishInitial(rankedReadyAt) }
                }
            }
        }
    }

    /// Native-first prediction. Model generation/scoring uses its own queue;
    /// personalization returns to the converter queue without blocking either.
    func suggestions(prompt: String, leftContext: String, useLanguageModel: Bool,
                     completion: @escaping @MainActor @Sendable ([NextWordSuggestion]) -> Void) {
        pending?.cancel()
        let request = Request()
        pending = request
        let storage = self.storage
        queue.async {
            guard !request.isCancelled else { return }
            let native = storage.engine.postCompositionSuggestions(leftContext: leftContext)
            guard !request.isCancelled else { return }
            let base = PostCompositionSuggestionReranker.merge(native: native, neural: [])
            if !base.isEmpty {
                DispatchQueue.main.async { if !request.isCancelled { completion(base) } }
            }
            guard useLanguageModel, !request.isCancelled else { return }
            let history = storage.engine.rememberedNextWords(context: prompt)
            let modelQueuedAt = KeyboardPerformance.start()
            Self.modelQueue.async {
                KeyboardPerformance.record(.modelQueueWait, since: modelQueuedAt)
                guard !request.isCancelled, !LanguageModelStorage.shared.isSuspended else { return }
                let scoring = SuggestionScoring()
                let words = try? LanguageModelStorage.shared.model?.scoredNextWords(prompt: prompt, history: history, cache: scoring.cache,
                    cancelled: { request.isCancelled || LanguageModelStorage.shared.isSuspended })
                guard !request.isCancelled, !LanguageModelStorage.shared.isSuspended else { return }
                Self.candidateQueue.async {
                    guard !request.isCancelled, !LanguageModelStorage.shared.isSuspended else { return }
                    let neural = storage.engine.personalizedNextWords(words?.generated ?? [], history: words?.history ?? [], context: prompt)
                    let pool = PostCompositionSuggestionReranker.merge(native: native, neural: neural)
                    let rankingQueuedAt = KeyboardPerformance.start()
                    Self.modelQueue.async {
                        KeyboardPerformance.record(.modelQueueWait, since: rankingQueuedAt)
                        guard !request.isCancelled, !LanguageModelStorage.shared.isSuspended else { return }
                        let suggestions = LanguageModelStorage.shared.model?.rerankPostComposition(pool, prompt: prompt, cache: scoring.cache,
                            cancelled: { request.isCancelled || LanguageModelStorage.shared.isSuspended }) ?? pool
                        guard !request.isCancelled, !suggestions.isEmpty else { return }
                        DispatchQueue.main.async { if !request.isCancelled { completion(suggestions) } }
                    }
                }
            }
        }
    }

    func completeNextWord(_ text: String, context: String) {
        let storage = self.storage
        queue.async { storage.engine.completeNextWord(text, context: context) }
    }

    func stageSelection(_ snapshot: CandidateSnapshot, event: CandidateLearningFeedback) {
        let storage = self.storage
        queue.async { storage.engine.stageSelection(snapshot, event: event) }
    }

    func stageNextWord(_ text: String, event: CandidateLearningFeedback) {
        let storage = self.storage
        queue.async { storage.engine.stageNextWord(text, event: event) }
    }

    func stageNativePrediction(_ prediction: NativePostCompositionPrediction, event: CandidateLearningFeedback) {
        let storage = self.storage
        queue.async { storage.engine.stageNativePrediction(prediction, event: event) }
    }
    func completeNativePrediction(_ prediction: NativePostCompositionPrediction) {
        let storage = self.storage
        queue.async { storage.engine.completeNativePrediction(prediction) }
    }

    func resolveFeedback(_ id: UUID, accepted: Bool) {
        let storage = self.storage
        queue.async { storage.engine.resolveFeedback(id, accepted: accepted) }
    }

    func complete(_ candidate: CandidateSnapshot, explicit: Bool = true) {
        let storage = self.storage
        let queue = self.queue
        queue.async {
            storage.engine.complete(candidate, explicit: explicit)
            // Persistence occurs on confirmation boundaries, never on keystrokes.
            queue.async { storage.flushCachedLearning() }
        }
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    func disableLanguageModel() {
        cancelPending()
        Self.modelQueue.async { LanguageModelStorage.shared.release() }
    }

    func handleMemoryPressure() {
        cancelPreparation()
        LanguageModelStorage.shared.setSuspended(true)
        cancelPending()
        let storage = self.storage
        Self.modelQueue.async { LanguageModelStorage.shared.release() }
        queue.async { storage.handleMemoryPressure() }
    }

    /// Only an explicit off-to-on settings change retries neural work after a
    /// memory warning; ordinary keystrokes and host changes must not reload it
    func allowLanguageModel() {
        LanguageModelStorage.shared.setSuspended(false)
    }

    func resourceState() async -> ResourceState {
        let storage = self.storage
        return await withCheckedContinuation { continuation in
            queue.async {
                let engineLoaded = storage.engineLoaded
                Self.modelQueue.async {
                    continuation.resume(returning: LanguageModelStorage.shared.resourceState(engineLoaded: engineLoaded))
                }
            }
        }
    }

    func reset(preservingContext: Bool = false) {
        cancelPending()
        let storage = self.storage
        queue.async { storage.resetCachedEngine(preservingContext: preservingContext) }
    }

    func releaseInactiveResources() {
        cancelPreparation()
        cancelPending()
        let storage = self.storage
        queue.async { storage.releaseInactiveResources() }
    }

    func clearLearning() {
        cancelPending()
        let storage = self.storage
        queue.async { storage.engine.clearLearning() }
    }

    deinit {
        preparation?.cancel()
        pending?.cancel()
        let storage = self.storage
        queue.async { storage.flushCachedLearning() }
    }
}
