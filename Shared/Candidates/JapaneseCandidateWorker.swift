import Foundation
import os
import KanaKanjiConverterModuleWithDefaultDictionary

/// The converter and its dictionary caches belong exclusively to this queue.
/// Cancellation skips superseded requests; a running request may finish but
/// the session revision prevents it from changing newer composition state.
@MainActor
final class JapaneseCandidateWorker {
    nonisolated struct ResourceState: Equatable, Sendable {
        let engineLoaded: Bool
        let modelLoaded: Bool
        let modelSuspendedForMemoryPressure: Bool
    }
    private nonisolated final class Storage: @unchecked Sendable {
        private var cachedEngine: JapaneseCandidateEngine?
        private var cachedLanguageModel: VimeLanguageModel?
        private var attemptedLanguageModel = false
        var modelSuspendedForMemoryPressure = false
        var resourceState: ResourceState {
            ResourceState(engineLoaded: cachedEngine != nil, modelLoaded: cachedLanguageModel != nil,
                          modelSuspendedForMemoryPressure: modelSuspendedForMemoryPressure)
        }
        func handleMemoryPressure() {
            modelSuspendedForMemoryPressure = true
            releaseLanguageModel()
            cachedEngine?.discardTransientCaches()
        }
        func releaseLanguageModel() {
            cachedLanguageModel = nil
            attemptedLanguageModel = false
        }
        var languageModel: VimeLanguageModel? {
            guard !modelSuspendedForMemoryPressure else { return nil }
            if !attemptedLanguageModel {
                attemptedLanguageModel = true
                let log = Logger(subsystem: "com.Voltline.Vime", category: "LanguageModel")
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    try autoreleasepool { cachedLanguageModel = try VimeLanguageModel() }
                    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    let version = cachedLanguageModel?.modelVersion ?? "unknown"
                    VimeExtensionAudit.recordModelLoad(version: version, milliseconds: milliseconds)
                    log.notice("Model \(version, privacy: .public) loaded in \(milliseconds) ms; footprint \(VimeLanguageModel.footprintMB()) MB")
                } catch {
                    log.error("Model unavailable (\(String(describing: error), privacy: .public)); retaining dictionary candidates.")
                }
            }
            return cachedLanguageModel
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
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    // Drain Foundation/Core ML temporaries at every request, including cancelled
    // work, instead of relying on the long-lived queue's inherited pool policy
    private let queue = DispatchQueue(label: "com.Voltline.Vime.candidates", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
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
            guard !request.isCancelled else { return }
            storage.engine.reconcileContext(leftContext)
            storage.engine.seedContinuity(continuity)
            let computeStartedAt = KeyboardPerformance.start()
            let values = storage.engine.candidates(for: composing, katakana: katakana, revision: revision, includeCorrections: false, conversionLength: conversionLength)
            KeyboardPerformance.record(.candidateCompute, since: computeStartedAt)
            KeyboardPerformance.record(.candidateRequestToResult, since: requestStartedAt)
            let readyAt = KeyboardPerformance.start()
            guard !request.isCancelled else { return }
            DispatchQueue.main.async { completion(values, readyAt, false) }
            // Normal prediction is delivered first. New input cancels this
            // supplementary search before it starts; running search checks every query.
            queue.async {
                guard !request.isCancelled else { return }
                let sentence = VimeLanguageModel.sentenceContext(leftContext ?? "")
                let rerank = { (values: [CandidateSnapshot]) -> [CandidateSnapshot] in
                    guard ranking == .languageModel, !request.isCancelled,
                          VimeLanguageModel.rerankingSlots(values, katakana: katakana).count > 1 else { return values }
                    return storage.languageModel?.rerank(values, context: sentence, katakana: katakana,
                        cancelled: { request.isCancelled }) ?? values
                }
                let formatted = expanded
                    ? storage.engine.addingWidthCandidates(to: values, for: composing, katakana: katakana,
                        revision: revision, conversionLength: conversionLength, cancelled: { request.isCancelled }) : values
                let enriched = expanded && conversionLength == nil
                    ? storage.engine.addingPrefixCandidates(to: formatted, for: composing, katakana: katakana,
                        revision: revision, cancelled: { request.isCancelled }) : formatted
                guard !request.isCancelled else { return }
                // Prefix choices are useful immediately; a cold LM must not
                // hold the expanded menu's dictionary supplementation hostage.
                if enriched.map(\.presentation) != values.map(\.presentation) {
                    let readyAt = KeyboardPerformance.start()
                    DispatchQueue.main.async { completion(enriched, readyAt, true) }
                }
                let ranked = rerank(enriched)
                guard !request.isCancelled else { return }
                if ranked.map(\.presentation) != enriched.map(\.presentation) {
                    let readyAt = KeyboardPerformance.start()
                    DispatchQueue.main.async { completion(ranked, readyAt, true) }
                }
                guard conversionLength == nil else { return }
                let correctionStartedAt = KeyboardPerformance.start()
                let corrected = storage.engine.addingCorrections(to: enriched, for: composing, katakana: katakana,
                    revision: revision, cancelled: { request.isCancelled })
                KeyboardPerformance.record(.correctionCompute, since: correctionStartedAt)
                guard !request.isCancelled, corrected.map(\.presentation) != enriched.map(\.presentation) else { return }
                let expanded = rerank(corrected)
                guard !request.isCancelled, expanded.map(\.presentation) != ranked.map(\.presentation) else { return }
                KeyboardPerformance.record(.correctionRequestToResult, since: requestStartedAt)
                let readyAt = KeyboardPerformance.start()
                DispatchQueue.main.async { completion(expanded, readyAt, true) }
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
                cancelled: { request.isCancelled })
            guard !request.isCancelled else { return }
            let neural = storage.engine.personalizedNextWords(words?.generated ?? [], history: words?.history ?? [], context: prompt)
            let pool = PostCompositionSuggestionReranker.merge(native: native, neural: neural)
            let suggestions = storage.languageModel?.rerankPostComposition(pool, prompt: prompt,
                cancelled: { request.isCancelled }) ?? pool
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

    func disableLanguageModel() {
        cancelPending()
        let storage = self.storage
        queue.async { storage.releaseLanguageModel() }
    }

    func handleMemoryPressure() {
        cancelPending()
        let storage = self.storage
        queue.async { storage.handleMemoryPressure() }
    }

    /// Only an explicit off-to-on settings change retries neural work after a
    /// memory warning; ordinary keystrokes and host changes must not reload it
    func allowLanguageModel() {
        let storage = self.storage
        queue.async { storage.modelSuspendedForMemoryPressure = false }
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
