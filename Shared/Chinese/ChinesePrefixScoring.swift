import Foundation

/// The reranking scores of many sentences at once on the kvbatch-v4
/// package: summed log probabilities of the tokens after the context
/// (joint encoding with the context, BOS), but every token prefix the
/// sentences share runs once, and the rest runs in batches. Sentences one
/// typing slip apart share everything before the slip, so a correction
/// costs little more than its own last few tokens.
///
/// Model queue, like the package itself.
nonisolated enum ChinesePrefixScoring {
    static let bos: Int32 = 2

    /// Summed log probabilities of each candidate after `context`, in order:
    /// the tokens every candidate shares run once as the prefix, then every
    /// candidate's rest through `score` in as few calls as the memory left
    /// allows (`VimeKVBatchLanguageModel.scores(after:rows:)`).
    ///
    /// Each sum starts where its candidate's tokens part from the context's,
    /// or, with `sharedStart`, where the first of them does, so that every
    /// sum covers the same context tokens (what reranking compares).
    static func scores(context: String, candidates: [String], sharedStart: Bool = false,
                       model: VimeKVBatchLanguageModel, tokenizer: VimeSentenceTokenizer,
                       cancelled: () -> Bool = { false }) throws -> [Double] {
        let (sequences, starts, shared) = try prepared(context: context, candidates: candidates,
                                                       sharedStart: sharedStart, tokenizer: tokenizer)
        let tokens = try rowScores(sequences, shared: shared, model: model, cancelled: cancelled)
        return zip(tokens, starts).map { values, start in
            // Entry i scores the token at position shared + i.
            values.enumerated().reduce(0.0) { $0 + ($1.offset + shared >= start ? Double($1.element) : 0) }
        }
    }

    /// The tokens of `text` after `context`, each with its log probability:
    /// the terms of the sum `scores` gives for `text`.
    static func tokenScores(context: String, text: String, model: VimeKVBatchLanguageModel,
                            tokenizer: VimeSentenceTokenizer) throws -> [(id: Int32, logProbability: Double)] {
        let (sequences, starts, shared) = try prepared(context: context, candidates: [text],
                                                       sharedStart: false, tokenizer: tokenizer)
        let values = try rowScores(sequences, shared: shared, model: model, cancelled: { false })[0]
        return values.enumerated().compactMap { offset, value in
            offset + shared >= starts[0] ? (sequences[0][offset + shared], Double(value)) : nil
        }
    }

    /// The shared tokens but the last as the prefix; each row starts with that last one.
    private static func rowScores(_ sequences: [[Int32]], shared: Int, model: VimeKVBatchLanguageModel,
                                  cancelled: () -> Bool) throws -> [[Float]] {
        let prefix = try model.prefix(Array(sequences[0][..<(shared - 1)]))
        return try model.scores(after: prefix, rows: sequences.map { Array($0[(shared - 1)...]) }, cancelled: cancelled)
    }

    /// Each candidate's tokens after BOS and the context, encoded jointly;
    /// where each one's scored part starts; and the length of the prefix
    /// every sequence shares, up to the earliest scored token. A candidate
    /// that does not decode back to itself, or holds one of the three-task
    /// model's markers, makes the whole call ineligible.
    private static func prepared(context: String, candidates: [String], sharedStart: Bool,
                                 tokenizer: VimeSentenceTokenizer) throws
        -> (sequences: [[Int32]], starts: [Int], shared: Int) {
        guard !candidates.isEmpty, candidates.allSatisfy({ !$0.isEmpty })
        else { throw VimeLanguageModel.Failure.ineligible }
        func encode(_ text: String) throws -> [Int32] {
            guard !text.isEmpty else { return [] }
            let ids = try tokenizer.encode(text)
            guard try tokenizer.decode(ids).utf8.elementsEqual(text.utf8),
                  !ids.contains(where: ChineseLanguageModel.reservedTokens.contains)
            else { throw VimeLanguageModel.Failure.ineligible }
            return ids
        }
        let contextIDs = [bos] + (try encode(context))
        let sequences = try candidates.map { [bos] + (try encode(context + $0)) }
        // Each candidate's own scored part starts where it parts from the context.
        var starts = sequences.map { sequence in
            var common = 0
            while common < min(contextIDs.count, sequence.count), contextIDs[common] == sequence[common] { common += 1 }
            return common
        }
        if sharedStart { starts = Array(repeating: starts.min()!, count: starts.count) }
        guard zip(sequences, starts).allSatisfy({ $1 >= 1 && $0.count > $1 }),
              sequences.allSatisfy({ $0.count <= VimeKVLanguageModel.contextLength })
        else { throw VimeLanguageModel.Failure.ineligible }
        // The prompt: what every sequence shares, up to the earliest scored token.
        var shared = starts.min()!
        for length in 1...shared where !sequences.allSatisfy({ $0[length - 1] == sequences[0][length - 1] }) {
            shared = length - 1; break
        }
        guard shared >= 1 else { throw VimeLanguageModel.Failure.ineligible }
        return (sequences, starts, shared)
    }
}
