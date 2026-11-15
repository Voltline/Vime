import Foundation
import Accelerate

/// The bucketed beam search of `ChineseConstrainedGeneration`, kept across
/// keystrokes, for lm mode (task mode puts the keys in the prompt, so
/// nothing carries over).
///
/// Forward only: a token may end at any key it spells, whether or not the
/// keys after it can be spelled, so the bucket of key `p` depends on the first
/// `p` keys alone. Each new key then costs one batched call — the best of the
/// previous last bucket run through the model — and the tokens that end
/// exactly at the new key are scored from the hypotheses already run within
/// the longest token's reach. Each run hypothesis keeps the log
/// probabilities of the tokens that can follow its key (those whose first
/// character has a spelling starting with that letter).
///
/// A change of keys keeps everything up to the first key that differs (an
/// apostrophe counts), so a backspace goes back to what that key had with no
/// model call. Work is done one key at a time; a cancelled update keeps the
/// keys it finished and the next update goes on from there.
///
/// Confined to the model queue.
nonisolated final class ChineseIncrementalGeneration<Model: ChineseScoringModel> {
    typealias Generation = ChineseConstrainedGeneration

    /// Scored, waiting in the bucket of the keys it has used; its last token
    /// has not gone through the model yet.
    private struct Entry {
        let tokens: [Int32]
        let score: Double
        /// The state before the last token; nil for the root.
        let parent: Model.State?
    }

    /// A hypothesis that went through the model, and what may follow it.
    private struct Node {
        let tokens: [Int32]
        let score: Double
        /// The letter it was run for; nil for a root that keeps every token.
        let letter: UInt8?
        /// The state after its tokens, for its children.
        let state: Model.State
        /// Log probabilities aligned to `vocabulary.byLetter[letter]` (all tokens for the root).
        let logProbabilities: [Float]
    }

    let model: Model
    let vocabulary: Generation.Vocabulary
    let lexicon: ChinesePinyinLexicon
    let prompt: [Int32]
    let parameters: Generation.Parameters

    private var letters: [UInt8] = []
    private var breaks: [Bool] = []
    /// Buckets `0...settled` are final for `letters`.
    private var buckets: [[Entry]] = [[Entry(tokens: [], score: 0, parent: nil)]]
    private var settled = 0
    /// `nodes[p]`: bucket `p` run through the model (the root at 0).
    private var nodes: [[Node]] = []

    /// Model calls so far, for tests and measurements: the prompt, then one per batch.
    private(set) var calls = 0
    /// Seconds in the model (with any log-softmax and picking), and in settling buckets.
    private(set) var modelSeconds = 0.0
    private(set) var settleSeconds = 0.0

    init(model: Model, vocabulary: Generation.Vocabulary, lexicon: ChinesePinyinLexicon, prompt: [Int32],
         parameters: Generation.Parameters = Generation.Parameters()) throws {
        guard !prompt.isEmpty, prompt.count < parameters.maximumLength else { throw Generation.Failure.prompt }
        self.model = model; self.vocabulary = vocabulary; self.lexicon = lexicon
        self.prompt = prompt; self.parameters = parameters
    }

    /// The best `parameters.count` distinct sentences that spell `keys`, best
    /// first; empty when none does. Throws `Failure.cancelled` (keeping the
    /// keys finished so far) as soon as `cancelled` says so.
    func update(_ keys: ChinesePinyinKeys, cancelled: () -> Bool = { false }) throws -> [Generation.Result] {
        guard parameters.beam > 0, parameters.count > 0 else { return [] }
        var common = 0
        while common < min(letters.count, keys.count), letters[common] == keys.letters[common],
              breaks[common] == keys.breaks[common] { common += 1 }
        settled = min(settled, common)
        buckets.removeSubrange((settled + 1)...)
        // The node at `settled` stays: it is run again only if its letter changed.
        if nodes.count > settled + 1 { nodes.removeSubrange((settled + 1)...) }
        letters = keys.letters; breaks = keys.breaks

        let spans = Spans(keys: keys, lexicon: lexicon, vocabulary: vocabulary)
        while settled < keys.count {
            if cancelled() { throw Generation.Failure.cancelled }
            try run(settled)
            let started = ProcessInfo.processInfo.systemUptime
            settle(settled + 1, spans: spans)
            settleSeconds += ProcessInfo.processInfo.systemUptime - started
            settled += 1
        }

        var finished: [String: Generation.Result] = [:]
        for entry in buckets[keys.count] {
            let text = String(String.UnicodeScalarView(entry.tokens.flatMap { vocabulary.characters[Int($0)] }))
            if let known = finished[text], known.score >= entry.score { continue }
            finished[text] = Generation.Result(text: text, tokens: entry.tokens, score: entry.score)
        }
        return finished.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.tokens.lexicographicallyPrecedes($1.tokens)
        }.prefix(parameters.count).map { $0 }
    }

    /// Makes `nodes[position]` hold bucket `position` run for its letter.
    private func run(_ position: Int) throws {
        let letter = letters[position]
        if position == 0 {
            // The root keeps every token when the model can score them all;
            // otherwise those of the first letter, run again when it changes.
            if let root = nodes.first?.first, root.letter == nil || root.letter == letter { return }
            let rootLetter = model.scoresEveryToken ? nil : letter
            let started = ProcessInfo.processInfo.systemUptime
            let step = try model.start(prompt, allowed: rootLetter.map { vocabulary.byLetter[Int($0) - 97] })
            modelSeconds += ProcessInfo.processInfo.systemUptime - started
            calls += 1
            nodes = [[Node(tokens: [], score: 0, letter: rootLetter, state: step.state,
                           logProbabilities: step.logProbabilities)]]
            return
        }
        if nodes.count > position {
            // Nothing to run does not depend on the letter.
            if nodes[position].first.map({ $0.letter == letter }) ?? true { return }
            nodes.removeSubrange(position...)
        }
        let room = parameters.maximumLength - prompt.count
        let runnable = buckets[position].filter { $0.tokens.count < room }
        guard !runnable.isEmpty else { nodes.append([]); return }
        let started = ProcessInfo.processInfo.systemUptime
        let steps = try model.extend(runnable.map { ($0.parent!, $0.tokens.last!) },
                                     allowed: vocabulary.byLetter[Int(letter) - 97])
        modelSeconds += ProcessInfo.processInfo.systemUptime - started
        calls += 1
        nodes.append(zip(runnable, steps).map { entry, step in
            Node(tokens: entry.tokens, score: entry.score, letter: letter, state: step.state,
                 logProbabilities: step.logProbabilities)
        })
    }

    /// Fills bucket `end` from every node within reach.
    private func settle(_ end: Int, spans: Spans) {
        var best: [[Int32]: Entry] = [:]
        for start in max(0, end - vocabulary.maximumSpan)..<end {
            let tokens = spans.tokens(from: start, to: end)
            guard !tokens.isEmpty else { continue }
            for node in nodes[start] {
                let state = node.state
                let index = node.letter.map { vocabulary.letterIndex[Int($0) - 97] }
                for token in tokens {
                    let position = index.map { Int($0[Int(token)]) } ?? Int(token)
                    let score = node.score + Double(node.logProbabilities[position])
                    guard score.isFinite else { continue }
                    let sequence = node.tokens + [token]
                    if let known = best[sequence], known.score >= score { continue }
                    best[sequence] = Entry(tokens: sequence, score: score, parent: state)
                }
            }
        }
        buckets.append(best.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.tokens.lexicographicallyPrecedes($1.tokens)
        }.prefix(parameters.beam).map { $0 })
    }

    /// The tokens that spell exactly the keys from one position to another,
    /// for one set of keys.
    private final class Spans {
        let keys: ChinesePinyinKeys
        let lexicon: ChinesePinyinLexicon
        let vocabulary: Generation.Vocabulary
        private var ends: [Int: [Unicode.Scalar: [Int]]] = [:]
        private var firsts: [Int: [Unicode.Scalar]] = [:]
        init(keys: ChinesePinyinKeys, lexicon: ChinesePinyinLexicon, vocabulary: Generation.Vocabulary) {
            self.keys = keys; self.lexicon = lexicon; self.vocabulary = vocabulary
        }

        private func ends(of character: Unicode.Scalar, from start: Int) -> [Int] {
            if let known = ends[start]?[character] { return known }
            var found: [Int] = []
            for spelling in lexicon.spellings(of: character)
            where keys.matches(spelling, at: start) && !found.contains(start + spelling.count) {
                found.append(start + spelling.count)
            }
            ends[start, default: [:]][character] = found
            return found
        }

        /// Characters with a spelling typed from `start`.
        private func firsts(from start: Int) -> [Unicode.Scalar] {
            if let known = firsts[start] { return known }
            var found: [Unicode.Scalar] = []
            var seen = Set<Unicode.Scalar>()
            for spelling in lexicon.inventory where keys.matches(spelling, at: start) {
                for character in lexicon.characters(spelled: spelling) where seen.insert(character).inserted {
                    found.append(character)
                }
            }
            firsts[start] = found
            return found
        }

        func tokens(from start: Int, to end: Int) -> [Int32] {
            var found: [Int32] = []
            for character in firsts(from: start) {
                for token in vocabulary.tokens(startingWith: character) where reaches(token, from: start, to: end) {
                    found.append(token)
                }
            }
            return found.sorted()
        }

        private func reaches(_ token: Int32, from start: Int, to end: Int) -> Bool {
            var positions = [start]
            for character in vocabulary.characters[Int(token)] {
                var next: [Int] = []
                for position in positions {
                    for to in ends(of: character, from: position) where to <= end && !next.contains(to) { next.append(to) }
                }
                guard !next.isEmpty else { return false }
                positions = next
            }
            return positions.contains(end)
        }
    }
}
