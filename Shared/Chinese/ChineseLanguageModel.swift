import Foundation

/// The Chinese keyboard's model: VimeML's vimeml-tiny-zh-v1 as the
/// kvbatch-v3 package, with its tokenizer. One instance, held by
/// `JapaneseCandidateWorker.LanguageModelStorage` like the Japanese model
/// (never both at once), serves reranking (`scores`), sentence correction
/// (`tokenScores`, `ChinesePrefixScoring`) and sentence generation (`batch`).
///
/// Model queue, like the package.
nonisolated final class ChineseLanguageModel {
    static let tokenizerResource = "VimeChineseTokenizerV1"
    static let vocabulary = 12288
    static let displayVersion = "1"
    /// <CTX>, <READ> and <OUT>: the three-task model's markers, never part of a scored sentence.
    static let reservedTokens: Set<Int32> = [4, 5, 6]

    let batch: VimeKVBatchLanguageModel
    let tokenizer: VimeSentenceTokenizer
    var modelVersion: String { batch.modelVersion }

    /// `preload` loads the `score` function now, as the keyboard does so
    /// that a cold load never holds a request.
    init(bundle: Bundle = .main, preload: Bool = false) throws {
        guard let tokenizerURL = bundle.url(forResource: Self.tokenizerResource, withExtension: "model")
        else { throw VimeLanguageModel.Failure.resources }
        batch = try VimeKVBatchLanguageModel(bundle: bundle)
        tokenizer = try VimeSentenceTokenizer(url: tokenizerURL, vocabulary: Self.vocabulary)
        if preload { try batch.preload(.score) }
    }

    /// Reranking: each candidate's summed log probability after `context`,
    /// all of them from the token where the first one parts from the
    /// context, so that they compare over the same tokens. Distinct,
    /// non-empty candidates only.
    func scores(context: String, candidates: [String], cancelled: () -> Bool = { false }) throws -> [Double] {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.lmCandidateScoring, since: started) }
        guard !cancelled() else { throw VimeLanguageModel.Failure.cancelled }
        guard Set(candidates.map { Data($0.utf8) }).count == candidates.count
        else { throw VimeLanguageModel.Failure.ineligible }
        return try ChinesePrefixScoring.scores(context: context, candidates: candidates, sharedStart: true,
                                               model: batch, tokenizer: tokenizer, cancelled: cancelled)
    }

    /// The tokens of `text` after `context`, each with its log probability.
    func tokenScores(context: String, text: String) throws -> [(text: String, logProbability: Double)] {
        try ChinesePrefixScoring.tokenScores(context: context, text: text, model: batch, tokenizer: tokenizer)
            .map { (try tokenizer.decode([$0.id]), $0.logProbability) }
    }
}
