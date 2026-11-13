import Foundation
import os

/// Gives the model other sentences to weigh against Rime's.
///
/// Rime makes one sentence for a long input, so reordering its candidates
/// leaves the model nothing to choose. Here the model finds the characters of
/// Rime's sentence it believes least, and every word of the dictionary read
/// the same way may take the place of one of them; the model scores those
/// sentences, and a second round does the same from the best one. A sentence
/// replaces Rime's only when the model prefers it by a clear margin. Short of
/// time or memory, the second round is skipped.
nonisolated enum ChineseSentenceSwap {
    /// Characters per round whose neighbourhood is tried.
    static let weakCharacters = 2
    /// Longest word, in syllables, that may replace part of the sentence.
    static let longestWord = 4
    /// Dictionary words tried for each stretch of syllables.
    static let wordsPerSpan = 4
    /// Log probability a sentence must gain over Rime's to replace it.
    static let margin = 3.0
    /// Shortest sentence, in characters, worth trying.
    static let shortest = 3
    /// The search gives up after this long.
    static let budget: TimeInterval = 0.300
    /// The second round starts only when the first ended within this long.
    static let secondRoundStart: TimeInterval = 0.060
    /// The second round needs this much memory left to the process.
    static let secondRoundMemory = 48 * 1_048_576

    struct Job: Sendable, Equatable {
        /// Rime's first candidate, simplified.
        let sentence: String
        /// The input's syllables, one for each character of `sentence`.
        let syllables: [String]
        let context: String
    }

    /// A job for Rime's first candidate when it is a sentence of Chinese
    /// characters for the whole input, one syllable each.
    static func job(input: String, preedit: String, candidate: RimeCandidate?, context: String) -> Job? {
        guard let candidate, candidate.coversInput, !candidate.userPhrase else { return nil }
        let sentence = candidate.genuine
        guard sentence.count >= shortest,
              sentence.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }),
              let syllables = syllables(input: input, preedit: preedit), syllables.count == sentence.count else { return nil }
        return Job(sentence: sentence, syllables: syllables, context: context)
    }

    /// The input cut where Rime's preedit separates syllables. The preedit may
    /// spell a syllable differently (ü for v), never with another length.
    static func syllables(input: String, preedit: String) -> [String]? {
        let letters = input.filter { $0 != "'" }
        let pieces = preedit.split(whereSeparator: { $0 == " " || $0 == "'" })
        guard !pieces.isEmpty, pieces.allSatisfy({ $0.allSatisfy(\.isLetter) }),
              pieces.reduce(0, { $0 + $1.count }) == letters.count,
              letters.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        var rest = Substring(letters)
        return pieces.map { piece in
            defer { rest = rest.dropFirst(piece.count) }
            return String(rest.prefix(piece.count))
        }
    }

    /// The `count` lowest-scoring positions, lowest first.
    static func weakest(_ scores: [Double], count: Int = weakCharacters) -> [Int] {
        Array(scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] < scores[$1] : $0 < $1 }.prefix(count))
    }

    /// Stretches of up to `longestWord` syllables that include one of `positions`.
    static func spans(around positions: [Int], length: Int) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        for size in 1...longestWord {
            for start in 0...max(0, length - size) where start + size <= length {
                let span = start..<(start + size)
                if positions.contains(where: span.contains), !spans.contains(span) { spans.append(span) }
            }
        }
        return spans
    }

    /// `sentence` with each span replaced by each of its words, in order,
    /// leaving out the sentence itself and repeats.
    static func variants(of sentence: String, spans: [Range<Int>], words: (Range<Int>) -> [String]) -> [String] {
        let characters = Array(sentence)
        var seen: Set<String> = [sentence]
        var found: [String] = []
        for span in spans {
            for word in words(span) where word.count == span.count {
                let variant = String(characters[..<span.lowerBound]) + word + String(characters[span.upperBound...])
                if seen.insert(variant).inserted { found.append(variant) }
            }
        }
        return found
    }

    /// Words Rime has for a stretch of syllables: whole dictionary entries of
    /// one character per syllable, likeliest first.
    static func words(in candidates: [RimeCandidate], syllables: Int, allows: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return candidates.filter {
            $0.coversInput && !$0.sentence && $0.genuine.count == syllables
                && $0.genuine.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
                && allows($0.genuine) && seen.insert($0.genuine).inserted
        }.prefix(wordsPerSpan).map(\.genuine)
    }

    /// The models' search, abstracted so tests can drive it without Core ML or Rime.
    struct Scorer {
        var characters: (_ context: String, _ text: String) throws -> [Double]
        var sentences: (_ context: String, _ texts: [String]) throws -> [Double]
        var lookUp: (_ spellings: [String]) -> [[RimeCandidate]]
        var allows: (String) -> Bool
        var secondRound: () -> Bool
    }

    /// The sentence to show instead of Rime's, or nil to keep Rime's.
    static func search(_ job: Job, scorer: Scorer) throws -> String? {
        var cache: [Range<Int>: [String]] = [:]
        func fill(_ spans: [Range<Int>]) {
            let missing = spans.filter { cache[$0] == nil }
            guard !missing.isEmpty else { return }
            let found = scorer.lookUp(missing.map { job.syllables[$0].joined() })
            for (span, candidates) in zip(missing, found) {
                cache[span] = words(in: candidates, syllables: span.count, allows: scorer.allows)
            }
        }
        func round(from sentence: String, scored: Set<String>) throws -> [(String, Double)] {
            let weak = weakest(try scorer.characters(job.context, sentence))
            let spans = spans(around: weak, length: job.syllables.count)
            fill(spans)
            let found = variants(of: sentence, spans: spans) { cache[$0] ?? [] }
                .filter { !scored.contains($0) && scorer.allows($0) }
            guard !found.isEmpty else { return [] }
            return Array(zip(found, try scorer.sentences(job.context, found)))
        }
        let base = try scorer.sentences(job.context, [job.sentence])[0]
        var scored: Set<String> = [job.sentence]
        var best = (job.sentence, base)
        for (text, score) in try round(from: job.sentence, scored: scored) {
            scored.insert(text)
            if score > best.1 { best = (text, score) }
        }
        if best.0 != job.sentence, scorer.secondRound() {
            for (text, score) in try round(from: best.0, scored: scored) where score > best.1 { best = (text, score) }
        }
        return best.1 > base + margin ? best.0 : nil
    }

    /// Searches on the model queue and reports on the main queue: nil when
    /// Rime's sentence stays, the model is not ready, or time runs out.
    static func improve(_ job: Job, engine: RimeEngine, request: ChineseCandidateRanking.Request,
                        allows: @escaping @Sendable (String) -> Bool,
                        completion: @escaping @MainActor (String?) -> Void) {
        let storage = JapaneseCandidateWorker.LanguageModelStorage.shared
        let warm = storage.isReady(for: .chinese)
        JapaneseCandidateWorker.modelQueue.async {
            var result: String?
            let started = ProcessInfo.processInfo.systemUptime
            let cancelled = { request.isCancelled || storage.isSuspended }
            // A cold model loads here for later compositions but does not search now.
            if !cancelled(), let model = storage.model(for: .chinese), warm {
                let scorer = Scorer(
                    characters: { try model.characterScores(context: $0, text: $1, cancelled: cancelled) },
                    sentences: { try model.scores(context: $0, candidates: $1, cancelled: cancelled) },
                    lookUp: { cancelled() ? $0.map { _ in [] } : engine.lookUpAndWait($0, limit: 12) },
                    allows: allows,
                    secondRound: {
                        ProcessInfo.processInfo.systemUptime - started < secondRoundStart
                            && os_proc_available_memory() >= secondRoundMemory
                    })
                result = try? search(job, scorer: scorer)
                if cancelled() { result = nil }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }
}
