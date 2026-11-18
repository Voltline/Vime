import Foundation

/// The reranking scores of many sentences at once on the batched KV package:
/// the same sums `VimeLanguageModel.scores` gives (joint encoding with the
/// context, BOS, log probabilities of the tokens after the context), but
/// every token prefix the sentences share runs once, and each depth runs in
/// batches. Sentences one typing slip apart share everything before the slip,
/// so a correction costs little more than its own last few tokens.
///
/// Model queue, like the package itself.
nonisolated enum ChinesePrefixScoring {
    static let bos: Int32 = 2

    /// Summed log probabilities of each candidate after `context`, in order,
    /// on the kvbatch-v3 package: the tokens every candidate shares run once
    /// as the prefix, then every candidate's rest through `score` in as few
    /// calls as the memory left allows (`VimeKVBatchLanguageModel.scores(after:rows:)`).
    /// A candidate whose sum ends at or below its `floor` scores -infinity.
    static func scores(context: String, candidates: [String], floors: [Double]? = nil,
                       model: VimeKVBatchLanguageModel, tokenizer: VimeSentenceTokenizer,
                       cancelled: () -> Bool = { false }) throws -> [Double] {
        let (sequences, starts, shared) = try prepared(context: context, candidates: candidates, floors: floors,
                                                       tokenizer: tokenizer)
        // The prefix holds the shared tokens but the last, which starts every row.
        let prefix = try model.prefix(Array(sequences[0][..<(shared - 1)]))
        let rows = sequences.map { Array($0[(shared - 1)...]) }
        let tokens = try model.scores(after: prefix, rows: rows, cancelled: cancelled)
        return zip(tokens, starts).enumerated().map { index, item in
            let (values, start) = item
            // Entry i scores the token at position shared + i.
            let sum = values.enumerated().reduce(0.0) { $0 + ($1.offset + shared >= start ? Double($1.element) : 0) }
            return floors.map { sum > $0[index] } ?? true ? sum : -.infinity
        }
    }

    /// The same sums on the sequence package, the fallback while v3 is
    /// measured on devices: a call for every 16 candidates' shared prefix
    /// and a few for the rest (`VimeKVSequenceLanguageModel.tokenScores`).
    /// `floors` as above, applied to the finished sums.
    static func scores(context: String, candidates: [String], floors: [Double]? = nil,
                       model: VimeKVSequenceLanguageModel, tokenizer: VimeSentenceTokenizer,
                       cancelled: () -> Bool = { false }) throws -> [Double] {
        let (sequences, starts, _) = try prepared(context: context, candidates: candidates, floors: floors,
                                                       tokenizer: tokenizer)
        // Token i of a sequence is scored by entry i - 1.
        let tokens = try model.tokenScores(sequences, cancelled: cancelled)
        return zip(tokens, starts).enumerated().map { index, item in
            let (values, start) = item
            let sum = values.enumerated().reduce(0.0) { $0 + ($1.offset + 1 >= start ? Double($1.element) : 0) }
            return floors.map { sum > $0[index] } ?? true ? sum : -.infinity
        }
    }

    /// The package the sums run on: kvbatch-v3, or the sequence package
    /// when v3 cannot load.
    enum Model {
        case batch(VimeKVBatchLanguageModel)
        case sequence(VimeKVSequenceLanguageModel)
    }

    static func scores(context: String, candidates: [String], floors: [Double]? = nil, model: Model,
                       tokenizer: VimeSentenceTokenizer, cancelled: () -> Bool = { false }) throws -> [Double] {
        switch model {
        case .batch(let batch):
            try scores(context: context, candidates: candidates, floors: floors, model: batch, tokenizer: tokenizer,
                       cancelled: cancelled)
        case .sequence(let sequence):
            try scores(context: context, candidates: candidates, floors: floors, model: sequence, tokenizer: tokenizer,
                       cancelled: cancelled)
        }
    }

    /// Each candidate's tokens after BOS and the context, encoded jointly;
    /// where each one's scored part starts; and the length of the prefix
    /// every sequence shares, up to the earliest scored token.
    private static func prepared(context: String, candidates: [String], floors: [Double]?,
                                 tokenizer: VimeSentenceTokenizer) throws
        -> (sequences: [[Int32]], starts: [Int], shared: Int) {
        guard !candidates.isEmpty, candidates.allSatisfy({ !$0.isEmpty }),
              floors.map({ $0.count == candidates.count }) ?? true
        else { throw VimeLanguageModel.Failure.ineligible }
        func encode(_ text: String) throws -> [Int32] {
            guard !text.isEmpty else { return [] }
            let ids = try tokenizer.encode(text)
            guard try tokenizer.decode(ids).utf8.elementsEqual(text.utf8) else { throw VimeLanguageModel.Failure.ineligible }
            return ids
        }
        let contextIDs = [bos] + (try encode(context))
        let sequences = try candidates.map { [bos] + (try encode(context + $0)) }
        // Each candidate's own scored part starts where it parts from the context.
        let starts = sequences.map { sequence in
            var common = 0
            while common < min(contextIDs.count, sequence.count), contextIDs[common] == sequence[common] { common += 1 }
            return common
        }
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
