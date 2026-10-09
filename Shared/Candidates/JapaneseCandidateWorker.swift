import Foundation
import os
import KanaKanjiConverterModuleWithDefaultDictionary

/// The converter and its dictionary caches belong exclusively to this queue.
/// Cancellation skips superseded requests; a running request may finish but
/// the session revision prevents it from changing newer composition state.
@MainActor
final class JapaneseCandidateWorker {
    private nonisolated final class Storage: @unchecked Sendable {
        private var cachedEngine: JapaneseCandidateEngine?
        private var cachedLanguageModel: VimeLanguageModel?
        private var attemptedLanguageModel = false
        func releaseLanguageModel() {
            cachedLanguageModel = nil
            attemptedLanguageModel = false
        }
        var languageModel: VimeLanguageModel? {
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
                    ranking: CandidateRankingMode = .languageModel,
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
                let sentence = VimeLanguageModel.sentenceContext(leftContext ?? "")
                let rerank = { (values: [CandidateSnapshot]) -> [CandidateSnapshot] in
                    guard ranking == .languageModel, !request.isCancelled,
                          VimeLanguageModel.rerankingSlots(values, katakana: katakana).count > 1 else { return values }
                    return storage.languageModel?.rerank(values, context: sentence, katakana: katakana,
                        cancelled: { request.isCancelled }) ?? values
                }
                let ranked = rerank(values)
                guard !request.isCancelled else { return }
                if ranked.map(\.presentation) != values.map(\.presentation) {
                    let readyAt = KeyboardPerformance.start()
                    DispatchQueue.main.async { completion(ranked, readyAt, true) }
                }
                let correctionStartedAt = KeyboardPerformance.start()
                let corrected = storage.engine.addingCorrections(to: values, for: composing, katakana: katakana,
                    revision: revision, cancelled: { request.isCancelled })
                KeyboardPerformance.record(.correctionCompute, since: correctionStartedAt)
                guard !request.isCancelled, corrected.map(\.presentation) != values.map(\.presentation) else { return }
                let expanded = rerank(corrected)
                guard !request.isCancelled, expanded.map(\.presentation) != ranked.map(\.presentation) else { return }
                KeyboardPerformance.record(.correctionRequestToResult, since: requestStartedAt)
                let readyAt = KeyboardPerformance.start()
                DispatchQueue.main.async { completion(expanded, readyAt, true) }
            }
        }
    }

    /// LM next-word prediction for the unfinished sentence. Shares the serial queue and
    /// the cancellation slot with candidate requests, so typing stops the search.
    func suggestions(prompt: String, completion: @escaping @MainActor @Sendable ([NextWordSuggestion]) -> Void) {
        pending?.cancel()
        let request = Request()
        pending = request
        let storage = self.storage
        queue.async {
            guard !request.isCancelled else { return }
            let history = storage.engine.rememberedNextWords(context: prompt)
            let words = try? storage.languageModel?.scoredNextWords(prompt: prompt, history: history,
                cancelled: { request.isCancelled })
            guard !request.isCancelled else { return }
            let suggestions = storage.engine.personalizedNextWords(words?.generated ?? [], history: words?.history ?? [], context: prompt)
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
