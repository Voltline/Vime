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
    private final class Node {
        let token: Int32
        /// Position of `token` in the sequences through this node.
        let position: Int
        var children: [Int32: Node] = [:]
        /// The candidates whose sequences pass through this node.
        var members: [Int] = []
        var cache: VimeKVLanguageModel.Cache?
        weak var parent: Node?
        init(token: Int32, position: Int, parent: Node?) { self.token = token; self.position = position; self.parent = parent }
    }

    static let bos: Int32 = 2

    /// Summed log probabilities of each candidate after `context`, in order.
    ///
    /// A candidate whose sum is sure to end at or below its `floor` (log
    /// probabilities are never positive, so a partial sum only falls) stops
    /// there and scores -infinity; the others score exactly.
    static func scores(context: String, candidates: [String], floors: [Double]? = nil,
                       model: VimeKVBatchLanguageModel, tokenizer: VimeSentenceTokenizer,
                       cancelled: () -> Bool = { false }) throws -> [Double] {
        let (sequences, starts, shared) = try prepared(context: context, candidates: candidates, floors: floors,
                                                       tokenizer: tokenizer)
        return try trieScores(sequences: sequences, starts: starts, shared: shared, floors: floors, model: model,
                              cancelled: cancelled)
    }

    /// The same sums on the sequence package: a call for every 16
    /// candidates' shared prefix and a few for the rest, however long they are (`VimeKVSequenceLanguageModel.tokenScores`).
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

    private static func trieScores(sequences: [[Int32]], starts: [Int], shared: Int, floors: [Double]?,
                                   model: VimeKVBatchLanguageModel, cancelled: () -> Bool) throws -> [Double] {
        let candidates = sequences
        let root = Node(token: sequences[0][shared - 1], position: shared - 1, parent: nil)
        root.members = Array(candidates.indices)
        for (index, sequence) in sequences.enumerated() {
            var node = root
            for position in shared..<sequence.count {
                let token = sequence[position]
                let child = node.children[token] ?? Node(token: token, position: position, parent: node)
                node.children[token] = child
                child.members.append(index)
                node = child
            }
        }

        var sums = [Double](repeating: 0, count: candidates.count)
        var alive = [Bool](repeating: true, count: candidates.count)
        func assign(_ parent: Node, _ allowed: [Int32], _ values: [Float]) {
            let index = Dictionary(uniqueKeysWithValues: allowed.enumerated().map { ($1, $0) })
            for (token, child) in parent.children {
                let value = Double(values[index[token]!])
                for member in child.members where alive[member] && child.position >= starts[member] {
                    sums[member] += value
                    if let floors, sums[member] <= floors[member] { alive[member] = false }
                }
            }
        }
        let first = Array(root.children.keys).sorted()
        let prompt = try model.prompt(Array(sequences[0][..<shared]), allowed: first)
        assign(root, first, prompt.logProbabilities)
        root.cache = prompt.cache

        var level = Array(root.children.values)
        while !level.isEmpty {
            guard !cancelled() else { throw VimeLanguageModel.Failure.cancelled }
            // A node runs only while a candidate through it is still in the running.
            let parents = level.filter { node in !node.children.isEmpty && node.members.contains { alive[$0] } }
            var index = 0
            while index < parents.count {
                // As many rows as fit one call: the batch size, and the allowed ids together.
                var batch: [Node] = []
                var allowed = Set<Int32>()
                while index < parents.count, batch.count < model.maximumBatch {
                    let next = allowed.union(parents[index].children.keys)
                    guard next.count <= VimeKVBatchLanguageModel.maximumAllowed || batch.isEmpty else { break }
                    allowed = next; batch.append(parents[index]); index += 1
                }
                let ids = allowed.sorted()
                let items = try batch.map { node -> (cache: VimeKVLanguageModel.Cache?, token: Int32) in
                    guard let cache = node.parent?.cache else { throw VimeLanguageModel.Failure.tensor }
                    return (cache, node.token)
                }
                let results = try model.scores(items, allowed: ids)
                for (node, result) in zip(batch, results) {
                    assign(node, ids, result.logProbabilities)
                    node.cache = result.cache
                }
            }
            level = parents.flatMap { Array($0.children.values) }
        }
        return zip(sums, alive).map { $1 ? $0 : -.infinity }
    }
}
