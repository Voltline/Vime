import Foundation
import os
import KanaKanjiConverterModuleWithDefaultDictionary

/// The converter and its dictionary caches belong exclusively to this queue.
/// Cancellation skips superseded requests; a running request may finish but
/// the session revision prevents it from changing newer composition state.
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
    /// Every worker uses this queue, so the process owns at most one model and
    /// neither Core ML nor SentencePiece is used concurrently by two sessions.
    private nonisolated static let candidateQueue = DispatchQueue(
        label: "com.Voltline.Vime.candidates", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private nonisolated final class LanguageModelStorage: @unchecked Sendable {
        static let shared = LanguageModelStorage()
        // Only the pressure gate crosses queues. Set it immediately, even when
        // model initialization or prediction is still running on candidateQueue.
        private let lock = NSLock()
        private var suspended = false
        var isSuspended: Bool { lock.lock(); defer { lock.unlock() }; return suspended }
        func setSuspended(_ value: Bool) { lock.lock(); suspended = value; lock.unlock() }
        private(set) var cachedModel: VimeLanguageModel?
        private var attempted = false
        private(set) var loadCount = 0
        func release() { cachedModel = nil; attempted = false }
        var model: VimeLanguageModel? {
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
                } catch {
                    log.error("Model unavailable (\(String(describing: error), privacy: .public)); retaining dictionary candidates.")
                }
            }
            return isSuspended ? nil : cachedModel
        }
    }
    private nonisolated final class Storage: @unchecked Sendable {
        private var cachedEngine: JapaneseCandidateEngine?
        var resourceState: ResourceState {
            let model = LanguageModelStorage.shared
            return ResourceState(engineLoaded: cachedEngine != nil, modelLoaded: model.cachedModel != nil,
                                 modelSuspendedForMemoryPressure: model.isSuspended,
                                 modelLoadCount: model.loadCount)
        }
        func handleMemoryPressure() {
            LanguageModelStorage.shared.release()
            cachedEngine?.discardTransientCaches()
        }
        var languageModel: VimeLanguageModel? { LanguageModelStorage.shared.model }
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
    private nonisolated final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var initiallyPublished = false
        private var refinement: [CandidateSnapshot]?
        func cancel() { lock.lock(); cancelled = true; refinement = nil; lock.unlock() }
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

    func candidates(for composing: ComposingText, katakana: Bool, revision: Int, leftContext: String?, continuity: CandidateContinuity?,
                    ranking: CandidateRankingMode = .languageModel, conversionLength: Int? = nil, expanded: Bool = false,
                    completion: @escaping @MainActor @Sendable ([CandidateSnapshot], TimeInterval?, Bool) -> Void) {
        pending?.cancel()
        let request = Request()
        pending = request
        let storage = self.storage
        let queue = self.queue
        let requestStartedAt = KeyboardPerformance.start()
        queue.async {
            KeyboardPerformance.record(.candidateQueueWait, since: requestStartedAt)
            guard !request.isCancelled else { return }
            storage.engine.reconcileContext(leftContext)
            storage.engine.seedContinuity(continuity)
            let computeStartedAt = KeyboardPerformance.start()
            let values = storage.engine.candidates(for: composing, katakana: katakana, revision: revision, includeCorrections: false, conversionLength: conversionLength)
            KeyboardPerformance.record(.candidateCompute, since: computeStartedAt)
            KeyboardPerformance.record(.candidateRequestToResult, since: requestStartedAt)
            let readyAt = KeyboardPerformance.start()
            guard !request.isCancelled else { return }
            let sentence = VimeLanguageModel.sentenceContext(leftContext ?? "")
            // Sentence-initial ranking currently adds a publication window
            // for little measured gain. Keep native/personal evidence there.
            let neuralRanking = ranking == .languageModel && !sentence.isEmpty
                && CandidateCompetitionPolicy.plan(values, katakana: katakana, maximumCandidates: Self.initialRankingCandidateLimit).slots.count > 1
            let initialDeadline = ProcessInfo.processInfo.systemUptime + Self.initialRankingWindow
            if neuralRanking {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.initialRankingWindow) {
                    if let result = request.claimInitialPublication(fallback: values) { completion(result, readyAt, false) }
                }
            } else {
                DispatchQueue.main.async {
                    if let result = request.claimInitialPublication(fallback: values) { completion(result, readyAt, false) }
                }
            }
            // New input cancels supplementary work. Neural ranking gets one
            // short opportunity before display; corrections supplement that
            // published list without another model pass or visible permutation.
            let supplementaryQueuedAt = KeyboardPerformance.start()
            queue.async {
                KeyboardPerformance.record(.supplementaryQueueWait, since: supplementaryQueuedAt)
                guard !request.isCancelled else { return }
                if neuralRanking {
                    // Load once even when cold initialization exceeds the window;
                    // the timer still publishes promptly and later input uses the warm model.
                    let model = storage.languageModel
                    guard !request.isCancelled else { return }
                    _ = model?.rerank(values, context: sentence,
                        katakana: katakana, maximumCandidates: Self.initialRankingCandidateLimit, onRefinement: {
                            request.refine($0, before: initialDeadline)
                        }, cancelled: {
                            request.isCancelled || LanguageModelStorage.shared.isSuspended
                                || ProcessInfo.processInfo.systemUptime >= initialDeadline
                        }) ?? values
                    let rankedReadyAt = KeyboardPerformance.start()
                    DispatchQueue.main.async {
                        // The timer and this callback use only refinements
                        // completed within the window, including partial work.
                        guard let result = request.claimInitialPublication(fallback: values) else { return }
                        completion(result, rankedReadyAt, false)
                    }
                }
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
    }

    /// Native-first, optionally neural next-word prediction. Shares the serial queue and
    /// the cancellation slot with candidate requests, so typing stops the search.
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
            let words = try? storage.languageModel?.scoredNextWords(prompt: prompt, history: history,
                cancelled: { request.isCancelled || LanguageModelStorage.shared.isSuspended })
            guard !request.isCancelled else { return }
            let neural = storage.engine.personalizedNextWords(words?.generated ?? [], history: words?.history ?? [], context: prompt)
            let pool = PostCompositionSuggestionReranker.merge(native: native, neural: neural)
            let suggestions = storage.languageModel?.rerankPostComposition(pool, prompt: prompt,
                cancelled: { request.isCancelled || LanguageModelStorage.shared.isSuspended }) ?? pool
            guard !suggestions.isEmpty else { return }
            DispatchQueue.main.async { if !request.isCancelled { completion(suggestions) } }
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
        queue.async { LanguageModelStorage.shared.release() }
    }

    func handleMemoryPressure() {
        LanguageModelStorage.shared.setSuspended(true)
        cancelPending()
        let storage = self.storage
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
            queue.async { continuation.resume(returning: storage.resourceState) }
        }
    }

    func reset(preservingContext: Bool = false) {
        cancelPending()
        let storage = self.storage
        queue.async { storage.resetCachedEngine(preservingContext: preservingContext) }
    }

    func releaseInactiveResources() {
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
        pending?.cancel()
        let storage = self.storage
        queue.async { storage.flushCachedLearning() }
    }
}
