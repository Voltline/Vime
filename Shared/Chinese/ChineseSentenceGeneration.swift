import Foundation

/// Whole-sentence Chinese candidates generated under the pinyin typed, then
/// rescored by the reranking model with the text before the caret.
///
/// In v2 task mode (`decodingMode == .task`), `ChineseInputSession` schedules
/// a single pause-triggered generation and weighs its top sentence against the
/// current lead with `decide`. Any failure — keys no sentence spells, no model,
/// suspension, cancellation or the deadline — returns nil, and the caller keeps
/// Rime's candidates. When only rescoring fails, generation scores alone decide.
nonisolated enum ChineseSentenceGeneration {
    /// Development switch (App Group defaults); on unless set to false.
    static let developmentSwitchKey = "vime.development.chineseSentenceGeneration"
    static var isEnabled: Bool {
        UserDefaults(suiteName: KeyboardPreferences.appGroup)?.object(forKey: developmentSwitchKey) as? Bool ?? true
    }
    static let mode: ChineseConstrainedGeneration.Mode = .lm
    static let parameters = ChineseConstrainedGeneration.Parameters()
    /// Weight of the reranking model's log probability against the generator's.
    static let rescoreWeight = 1.6
    /// Input lengths eligible for pause-triggered sentence generation.
    static let letters = 4...48
    /// Generated lead replaces the current lead only when its LM score beats it by at least this much.
    static let leadMargin = 3.0
    /// Minimum LM score lead over the current lead required to show at rank 2.
    static let showMargin = 0.0

    /// Whether `input` is eligible for pause-triggered generation: plain lowercase letters in range.
    static func wants(_ input: String) -> Bool {
        letters.contains(input.count) && input.allSatisfy { ("a"..."z").contains($0) }
    }

    struct Decision: Equatable, Sendable {
        let candidate: Candidate
        /// True when the generated sentence should take rank 1; false for rank 2.
        let leads: Bool
    }

    /// Decides whether `generated` should show against `currentLead`, using LM scores
    /// computed with the same model and context. Protected leads (user phrases,
    /// learned words, or whole-input Rime dictionary words) are never displaced.
    static func decide(generated: Candidate, currentLead: String, currentScore: Double,
                       generatedScore: Double, leadProtected: Bool) -> Decision? {
        guard !generated.text.isEmpty, generated.text != currentLead,
              currentScore.isFinite, generatedScore.isFinite else { return nil }
        let margin = generatedScore - currentScore
        if !leadProtected, margin >= leadMargin {
            return Decision(candidate: generated, leads: true)
        }
        if margin >= showMargin {
            return Decision(candidate: generated, leads: false)
        }
        return nil
    }

    struct Candidate: Equatable, Sendable {
        let text: String
        let generationScore: Double
        /// The reranking model's log probability after the context, when it scored.
        let modelScore: Double?
        let score: Double
    }

    /// generation + `rescoreWeight` × model, best first; the generation
    /// scores alone when `modelScores` is nil or does not fit.
    static func rescored(_ generated: [ChineseConstrainedGeneration.Result], modelScores: [Double]?) -> [Candidate] {
        let fits = modelScores.map { $0.count == generated.count && $0.allSatisfy(\.isFinite) } ?? false
        let candidates = generated.enumerated().map { index, result in
            let model = fits ? modelScores![index] : nil
            return Candidate(text: result.text, generationScore: result.score, modelScore: model,
                             score: result.score + rescoreWeight * (model ?? 0))
        }
        return candidates.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element)
    }

    /// Drops what `allows` refuses (the same exclusions Rime's candidates go
    /// through) and rescores with `scorer`; nil when nothing is left or
    /// `cancelled`. Model queue.
    static func finished(_ generated: [ChineseConstrainedGeneration.Result], context: String,
                         scorer: ChineseLanguageModel?, allows: (String) -> Bool,
                         cancelled: () -> Bool) -> [Candidate]? {
        let allowed = generated.filter { allows($0.text) }
        guard !allowed.isEmpty, !cancelled() else { return nil }
        let scores = scorer.flatMap {
            try? $0.scores(context: context, candidates: allowed.map(\.text), cancelled: cancelled)
        }
        guard !cancelled() else { return nil }
        return rescored(allowed, modelScores: scores)
    }

    /// A fresh search for all of `keys` at once, then `finished`. Model queue.
    static func candidates(keys: String, leftContext: String, generator: Storage.Generator,
                           parameters: ChineseConstrainedGeneration.Parameters = Self.parameters,
                           scorer: ChineseLanguageModel?, allows: (String) -> Bool,
                           cancelled: () -> Bool) -> [Candidate]? {
        let context = VimeLanguageModel.sentenceContext(leftContext)
        guard let typed = ChinesePinyinKeys(keys) else { return nil }
        let generated: [ChineseConstrainedGeneration.Result]
        switch generator.mode {
        case .task:
            guard let parts = try? ChineseConstrainedGeneration.taskPromptParts(
                      context: context, keys: keys, tokenizer: generator.tokenizer),
                  let output = try? ChineseConstrainedGeneration.generateTask(
                      model: generator.model, vocabulary: generator.vocabulary, lexicon: generator.lexicon,
                      keys: typed, contextPrefix: parts.contextPrefix, keySuffix: parts.keySuffix,
                      parameters: parameters, cancelled: cancelled)
            else { return nil }
            generated = output.results
        case .lm:
            guard let prompt = try? ChineseConstrainedGeneration.prompt(.lm, context: context, keys: "",
                                                                        tokenizer: generator.tokenizer),
                  let session = try? ChineseIncrementalGeneration(model: generator.model, vocabulary: generator.vocabulary,
                                                                  lexicon: generator.lexicon, prompt: prompt, parameters: parameters),
                  let output = try? session.update(typed, cancelled: cancelled)
            else { return nil }
            generated = output
        }
        return finished(generated, context: context, scorer: scorer, allows: allows, cancelled: cancelled)
    }

    /// Whether `generate` rescores with the reranking model in lm mode (v1);
    /// task mode (v2) always rescores with its own LM scores.
    static let rescores = false

    /// Generates on the model queue (v2: task mode with self rescoring;
    /// v1: incremental lm mode reused across keystrokes), and reports on the
    /// main queue: the generated sentences that `allows` keeps, best first, or
    /// nil (cancelled, no model, nothing spelled).
    static func generate(keys: String, leftContext: String, request: ChineseCandidateRanking.Request,
                         allows: @escaping @Sendable (String) -> Bool,
                         completion: @escaping @MainActor ([Candidate]?) -> Void) {
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        JapaneseCandidateWorker.modelQueue.async {
            var result: [Candidate]?
            let stop = { request.isCancelled || storage.isSuspended }
            let context = VimeLanguageModel.sentenceContext(leftContext)
            if !stop(), let model = storage.chineseModel, let typed = ChinesePinyinKeys(keys),
               let generator = Storage.shared.generator(for: model) {
                switch model.decodingMode {
                case .task:
                    result = candidates(keys: keys, leftContext: leftContext, generator: generator,
                                        scorer: model, allows: allows, cancelled: stop)
                case .lm:
                    if let session = Storage.shared.session(context: context, model: model),
                       let generated = try? session.update(typed, cancelled: stop) {
                        result = finished(generated, context: context, scorer: rescores ? model : nil, allows: allows,
                                          cancelled: stop)
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Runs v2 task-mode generation on the model queue, weighs its top candidate
    /// against `currentLead` with the same model and context, and delivers a
    /// placement decision on the main queue. Never records keystroke fallback latency.
    static func generateAndWeigh(
        keys: String,
        leftContext: String,
        currentLead: String,
        leadProtected: Bool,
        request: ChineseCandidateRanking.Request,
        allows: @escaping @Sendable (String) -> Bool,
        completion: @escaping @MainActor (Decision?) -> Void
    ) {
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        JapaneseCandidateWorker.modelQueue.async {
            var decision: Decision?
            let stop = { request.isCancelled || storage.isSuspended }
            if !stop(), let model = storage.chineseModel, model.decodingMode == .task,
               let generator = Storage.shared.generator(for: model),
               let ranked = candidates(keys: keys, leftContext: leftContext, generator: generator,
                                       scorer: model, allows: allows, cancelled: stop),
               let top = ranked.first, top.text != currentLead, !stop() {
                let context = VimeLanguageModel.sentenceContext(leftContext)
                if let pair = try? model.scores(context: context, candidates: [currentLead, top.text], cancelled: stop),
                   pair.count == 2, !stop() {
                    decision = decide(generated: top, currentLead: currentLead,
                                      currentScore: pair[0], generatedScore: pair[1],
                                      leadProtected: leadProtected)
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(decision) } }
        }
    }

    /// What the search needs on top of the Chinese model (whose package and
    /// tokenizer it uses): its usable tokens, the dictionary, and the search
    /// of the current context. Dropped with the model by
    /// `ChineseCandidateRanking.release()`, and rebuilt when the model is
    /// another instance. Model queue.
    final class Storage: @unchecked Sendable {
        static let shared = Storage()
        struct Generator {
            let mode: ChineseConstrainedGeneration.Mode
            let model: ChineseKVGenerator
            let tokenizer: VimeSentenceTokenizer
            let vocabulary: ChineseConstrainedGeneration.Vocabulary
            let lexicon: ChinesePinyinLexicon
        }
        private var cached: (owner: ObjectIdentifier, generator: Generator)?
        private var current: ChineseIncrementalGeneration<ChineseKVGenerator>?

        func generator(for model: ChineseLanguageModel) -> Generator? {
            dispatchPrecondition(condition: .onQueue(JapaneseCandidateWorker.modelQueue))
            if let cached, cached.owner == ObjectIdentifier(model) { return cached.generator }
            release()
            guard let generator = Self.generator(for: model) else { return nil }
            cached = (ObjectIdentifier(model), generator)
            return generator
        }

        /// The search's tokens and dictionary for `model`; nil without Rime's table.
        static func generator(for model: ChineseLanguageModel) -> Generator? {
            autoreleasepool {
                guard let lexicon = ChinesePinyinLexicon.bundled else { return nil }
                let vocabulary = ChineseConstrainedGeneration.Vocabulary(
                    tokenizer: model.tokenizer, size: model.batch.vocabularySize, lexicon: lexicon)
                return Generator(mode: model.decodingMode, model: ChineseKVGenerator(batch: model.batch),
                                 tokenizer: model.tokenizer, vocabulary: vocabulary, lexicon: lexicon)
            }
        }

        /// The search after `context`, kept while the context stays the same.
        func session(context: String, model: ChineseLanguageModel) -> ChineseIncrementalGeneration<ChineseKVGenerator>? {
            guard let generator = generator(for: model),
                  let prompt = try? ChineseConstrainedGeneration.prompt(.lm, context: context, keys: "",
                                                                        tokenizer: generator.tokenizer)
            else { return nil }
            if let current, current.prompt == prompt { return current }
            current = try? ChineseIncrementalGeneration(model: generator.model, vocabulary: generator.vocabulary,
                                                        lexicon: generator.lexicon, prompt: prompt, parameters: parameters)
            return current
        }

        func release() {
            dispatchPrecondition(condition: .onQueue(JapaneseCandidateWorker.modelQueue))
            cached = nil; current = nil
        }
    }
}
