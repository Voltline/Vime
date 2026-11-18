import Foundation

/// Whole-sentence Chinese candidates generated under the pinyin typed, then
/// rescored by the reranking model with the text before the caret.
///
/// Not shown yet: Rime's candidates and their reranking
/// (`ChineseCandidateRanking`) decide what the keyboard shows, and this path
/// runs only behind `isEnabled`, a development switch. The generator is the
/// zh-v1 batched KV package (kvbatch-v3) in lm mode for now — the prompt in
/// one call, each bucket in one call scoring only its letter's tokens —
/// searching forward only and kept across keystrokes (`ChineseIncrementalGeneration`); the three-task model puts the
/// keys in the prompt, so it would search afresh with `mode: .task`.
///
/// Any failure — keys no sentence spells, no model, cancellation or the
/// deadline — returns nil, and the caller keeps Rime's candidates. When only
/// the rescoring fails, the generation scores alone decide.
nonisolated enum ChineseSentenceGeneration {
    /// Development switch (App Group defaults); off unless set by hand.
    static let developmentSwitchKey = "vime.development.chineseSentenceGeneration"
    static var isEnabled: Bool {
        UserDefaults(suiteName: KeyboardPreferences.appGroup)?.bool(forKey: developmentSwitchKey) ?? false
    }
    static let mode: ChineseConstrainedGeneration.Mode = .lm
    static let parameters = ChineseConstrainedGeneration.Parameters()
    /// Weight of the reranking model's log probability against the generator's.
    static let rescoreWeight = 1.6

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
        guard let typed = ChinesePinyinKeys(keys),
              let prompt = try? ChineseConstrainedGeneration.prompt(.lm, context: context, keys: "",
                                                                    tokenizer: generator.tokenizer),
              let session = try? ChineseIncrementalGeneration(model: generator.model, vocabulary: generator.vocabulary,
                                                              lexicon: generator.lexicon, prompt: prompt, parameters: parameters),
              let generated = try? session.update(typed, cancelled: cancelled)
        else { return nil }
        return finished(generated, context: context, scorer: scorer, allows: allows, cancelled: cancelled)
    }

    /// Whether `generate` rescores with the reranking model; off while the
    /// incremental search is measured on its own.
    static let rescores = false

    /// Generates on the model queue, reusing the search for the same context
    /// across keystrokes, and reports on the main queue: the generated
    /// sentences that `allows` keeps, best first, or nil (cancelled, no model,
    /// nothing spelled). `request` is the reranking's: a new key cancels it,
    /// and what the search finished stays for the next key. lm mode only.
    static func generate(keys: String, leftContext: String, request: ChineseCandidateRanking.Request,
                         allows: @escaping @Sendable (String) -> Bool,
                         completion: @escaping @MainActor ([Candidate]?) -> Void) {
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        JapaneseCandidateWorker.modelQueue.async {
            var result: [Candidate]?
            let stop = { request.isCancelled || storage.isSuspended }
            let context = VimeLanguageModel.sentenceContext(leftContext)
            if !stop(), let model = storage.chineseModel, let typed = ChinesePinyinKeys(keys),
               let session = Storage.shared.session(context: context, model: model),
               let generated = try? session.update(typed, cancelled: stop) {
                result = finished(generated, context: context, scorer: rescores ? model : nil, allows: allows,
                                  cancelled: stop)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
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
                return Generator(model: ChineseKVGenerator(batch: model.batch), tokenizer: model.tokenizer,
                                 vocabulary: vocabulary, lexicon: lexicon)
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
