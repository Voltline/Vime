import Foundation
import Accelerate

/// What the incremental search needs: the log probabilities of chosen
/// tokens after the prompt, then after one more token on top of any earlier state.
protocol ChineseScoringModel: AnyObject {
    associatedtype State
    /// Whether `start` scores every token when `allowed` is nil.
    var scoresEveryToken: Bool { get }
    /// Log probabilities of `allowed` (nil: every token) after `prompt`.
    func start(_ prompt: [Int32], allowed: [Int32]?) throws -> (logProbabilities: [Float], state: State)
    /// Log probabilities of `allowed` after each state and its token, in order.
    func extend(_ items: [(state: State, token: Int32)], allowed: [Int32]) throws
        -> [(logProbabilities: [Float], state: State)]
}

/// A causal language model that generation can step through: the prompt
/// once, then one token at a time on top of any earlier state.
protocol ChineseGenerationModel: ChineseScoringModel {
    var vocabularySize: Int { get }
    /// Unnormalized logits of the token after `prompt`.
    func start(_ prompt: [Int32]) throws -> (logits: [Float], state: State)
    /// Unnormalized logits of the token after `token`, which follows `state`.
    func extend(_ state: State, with token: Int32) throws -> (logits: [Float], state: State)
    /// The same for several states at once, in order; models that batch override it.
    func extend(_ items: [(state: State, token: Int32)]) throws -> [(logits: [Float], state: State)]
}

extension ChineseGenerationModel {
    func extend(_ items: [(state: State, token: Int32)]) throws -> [(logits: [Float], state: State)] {
        try items.map { try extend($0.state, with: $0.token) }
    }
    var scoresEveryToken: Bool { true }
    func start(_ prompt: [Int32], allowed: [Int32]?) throws -> (logProbabilities: [Float], state: State) {
        let step = try start(prompt)
        return (try ChineseConstrainedGeneration.logProbabilities(step.logits, of: allowed), step.state)
    }
    func extend(_ items: [(state: State, token: Int32)], allowed: [Int32]) throws
        -> [(logProbabilities: [Float], state: State)] {
        try extend(items).map { (try ChineseConstrainedGeneration.logProbabilities($0.logits, of: allowed), $0.state) }
    }
}

/// The zh-v1 batched KV package (kvbatch-v3) for the incremental search:
/// the prompt in one call, each bucket in calls of up to `maximumBatch` rows
/// scoring only the tokens allowed there. It returns no full logits, so the
/// root is scored per first letter (`scoresEveryToken` is false).
nonisolated final class ChineseKVGenerator: ChineseScoringModel {
    typealias State = VimeKVLanguageModel.Cache
    let batch: VimeKVBatchLanguageModel
    var scoresEveryToken: Bool { false }
    init(batch: VimeKVBatchLanguageModel) { self.batch = batch }

    func start(_ ids: [Int32], allowed: [Int32]?) throws -> (logProbabilities: [Float], state: State) {
        guard let allowed else { throw VimeLanguageModel.Failure.tensor }
        // The package needs at least one id; nothing to score still gives the state.
        let step = try batch.prompt(ids, allowed: allowed.isEmpty ? [0] : allowed)
        return (allowed.isEmpty ? [] : step.logProbabilities, step.cache)
    }
    func extend(_ items: [(state: State, token: Int32)], allowed: [Int32]) throws
        -> [(logProbabilities: [Float], state: State)] {
        var results: [(logProbabilities: [Float], state: State)] = []
        results.reserveCapacity(items.count)
        var start = 0
        while start < items.count {
            let chunk = items[start..<min(items.count, start + batch.maximumBatch)]
            results += try batch.scores(chunk.map { (cache: Optional($0.state), token: $0.token) },
                                        allowed: allowed.isEmpty ? [0] : allowed)
                .map { (allowed.isEmpty ? [] : $0.logProbabilities, $0.cache) }
            start += chunk.count
        }
        return results
    }
}

