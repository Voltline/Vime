import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// Committed context, staged learning feedback and post-composition suggestions.
nonisolated extension JapaneseCandidateEngine {
    /// Reconcile against real host text (already excluding the marked range).
    /// No replayed learning: parsing external context only supplies POS evidence.
    func reconcileContext(_ left: String?) {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.contextEvaluation, since: started) }
        let text = String((left ?? "").suffix(96))
        guard text != committedContext else { return }
        // Queries may observe a stale remote proxy while the previous commit
        // is still awaiting its receipt. Only the session's verified verdict
        // may accept/reject that feedback; query context is not a receipt.
        preferenceMemory?.resetRecent()
        if let learningSession { try? converter.withSession(learningSession) { converter.stopComposition() } }
        committedContext = text; contextCandidate = nil; previousTop = nil
        converter.stopComposition()
        primaryQuery = nil
        invalidateNativeResults()
        contextCandidate = parseCommittedContext()
    }

    func parseCommittedContext() -> Candidate? {
        guard !committedContext.isEmpty else { return nil }
        var query = ComposingText(); query.insertAtCursorPosition(committedContext, inputStyle: .direct)
        let session = contextSession ?? converter.createSession(); contextSession = session
        var contextOptions = options; contextOptions.N_best = 1
        contextOptions.requireJapanesePrediction = .disabled
        return try? converter.withSession(session) {
            converter.stopComposition()
            return converter.requestCandidates(query, options: contextOptions).mainResults.first
        }
    }

    func completeConversionContext(_ snapshot: CandidateSnapshot) {
        // Prefix queries are isolated from the original full-query lattice.
        // Map only its completion count into that original lattice; learning
        // always receives the untouched native Candidate below.
        if snapshot.source != .rememberedConversion, snapshot.displaySurface == nil, let query = primaryQuery,
           Array(query.input.suffix(snapshot.remainingComposition.input.count)) == snapshot.remainingComposition.input {
            var completion = snapshot.candidate
            completion.composingCount = .inputCount(snapshot.consumedInputCount)
            converter.setCompletedData(completion)
        } else {
            converter.stopComposition()
            primaryQuery = nil
        }
    }

    func complete(_ snapshot: CandidateSnapshot, explicit: Bool = true) {
        completeConversionContext(snapshot)
        if snapshot.learningEligible {
            converter.updateLearningData(snapshot.candidate)
            learningDirty = true
            invalidateNativeResults()
        }
        if let scope = snapshot.preferenceScope {
            preferenceMemory?.record(reading: snapshot.reading, surface: snapshot.text, scope: scope)
        }
        if explicit { recordChoice(snapshot, context: committedContext, weight: 1, now: Date()) }
        committedContext = String((committedContext + snapshot.text).suffix(96))
        contextCandidate = snapshot.lexical && snapshot.displaySurface == nil && !snapshot.candidate.data.isEmpty ? snapshot.candidate : nil
    }

    /// Context completion is immediate; learning waits for a verified host receipt.
    func stageSelection(_ snapshot: CandidateSnapshot, event: CandidateLearningFeedback) {
        if let pendingFeedback { resolveFeedback(pendingFeedback.event.id, accepted: false) }
        preferenceMemory?.refreshIfChanged()
        completeConversionContext(snapshot)
        committedContext = String((committedContext + snapshot.text).suffix(96))
        contextCandidate = snapshot.lexical && snapshot.displaySurface == nil && !snapshot.candidate.data.isEmpty ? snapshot.candidate : nil
        pendingFeedback = PendingFeedback(snapshot: snapshot, text: snapshot.text, event: event,
            learningEpoch: preferenceMemory?.clearEpoch)
        if let scope = snapshot.preferenceScope {
            preferenceMemory?.stage(id: event.id, reading: snapshot.reading, surface: snapshot.text,
                context: event.context, scope: scope,
                weight: event.weight, now: event.selectedAt)
        }
    }

    func stageNextWord(_ text: String, event: CandidateLearningFeedback) {
        if let pendingFeedback { resolveFeedback(pendingFeedback.event.id, accepted: false) }
        preferenceMemory?.refreshIfChanged()
        pendingFeedback = PendingFeedback(text: text, event: event, learningEpoch: preferenceMemory?.clearEpoch)
        committedContext = String((committedContext + text).suffix(96))
        contextCandidate = nil
        if let learningSession { try? converter.withSession(learningSession) { converter.stopComposition() } }
        preferenceMemory?.stage(id: event.id, reading: "", surface: text, context: event.context,
            scope: "nextWord", weight: event.weight, now: event.selectedAt)
    }

    func postCompositionSuggestions(leftContext: String) -> [NextWordSuggestion] {
        preferenceMemory?.refreshIfChanged()
        reconcileContext(leftContext)
        if contextCandidate == nil { contextCandidate = parseCommittedContext() }
        guard let base = contextCandidate, !base.data.isEmpty,
              committedContext.hasSuffix(base.text) else { return [] }
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.nativeNextWords, since: started) }
        return converter.requestPostCompositionPredictionCandidates(leftSideCandidate: base, options: options).enumerated().compactMap { rank, candidate in
            guard !candidate.text.isEmpty, candidate.text.count <= 128 else { return nil }
            let native = NativePostCompositionPrediction(base: base, text: candidate.text, value: candidate.value,
                type: candidate.type, isTerminal: candidate.isTerminal, expectedLeftContext: committedContext)
            if native.isReplacement && (native.replacedText.isEmpty || !committedContext.hasSuffix(native.replacedText)) { return nil }
            let emoji = candidate.text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            return NextWordSuggestion(text: native.insertionText, source: emoji ? .emoji : .enginePrediction,
                score: -Double(rank), userScore: preferenceMemory?.nextWordScore(native.insertionText, context: VimeLanguageModel.sentenceContext(leftContext)) ?? 0,
                nativePrediction: native)
        }
    }

    func stageNativePrediction(_ prediction: NativePostCompositionPrediction, event: CandidateLearningFeedback) {
        if let pendingFeedback { resolveFeedback(pendingFeedback.event.id, accepted: false) }
        guard committedContext == prediction.expectedLeftContext else { return }
        preferenceMemory?.refreshIfChanged()
        pendingFeedback = PendingFeedback(text: prediction.insertionText, event: event,
            learningEpoch: preferenceMemory?.clearEpoch, nativePrediction: prediction)
        committedContext = String((String(committedContext.dropLast(prediction.replacedText.count)) + prediction.insertionText).suffix(96))
        contextCandidate = prediction.joined
        preferenceMemory?.stage(id: event.id, reading: "", surface: prediction.insertionText, context: event.context,
            scope: "nextWord", weight: event.weight, now: event.selectedAt)
    }

    func completeNativePrediction(_ prediction: NativePostCompositionPrediction) {
        guard committedContext == prediction.expectedLeftContext else { return }
        converter.updateLearningData(prediction.base, with: prediction.native)
        learningDirty = true
        invalidateNativeResults()
        committedContext = String((String(committedContext.dropLast(prediction.replacedText.count)) + prediction.insertionText).suffix(96))
        contextCandidate = prediction.joined
        flushLearning()
    }

    func resolveFeedback(_ id: UUID, accepted: Bool) {
        guard let pending = pendingFeedback, pending.event.id == id else { return }
        pendingFeedback = nil
        if accepted { preferenceMemory?.refreshIfChanged() }
        guard accepted, pending.learningEpoch == preferenceMemory?.clearEpoch else {
            preferenceMemory?.cancel(id); feedbackCancelled += 1; return
        }
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.learningAcceptance, since: started) }
        feedbackAccepted += 1
        if let snapshot = pending.snapshot {
            if snapshot.learningEligible {
                // Query sessions reset lastData while typing. Keep accepted-word
                // chronology in a separate azooKey session, on the same queue.
                let session = learningSession ?? converter.createSession(); learningSession = session
                try? converter.withSession(session) {
                    converter.setCompletedData(snapshot.candidate)
                    converter.updateLearningData(snapshot.candidate)
                }
                learningDirty = true
                invalidateNativeResults()
            } else if let learningSession {
                try? converter.withSession(learningSession) { converter.stopComposition() }
            }
            if let scope = snapshot.preferenceScope {
                preferenceMemory?.record(reading: snapshot.reading, surface: snapshot.text, context: pending.event.context,
                    scope: scope, weight: pending.event.weight,
                    now: pending.event.selectedAt)
                if pending.event.isDeliberateChoice {
                    recordChoice(snapshot, context: pending.event.context, weight: pending.event.weight, now: pending.event.selectedAt)
                }
            }
        } else if let nativePrediction = pending.nativePrediction {
            let session = learningSession ?? converter.createSession(); learningSession = session
            try? converter.withSession(session) {
                converter.updateLearningData(nativePrediction.base, with: nativePrediction.native)
                converter.setCompletedData(nativePrediction.joined)
            }
            learningDirty = true
            invalidateNativeResults()
            preferenceMemory?.recordNextWord(pending.text, context: pending.event.context,
                weight: pending.event.weight, now: pending.event.selectedAt)
        } else {
            preferenceMemory?.recordNextWord(pending.text, context: pending.event.context,
                weight: pending.event.weight, now: pending.event.selectedAt)
        }
        flushLearning()
    }

    func recordChoice(_ snapshot: CandidateSnapshot, context: String, weight: Double, now: Date) {
        guard snapshot.preferenceScope != nil else { return }
        preferenceMemory?.record(reading: snapshot.reading, surface: snapshot.text, context: context,
                                 scope: "choice", weight: weight, now: now)
        // Share modest word preferences across phrases. Never teach transformed
        // display text as if it were the native word segmentation.
        guard snapshot.learningEligible else { return }
        var left = context
        var seen = Set<String>()
        var recorded = 0
        for element in snapshot.candidate.data {
            let key = element.ruby + "\0" + element.word
            if recorded < 6, element.ruby.count >= 2,
               seen.insert(key).inserted,
               element.metadata.contains(.isFromUserDictionary) || !Self.isKanaFallback(element),
               !element.word.unicodeScalars.allSatisfy({ Self.literalSeparators.contains($0) }) {
                preferenceMemory?.record(reading: element.ruby, surface: element.word, context: left,
                                         scope: "wordChoice", weight: weight, now: now)
                recorded += 1
            }
            left = String((left + element.word).suffix(96))
        }
    }

    func flushLearning() {
        let startedAt = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.learningPersistence, since: startedAt) }
        preferenceMemory?.flush()
        guard learningDirty else { return }
        converter.commitUpdateLearningData(); learningDirty = false
    }

    @discardableResult func clearLearning() -> Bool {
        // This pinned version exposes LearningConfig without a public initializer.
        // A nonempty request applies our existing public request configuration.
        var bootstrap = ComposingText(); bootstrap.insertAtCursorPosition("　", inputStyle: .direct)
        _ = converter.requestCandidates(bootstrap, options: options)
        converter.resetMemory(); learningDirty = false
        preferenceMemory?.clear()
        invalidateNativeResults()
        reset()
        // The upstream reset API logs filesystem errors instead of returning
        // them. Verify deletion before acknowledging an app reset request.
        guard preferenceMemory != nil, preferenceMemory?.persistenceError == nil,
              let files = try? FileManager.default.contentsOfDirectory(at: memoryDirectoryURL,
                includingPropertiesForKeys: nil) else { return false }
        let nativeSuffixes = [".loudstxt3", ".loudschars2", ".memorymetadata", ".louds",
            ".loudstxt3.2", ".loudschars2.2", ".memorymetadata.2", ".louds.2", ".pause", "learningMemory.txt"]
        return !files.contains { file in nativeSuffixes.contains { file.lastPathComponent.hasSuffix($0) } }
    }

    func rememberedNextWords(context: String) -> [String] {
        preferenceMemory?.rememberedNextWords(context: context) ?? []
    }
    func personalizedNextWords(_ words: [ScoredNextWord], history: [ScoredNextWord], context: String) -> [NextWordSuggestion] {
        preferenceMemory?.nextWords(words, history: history, context: context) ?? words.map {
            NextWordSuggestion(text: $0.text, source: .contextPrediction,
                score: $0.logProbabilitySum, userScore: 0, modelScore: $0.logProbabilitySum, tokenCount: $0.tokenCount)
        }
    }
    func completeNextWord(_ text: String, context: String) {
        preferenceMemory?.recordNextWord(text, context: context)
        preferenceMemory?.flush()
    }
}