/// Beam search for whole sentences that spell exactly the keys typed.
///
/// Every output token is Chinese characters only, each in Vime's pinyin
/// dictionary, and together they spell the keys: each character by one of
/// its syllables or by an initial (its first letter, or zh, ch, sh). A token
/// may spell the keys in more than one way, so a hypothesis is a token
/// sequence and the number of keys it has used. Which key positions can
/// still be spelled to the end is worked out first, from the end backwards,
/// and only those positions are ever reached.
///
/// Independent of the model: the prompt decides what it does.
nonisolated enum ChineseConstrainedGeneration {
    enum Mode: Sendable {
        /// The three-task model: [BOS, CTX] context [READ] keys [OUT]; a
        /// sentence ends with the model's EOS, whose probability counts.
        case task
        /// A plain language model continuing the context; nothing is added at the end.
        case lm
    }

    struct Parameters: Sendable {
        var beam = 16
        /// Distinct sentences returned.
        var count = 10
        /// Prompt and output together.
        var maximumLength = VimeLanguageModel.contextLength
    }

    struct Result: Equatable, Sendable {
        let text: String
        let tokens: [Int32]
        /// Summed log probability of the tokens (and EOS in task mode).
        let score: Double
    }

    enum Failure: Error, Equatable { case keys, unreachable, prompt, cancelled }

    static let bos: Int32 = 2, eos: Int32 = 3, contextMarker: Int32 = 4, readingMarker: Int32 = 5, outputMarker: Int32 = 6

    /// The tokens generation may use: those made only of dictionary characters.
    final class Vocabulary: @unchecked Sendable {
        /// The characters of each token, empty when generation may not use it.
        let characters: [[Unicode.Scalar]]
        private let byFirst: [Unicode.Scalar: [Int32]]
        var usableCount: Int { characters.lazy.filter { !$0.isEmpty }.count }

        init(texts: [String], lexicon: ChinesePinyinLexicon) {
            var characters = [[Unicode.Scalar]](repeating: [], count: texts.count)
            var byFirst: [Unicode.Scalar: [Int32]] = [:]
            for (id, text) in texts.enumerated() {
                let scalars = Array(text.unicodeScalars)
                guard !scalars.isEmpty, scalars.allSatisfy({ $0.properties.isIdeographic && lexicon.contains($0) }),
                      Self.spellingCount(scalars, lexicon: lexicon) <= Self.maximumSpellings
                else { continue }
                characters[id] = scalars
                byFirst[scalars[0], default: []].append(Int32(id))
            }
            self.characters = characters
            self.byFirst = byFirst
            var span = 0
            var byLetter = [[Int32]](repeating: [], count: 26)
            for (id, scalars) in characters.enumerated() where !scalars.isEmpty {
                span = max(span, scalars.reduce(0) { $0 + (lexicon.spellings(of: $1).map(\.count).max() ?? 0) })
                for letter in Set(lexicon.spellings(of: scalars[0]).compactMap(\.first)) where (97...122).contains(letter) {
                    byLetter[Int(letter - 97)].append(Int32(id))
                }
            }
            maximumSpan = span
            self.byLetter = byLetter
            letterIndex = byLetter.map { tokens in
                var index = [Int32](repeating: -1, count: texts.count)
                for (position, token) in tokens.enumerated() { index[Int(token)] = Int32(position) }
                return index
            }
        }

        /// The most keys one usable token can spell.
        let maximumSpan: Int
        /// Usable tokens whose first character has a spelling that starts with
        /// each letter (a…z), by id; the only tokens that can follow that key.
        let byLetter: [[Int32]]
        /// Where each token is in `byLetter[letter]`, −1 when absent.
        let letterIndex: [[Int32]]

        /// Each token decoded on its own; special and control tokens never qualify.
        convenience init(tokenizer: VimeSentenceTokenizer, size: Int, lexicon: ChinesePinyinLexicon) {
            let texts = (0..<size).map { id in id < 8 ? "" : ((try? tokenizer.decode([Int32(id)])) ?? "") }
            self.init(texts: texts, lexicon: lexicon)
        }

        func tokens(startingWith character: Unicode.Scalar) -> [Int32] { byFirst[character] ?? [] }

        /// Tokens with more ways to spell them than this are left out, as VimeML does.
        static let maximumSpellings = 4096
        static func spellingCount(_ characters: [Unicode.Scalar], lexicon: ChinesePinyinLexicon) -> Int {
            var count = 1
            for character in characters {
                count *= lexicon.spellings(of: character).count
                if count > maximumSpellings { break }
            }
            return count
        }
    }

    /// task: [BOS, CTX] + context + [READ] + keys + [OUT]; lm: [BOS] + context.
    /// The context must encode and decode back exactly, without markers.
    static func prompt(_ mode: Mode, context: String, keys: String, tokenizer: VimeSentenceTokenizer) throws -> [Int32] {
        func encode(_ text: String) throws -> [Int32] {
            guard !text.isEmpty else { return [] }
            let ids = try tokenizer.encode(text)
            guard try tokenizer.decode(ids).utf8.elementsEqual(text.utf8),
                  !ids.contains(where: { (bos...outputMarker).contains($0) }) else { throw Failure.prompt }
            return ids
        }
        switch mode {
        case .task: return [bos, contextMarker] + (try encode(context)) + [readingMarker] + (try encode(keys)) + [outputMarker]
        case .lm: return [bos] + (try encode(context))
        }
    }

    /// Which letter positions can still be spelled through to the end:
    /// `result[i]` for the letters from `i` on (`result[count]` is true).
    static func reachable(_ keys: ChinesePinyinKeys, lexicon: ChinesePinyinLexicon) -> [Bool] {
        var reachable = [Bool](repeating: false, count: keys.count + 1)
        reachable[keys.count] = true
        for start in stride(from: keys.count - 1, through: 0, by: -1) {
            reachable[start] = lexicon.inventory.contains {
                start + $0.count <= keys.count && reachable[start + $0.count] && keys.matches($0, at: start)
            }
        }
        return reachable
    }

    /// The tokens that can follow letter `start` and where each can end,
    /// only at reachable positions. A token can end in several places.
    final class Spelling {
        let keys: ChinesePinyinKeys
        let reachable: [Bool]
        private let lexicon: ChinesePinyinLexicon
        private let vocabulary: Vocabulary
        private var ends: [Int: [Unicode.Scalar: [Int]]] = [:]
        private var steps: [Int: [(token: Int32, end: Int)]] = [:]

        init(keys: ChinesePinyinKeys, lexicon: ChinesePinyinLexicon, vocabulary: Vocabulary) {
            self.keys = keys
            self.lexicon = lexicon
            self.vocabulary = vocabulary
            reachable = ChineseConstrainedGeneration.reachable(keys, lexicon: lexicon)
        }

        /// Where `character` typed from `start` can end.
        func ends(of character: Unicode.Scalar, from start: Int) -> [Int] {
            if let known = ends[start]?[character] { return known }
            var found: [Int] = []
            for spelling in lexicon.spellings(of: character) {
                let end = start + spelling.count
                if end <= keys.count, reachable[end], keys.matches(spelling, at: start), !found.contains(end) {
                    found.append(end)
                }
            }
            found.sort()
            ends[start, default: [:]][character] = found
            return found
        }

        /// Where a token of these characters typed from `start` can end.
        func ends(of characters: [Unicode.Scalar], from start: Int) -> [Int] {
            var positions = [start]
            for character in characters {
                var next: [Int] = []
                for position in positions {
                    for end in ends(of: character, from: position) where !next.contains(end) { next.append(end) }
                }
                guard !next.isEmpty else { return [] }
                positions = next
            }
            return positions.sorted()
        }

        func steps(from start: Int) -> [(token: Int32, end: Int)] {
            if let known = steps[start] { return known }
            var firsts: [Unicode.Scalar] = []
            var seen = Set<Unicode.Scalar>()
            for spelling in lexicon.inventory where start + spelling.count <= keys.count
                && reachable[start + spelling.count] && keys.matches(spelling, at: start) {
                for character in lexicon.characters(spelled: spelling) where seen.insert(character).inserted {
                    firsts.append(character)
                }
            }
            var found: [(token: Int32, end: Int)] = []
            for character in firsts {
                for token in vocabulary.tokens(startingWith: character) {
                    for end in ends(of: vocabulary.characters[Int(token)], from: start) { found.append((token, end)) }
                }
            }
            found.sort { $0.token != $1.token ? $0.token < $1.token : $0.end < $1.end }
            steps[start] = found
            return found
        }
    }

    /// A hypothesis waiting in the bucket of the keys it has used: its last
    /// token is scored but not yet run through the model.
    private struct Pending<State> {
        let tokens: [Int32]
        let score: Double
        /// The state before the last token (the prompt's for the root).
        let state: State?
    }

    /// The hypotheses that used the same number of keys. Only the best
    /// `beam` distinct token sequences matter, so it trims itself as it
    /// fills, and refuses what cannot beat what it already keeps.
    private struct Bucket<State> {
        let beam: Int
        private var entries: [[Int32]: Pending<State>] = [:]
        /// The `beam`-th best score kept at the last trim (−∞ before).
        private var kept = -Double.infinity
        init(beam: Int) { self.beam = beam }
        var isEmpty: Bool { entries.isEmpty }

        mutating func add(_ tokens: [Int32], _ token: Int32, score: Double, state: State) {
            guard score >= kept else { return }
            let tokens = tokens + [token]
            if let known = entries[tokens], known.score >= score { return }
            entries[tokens] = Pending(tokens: tokens, score: score, state: state)
            if entries.count >= 4 * beam { trim() }
        }

        /// What a newcomer must reach to be kept: −∞ until `beam` are in.
        mutating func floor() -> Double {
            if entries.count >= beam { trim() }
            return entries.count >= beam ? kept : -.infinity
        }

        func best() -> [Pending<State>] {
            entries.values.sorted(by: Self.better).prefix(beam).map { $0 }
        }

        private mutating func trim() {
            let best = best()
            guard best.count >= beam else { return }
            if entries.count > beam { entries = Dictionary(uniqueKeysWithValues: best.map { ($0.tokens, $0) }) }
            kept = best[beam - 1].score
        }

        static func better(_ a: Pending<State>, _ b: Pending<State>) -> Bool {
            a.score != b.score ? a.score > b.score : a.tokens.lexicographicallyPrecedes(b.tokens)
        }
    }

    /// The best `parameters.count` distinct sentences, best first.
    ///
    /// Hypotheses are bucketed by the number of keys they have used and
    /// compete only within their bucket, so a token that spends many keys
    /// at once is never crowded out by one-letter initials. Buckets run in
    /// key order: each keeps its best `beam` token sequences, runs them
    /// through the model and scores their continuations into the buckets
    /// where those end. The bucket at the last key holds the sentences.
    ///
    /// Throws `Failure.unreachable` when no sentence can spell the keys and
    /// `Failure.cancelled` as soon as `cancelled` says so.
    static func generate<Model: ChineseGenerationModel>(
        model: Model, vocabulary: Vocabulary, lexicon: ChinesePinyinLexicon, keys: ChinesePinyinKeys,
        prompt: [Int32], mode: Mode, parameters: Parameters = Parameters(),
        cancelled: () -> Bool = { false }
    ) throws -> [Result] {
        guard parameters.beam > 0, parameters.count > 0 else { return [] }
        guard !prompt.isEmpty, prompt.count < parameters.maximumLength else { throw Failure.prompt }
        let spelling = Spelling(keys: keys, lexicon: lexicon, vocabulary: vocabulary)
        guard spelling.reachable[0] else { throw Failure.unreachable }
        func check() throws { if cancelled() { throw Failure.cancelled } }
        let n = keys.count
        // Room for a token after these: forwarding needs the prompt and every token in the cache.
        let room = parameters.maximumLength - prompt.count

        var buckets = [Bucket<Model.State>](repeating: Bucket(beam: parameters.beam), count: n + 1)
        try check()
        var rootStep: (logits: [Float], state: Model.State)? = try model.start(prompt)
        for position in 0..<n where position == 0 || !buckets[position].isEmpty {
            let kept = position == 0 ? [Pending<Model.State>(tokens: [], score: 0, state: nil)] : buckets[position].best()
            buckets[position] = Bucket(beam: parameters.beam)
            let steps = spelling.steps(from: position)
            let ends = Set(steps.map(\.end))
            for hypothesis in kept {
                guard hypothesis.tokens.count < room else { continue }
                // Its continuations score below it: when every bucket they
                // could enter already holds `beam` better, running it changes nothing.
                if ends.allSatisfy({ buckets[$0].floor() > hypothesis.score }) { continue }
                try check()
                let step: (logits: [Float], state: Model.State)
                if let state = hypothesis.state, let last = hypothesis.tokens.last {
                    step = try model.extend(state, with: last)
                } else {
                    step = rootStep!; rootStep = nil
                }
                let normalizer = try logNormalizer(step.logits)
                for next in steps {
                    let score = hypothesis.score + Double(step.logits[Int(next.token)]) - normalizer
                    guard score.isFinite else { continue }
                    buckets[next.end].add(hypothesis.tokens, next.token, score: score, state: step.state)
                }
            }
        }

        // The last bucket: the sentences. In task mode each also needs the model's EOS.
        var finished: [String: Result] = [:]
        for hypothesis in buckets[n].best() {
            var score = hypothesis.score
            if mode == .task, let state = hypothesis.state, let last = hypothesis.tokens.last {
                try check()
                let step = try model.extend(state, with: last)
                score += Double(step.logits[Int(eos)]) - (try logNormalizer(step.logits))
            }
            let text = String(String.UnicodeScalarView(hypothesis.tokens.flatMap { vocabulary.characters[Int($0)] }))
            if let known = finished[text], known.score >= score { continue }
            finished[text] = Result(text: text, tokens: hypothesis.tokens, score: score)
        }
        return finished.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.tokens.lexicographicallyPrecedes($1.tokens)
        }.prefix(parameters.count).map { $0 }
    }

    /// log Σ exp(logits) in single precision, for the incremental search;
    /// throws when any logit is not finite.
    /// Log probabilities of `allowed` (nil: every token) from unnormalized logits.
    static func logProbabilities(_ logits: [Float], of allowed: [Int32]?) throws -> [Float] {
        var shift = -Float(try logNormalizerSingle(logits))
        guard let allowed else {
            var all = [Float](repeating: 0, count: logits.count)
            vDSP_vsadd(logits, 1, &shift, &all, 1, vDSP_Length(all.count))
            return all
        }
        return [Float](unsafeUninitializedCapacity: allowed.count) { target, initialized in
            logits.withUnsafeBufferPointer { logits in
                for (index, id) in allowed.enumerated() { target[index] = logits[Int(id)] + shift }
            }
            initialized = allowed.count
        }
    }

    static func logNormalizerSingle(_ logits: [Float]) throws -> Double {
        let count = vDSP_Length(logits.count)
        var maximum: Float = 0
        vDSP_maxv(logits, 1, &maximum, count)
        guard maximum.isFinite else { throw VimeLanguageModel.Failure.tensor }
        var shifted = [Float](repeating: 0, count: logits.count)
        var shift = -maximum
        vDSP_vsadd(logits, 1, &shift, &shifted, 1, count)
        var n = Int32(logits.count)
        var total: Float = 0
        shifted.withUnsafeMutableBufferPointer { buffer in
            vvexpf(buffer.baseAddress!, buffer.baseAddress!, &n)
            vDSP_sve(buffer.baseAddress!, 1, &total, count)
        }
        guard total.isFinite, total > 0 else { throw VimeLanguageModel.Failure.tensor }
        return Double(maximum) + log(Double(total))
    }

    /// log Σ exp(logits), in double precision.
    static func logNormalizer(_ logits: [Float]) throws -> Double {
        var values = [Double](repeating: 0, count: logits.count)
        vDSP_vspdp(logits, 1, &values, 1, vDSP_Length(logits.count))
        var maximum = 0.0
        vDSP_maxvD(values, 1, &maximum, vDSP_Length(values.count))
        guard maximum.isFinite else { throw VimeLanguageModel.Failure.tensor }
        var shift = -maximum
        vDSP_vsaddD(values, 1, &shift, &values, 1, vDSP_Length(values.count))
        var count = Int32(values.count)
        var total = 0.0
        values.withUnsafeMutableBufferPointer { buffer in
            vvexp(buffer.baseAddress!, buffer.baseAddress!, &count)
            vDSP_sveD(buffer.baseAddress!, 1, &total, vDSP_Length(buffer.count))
        }
        guard total.isFinite, total > 0 else { throw VimeLanguageModel.Failure.tensor }
        return maximum + log(total)
    }
}
