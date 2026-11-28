import Foundation

/// The Japanese keyboard's `vimeml-ja-v6-20m` model: a kvbatch-v4 fp32kv
/// Core ML package (`TinyJapaneseV6KVBatchV4FP32KVINT8.mlmodelc`), its 12K
/// SentencePiece tokenizer (`VimeJapaneseTokenizerV6.model`), and the
/// hiragana-reading token index (`VimeJapaneseKanaIndexV6.json`).
///
/// One instance, held by `JapaneseCandidateWorker.LanguageModelStorage`
/// (mutually exclusive with V4.2 and the Chinese model), performs both:
/// - scoring AzooKey's top-20 candidates (`gen_score + 1.6 * lm_score`) on
///   every keystroke via `prefix` + `score`; and
/// - kana-position-bucketed constrained beam-16 generation (`topk = 10`)
///   after a pause via `scored`, merged and re-ranked with AzooKey's list.
///
/// Confined to `JapaneseCandidateWorker.modelQueue`.
nonisolated final class JapaneseLanguageModelV6 {
    enum Version: String, CaseIterable, Sendable {
        case v42
        case v6

        var displayVersion: String {
            switch self {
            case .v42: "4.2"
            case .v6: "6"
            }
        }
    }

    struct KanaIndex: Sendable {
        private struct Payload: Decodable {
            let format: String
            let max_len: Int?
            let by_reading: [String: [Int32]]
        }

        let byReading: [String: [Int32]]
        let maxLength: Int

        init(url: URL) throws {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
            guard payload.format == "vimeml_ja_kana_index_v1", !payload.by_reading.isEmpty else {
                throw VimeLanguageModel.Failure.integrity
            }
            var normalized: [String: [Int32]] = [:]
            normalized.reserveCapacity(payload.by_reading.count)
            var computedMax = 0
            for (reading, tids) in payload.by_reading where !reading.isEmpty && !tids.isEmpty {
                let uniqueSorted = Array(Set(tids)).sorted()
                normalized[reading] = uniqueSorted
                computedMax = max(computedMax, reading.count)
            }
            byReading = normalized
            maxLength = payload.max_len ?? computedMax
        }

        /// `ok[p]` is true iff `reading[p...]` can be covered by a sequence of pieces in this index.
        func reachable(_ reading: [Character]) -> [Bool] {
            let n = reading.count
            var ok = [Bool](repeating: false, count: n + 1)
            ok[n] = true
            guard n > 0 else { return ok }
            for p in stride(from: n - 1, through: 0, by: -1) {
                let hi = min(n, p + maxLength)
                for end in (p + 1)...hi where ok[end] {
                    if byReading[String(reading[p..<end])] != nil {
                        ok[p] = true
                        break
                    }
                }
            }
            return ok
        }
    }

    struct TaskScoreInput: Equatable, Sendable {
        let promptIDs: [Int32]
        let outputIDs: [Int32]
    }

    struct LMScoreInput: Equatable, Sendable {
        let ids: [Int32]
        let from: Int
    }

    struct GenerationResult: Equatable, Sendable {
        let text: String
        let score: Double
        let tokens: [Int32]
    }

    struct ScoredCandidate: Equatable, Sendable {
        let text: String
        let genScore: Double?
        let lmScore: Double?
        let finalScore: Double?
    }

    static let tokenizerResource = "VimeJapaneseTokenizerV6"
    static let kanaIndexResource = "VimeJapaneseKanaIndexV6"
    static let vocabulary = 12288
    static let contextLength = VimeKVBatchLanguageModel.contextLength
    static let contextCharLimit = 64
    static let bos: Int32 = 2
    static let eos: Int32 = 3
    static let contextMarker: Int32 = 4
    static let readingMarker: Int32 = 5
    static let outputMarker: Int32 = 6
    static let rescoreWeight: Double = 1.6
    static let defaultBeam = 16
    static let defaultTopK = 10
    static let azookeyLimit = 20

    static let defaultVersion: Version = .v6
    static let versionPreferenceKey = "vime.japaneseModelVersion"
    static var configuredVersion: Version {
        guard let raw = UserDefaults(suiteName: KeyboardPreferences.appGroup)?.string(forKey: versionPreferenceKey),
              let version = Version(rawValue: raw) else { return defaultVersion }
        return version
    }

    let batch: VimeKVBatchLanguageModel
    let tokenizer: VimeSentenceTokenizer
    let kanaIndex: KanaIndex
    private let generator: ChineseKVGenerator
    var modelVersion: String { batch.modelVersion }

    /// `preload` loads `score` and `prefix` so the first keystroke rerank does
    /// not pay cold load; `scored` stays lazy until pause-triggered generation.
    init(bundle: Bundle = .main, preload: Bool = false) throws {
        guard let tokenizerURL = bundle.url(forResource: Self.tokenizerResource, withExtension: "model"),
              let indexURL = bundle.url(forResource: Self.kanaIndexResource, withExtension: "json")
        else { throw VimeLanguageModel.Failure.resources }
        batch = try VimeKVBatchLanguageModel(bundle: bundle, variant: .jaV6)
        tokenizer = try VimeSentenceTokenizer(url: tokenizerURL, vocabulary: Self.vocabulary)
        kanaIndex = try KanaIndex(url: indexURL)
        generator = ChineseKVGenerator(batch: batch)
        if preload {
            try batch.preload(.score)
            try batch.preload(.prefix)
        }
    }

    // MARK: - Reading & Prompt Construction

    /// Converts katakana (`ァ`…`ヶ`) to hiragana, preserving prolonged marks and punctuation.
    static func toHiragana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            if scalar.value >= 0x30A1 && scalar.value <= 0x30F6,
               let shifted = UnicodeScalar(scalar.value - 0x60) {
                return shifted
            }
            return scalar
        }))
    }

    /// Splits the task-mode prompt into the reading-independent left-context prefix
    /// (`[BOS, CTX] + ctx`) and the reading suffix (`[READ] + reading + [OUT]`).
    func promptParts(reading: String, context: String = "", limit: Int = contextLength,
                     minOutputRoom: Int = 2) throws -> (contextPrefix: [Int32], readingSuffix: [Int32]) {
        let trimmedContext = context.isEmpty ? "" : String(context.suffix(Self.contextCharLimit))
        var ctx = trimmedContext.isEmpty ? [] : try tokenizer.encode(trimmedContext)
        let read = reading.isEmpty ? [] : try tokenizer.encode(reading)
        let fixed = 4 + read.count // BOS, CTX, READ, read..., OUT
        let maxCtx = max(0, limit - minOutputRoom - fixed)
        if ctx.count > maxCtx {
            ctx = maxCtx > 0 ? Array(ctx.suffix(maxCtx)) : []
        }
        return ([Self.bos, Self.contextMarker] + ctx, [Self.readingMarker] + read + [Self.outputMarker])
    }

    func promptIDs(reading: String, context: String = "", limit: Int = contextLength,
                   minOutputRoom: Int = 2) throws -> [Int32] {
        let parts = try promptParts(reading: reading, context: context, limit: limit, minOutputRoom: minOutputRoom)
        return parts.contextPrefix + parts.readingSuffix
    }

    // MARK: - Task & LM Scoring Inputs

    /// Exact task-mode score inputs matching `prepare_ja_v6_20m.task_score_inputs`.
    func taskScoreInputs(reading: String, context: String, candidates: [String]) throws -> [TaskScoreInput?] {
        let hira = Self.toHiragana(reading)
        var out: [TaskScoreInput?] = []
        out.reserveCapacity(candidates.count)
        for cand in candidates {
            guard !cand.isEmpty else { out.append(nil); continue }
            let ids = try tokenizer.encode(cand)
            guard (try? tokenizer.decode(ids)) == cand else { out.append(nil); continue }
            let output = ids + [Self.eos]
            let base = try promptIDs(reading: hira, context: context,
                                     limit: Self.contextLength + 1, minOutputRoom: output.count)
            if base.count + output.count - 1 > Self.contextLength {
                out.append(nil)
            } else {
                out.append(TaskScoreInput(promptIDs: base, outputIDs: output))
            }
        }
        return out
    }

    private static func commonPrefixLength(_ sequences: [[Int32]]) -> Int {
        guard let first = sequences.first else { return 0 }
        var length = first.count
        for seq in sequences.dropFirst() {
            let limit = min(length, seq.count)
            var matched = 0
            while matched < limit && first[matched] == seq[matched] { matched += 1 }
            length = matched
            if length == 0 { break }
        }
        return length
    }

    /// Exact LM-mode score inputs matching `prepare_ja_v6_20m.lm_score_inputs`.
    func lmScoreInputs(context: String, candidates: [String]) throws -> [LMScoreInput?] {
        guard !candidates.isEmpty else { return [] }
        let contextTokens = context.isEmpty ? [] : try tokenizer.encode(context)
        let contextIDs = [Self.bos] + contextTokens

        func joint(_ subset: [String]) throws -> [LMScoreInput]? {
            var sequences: [[Int32]] = []
            sequences.reserveCapacity(subset.count)
            for cand in subset {
                guard !cand.isEmpty else { return nil }
                let combined = context + cand
                let content = try tokenizer.encode(combined)
                guard (try? tokenizer.decode(content)) == combined else { return nil }
                let seq = [Self.bos] + content
                guard seq.count - 1 >= 1 && seq.count - 1 <= Self.contextLength else { return nil }
                sequences.append(seq)
            }
            let common = Self.commonPrefixLength([contextIDs] + sequences)
            guard common >= 1, sequences.allSatisfy({ $0.count > common }) else { return nil }
            return sequences.map { LMScoreInput(ids: $0, from: common) }
        }

        if let all = try joint(candidates) {
            return all.map { Optional($0) }
        }
        var out = [LMScoreInput?](repeating: nil, count: candidates.count)
        var eligibleIndices: [Int] = []
        for (i, cand) in candidates.enumerated() {
            if (try joint([cand])) != nil {
                eligibleIndices.append(i)
            }
        }
        if !eligibleIndices.isEmpty, let eligibleJoint = try joint(eligibleIndices.map { candidates[$0] }) {
            for (idx, item) in zip(eligibleIndices, eligibleJoint) {
                out[idx] = item
            }
        }
        return out
    }

    // MARK: - Batched KV Scoring

    /// Scores grouped `(prefix, continuation)` rows with one `prefix` call per distinct prefix
    /// and batched `score` calls.
    func scoreRows(_ rows: [(prefix: [Int32], continuation: [Int32])?],
                   cancelled: () -> Bool = { false }) throws -> [Double?] {
        var out = [Double?](repeating: nil, count: rows.count)
        var groupOrder: [[Int32]] = []
        var groups: [[Int32]: [Int]] = [:]
        for (i, row) in rows.enumerated() {
            guard let row, !row.prefix.isEmpty, !row.continuation.isEmpty else { continue }
            if groups[row.prefix] == nil { groupOrder.append(row.prefix) }
            groups[row.prefix, default: []].append(i)
        }
        for prefixTokens in groupOrder {
            if cancelled() { throw VimeLanguageModel.Failure.cancelled }
            guard let indices = groups[prefixTokens] else { continue }
            let basePrefix = try batch.prefix(Array(prefixTokens.dropLast()))
            let lastPrompt = prefixTokens[prefixTokens.count - 1]
            let scoreInputs = indices.map { [lastPrompt] + rows[$0]!.continuation }
            let tokenLogProbs = try batch.scores(after: basePrefix, rows: scoreInputs, cancelled: cancelled)
            for (idx, logProbs) in zip(indices, tokenLogProbs) {
                var sum = 0.0
                for lp in logProbs { sum += Double(lp) }
                out[idx] = sum.isFinite ? sum : nil
            }
        }
        return out
    }

    func scoreTask(reading: String, context: String, candidates: [String],
                   cancelled: () -> Bool = { false }) throws -> [Double?] {
        let inputs = try taskScoreInputs(reading: reading, context: context, candidates: candidates)
        return try scoreRows(inputs.map { $0.map { ($0.promptIDs, $0.outputIDs) } }, cancelled: cancelled)
    }

    func scoreLM(context: String, candidates: [String],
                 cancelled: () -> Bool = { false }) throws -> [Double?] {
        let inputs = try lmScoreInputs(context: context, candidates: candidates)
        return try scoreRows(inputs.map { item in
            item.map { (Array($0.ids[..<$0.from]), Array($0.ids[$0.from...])) }
        }, cancelled: cancelled)
    }

    // MARK: - Merge & Rank

    /// Ranks `unique(azookey + generated)` by `gen_score + lambda * lm_score` descending,
    /// matching `kana_gen_ja.merge_and_rank`.
    static func mergeAndRank(azookey: [String], generated: [String],
                             genScores: [Double?], lmScores: [Double?],
                             lambda: Double = rescoreWeight) -> [String] {
        var union: [String] = []
        var seen: Set<String> = []
        for text in azookey + generated where !text.isEmpty && seen.insert(text).inserted {
            union.append(text)
        }
        guard !union.isEmpty else { return [] }
        struct Key {
            let valid: Int
            let total: Double
            let index: Int
            let text: String
        }
        let keys: [Key] = union.enumerated().map { i, text in
            let gs = i < genScores.count ? genScores[i] : nil
            let ls = i < lmScores.count ? lmScores[i] : nil
            if let gs, let ls {
                return Key(valid: 0, total: gs + lambda * ls, index: i, text: text)
            } else if let ls {
                return Key(valid: 1, total: lambda * ls, index: i, text: text)
            } else if let gs {
                return Key(valid: 1, total: gs, index: i, text: text)
            } else {
                return Key(valid: 2, total: -.infinity, index: i, text: text)
            }
        }
        return keys.sorted { a, b in
            if a.valid != b.valid { return a.valid < b.valid }
            if a.total != b.total { return a.total > b.total }
            return a.index < b.index
        }.map(\.text)
    }

    /// Reranks AzooKey candidates (first step on every keystroke) by `gen_score + 1.6 * lm_score`.
    func rerankAzooKey(reading: String, context: String, candidates: [String],
                       cancelled: () -> Bool = { false }) throws -> (ordered: [String], genScores: [Double?], lmScores: [Double?]) {
        let hira = Self.toHiragana(reading)
        let gen = try scoreTask(reading: hira, context: context, candidates: candidates, cancelled: cancelled)
        let lm = try scoreLM(context: context, candidates: candidates, cancelled: cancelled)
        let ordered = Self.mergeAndRank(azookey: candidates, generated: [], genScores: gen, lmScores: lm)
        return (ordered, gen, lm)
    }

    // MARK: - Constrained Kana Beam Search

    /// Kana-position-bucketed constrained beam search in task mode, ending with `log P(EOS)`,
    /// matching `vimeml.deployment.ja_search.search_constrained`.
    func generate(reading: String, context: String = "", beam: Int = defaultBeam, topk: Int = defaultTopK,
                  cancelled: () -> Bool = { false }) throws -> [GenerationResult] {
        let hira = Self.toHiragana(reading)
        let parts = try promptParts(reading: hira, context: context)
        let baseLen = parts.contextPrefix.count + parts.readingSuffix.count
        let chars = Array(hira)
        let n = chars.count
        let ok = kanaIndex.reachable(chars)
        guard ok[0], baseLen < Self.contextLength else { return [] }
        let room = Self.contextLength - baseLen

        // Precompute valid moves and sorted unique allowed token IDs per reading position.
        var movesByPos: [[(end: Int, tids: [Int32])]] = Array(repeating: [], count: n)
        var allowedByPos: [[Int32]] = Array(repeating: [], count: n)
        for pos in 0..<n where ok[pos] {
            var moves: [(end: Int, tids: [Int32])] = []
            var allowedSet: Set<Int32> = []
            let hi = min(n, pos + kanaIndex.maxLength)
            for end in (pos + 1)...hi where ok[end] {
                if let tids = kanaIndex.byReading[String(chars[pos..<end])] {
                    moves.append((end, tids))
                    for tid in tids { allowedSet.insert(tid) }
                }
            }
            movesByPos[pos] = moves
            allowedByPos[pos] = allowedSet.sorted()
        }

        if cancelled() { throw VimeLanguageModel.Failure.cancelled }
        let ctxPrefix = try generator.prefix(parts.contextPrefix)
        let rootAllowed = n == 0 ? [Self.eos] : allowedByPos[0]
        let rootStep = try generator.start(parts.readingSuffix, after: ctxPrefix, allowed: rootAllowed)

        struct Chunk {
            let tokens: [Int32]
            let state: VimeKVLanguageModel.Cache
            let tids: [Int32]
            let values: [Double]
        }
        struct Kept {
            let tokens: [Int32]
            let score: Double
            let parentState: VimeKVLanguageModel.Cache
            let lastToken: Int32
        }

        var buckets: [Int: [Chunk]] = [:]
        var done: [String: (score: Double, tokens: [Int32])] = [:]

        func finish(_ tokens: [Int32], score: Double) {
            guard let text = try? tokenizer.decode(tokens) else { return }
            if let existing = done[text], existing.score >= score { return }
            done[text] = (score, tokens)
        }

        func expand(tokens: [Int32], score: Double, logProbs: [Float], allowed: [Int32],
                    state: VimeKVLanguageModel.Cache, pos: Int) {
            guard tokens.count + 1 < room else { return }
            var indexMap: [Int32: Int] = [:]
            indexMap.reserveCapacity(allowed.count)
            for (idx, tid) in allowed.enumerated() { indexMap[tid] = idx }
            for move in movesByPos[pos] {
                var values = [Double]()
                values.reserveCapacity(move.tids.count)
                for tid in move.tids {
                    if let idx = indexMap[tid] {
                        values.append(Double(logProbs[idx]) + score)
                    } else {
                        values.append(-.infinity)
                    }
                }
                buckets[move.end, default: []].append(Chunk(tokens: tokens, state: state, tids: move.tids, values: values))
            }
        }

        if n == 0 {
            finish([], score: Double(rootStep.logProbabilities[0]))
        } else {
            expand(tokens: [], score: 0.0, logProbs: rootStep.logProbabilities, allowed: rootAllowed,
                   state: rootStep.state, pos: 0)
        }

        for pos in 1...max(1, n) {
            if n == 0 { break }
            if cancelled() { throw VimeLanguageModel.Failure.cancelled }
            guard let chunks = buckets.removeValue(forKey: pos), !chunks.isEmpty else { continue }

            // Flatten and pick top `beam` distinct token sequences in stable descending score order.
            struct Entry {
                let chunkIndex: Int
                let itemIndex: Int
                let value: Double
                let flatIndex: Int
            }
            var entries: [Entry] = []
            var total = 0
            for c in chunks { total += c.tids.count }
            entries.reserveCapacity(total)
            var flat = 0
            for (ci, c) in chunks.enumerated() {
                for ii in 0..<c.tids.count {
                    entries.append(Entry(chunkIndex: ci, itemIndex: ii, value: c.values[ii], flatIndex: flat))
                    flat += 1
                }
            }
            entries.sort { a, b in
                if a.value != b.value { return a.value > b.value }
                return a.flatIndex < b.flatIndex
            }
            var kept: [Kept] = []
            kept.reserveCapacity(beam)
            var seen: Set<[Int32]> = []
            for entry in entries {
                let chunk = chunks[entry.chunkIndex]
                let tid = chunk.tids[entry.itemIndex]
                var child = chunk.tokens
                child.append(tid)
                if seen.insert(child).inserted {
                    kept.append(Kept(tokens: child, score: entry.value, parentState: chunk.state, lastToken: tid))
                    if kept.count == beam { break }
                }
            }
            guard !kept.isEmpty else { continue }

            let stepAllowed = pos == n ? [Self.eos] : allowedByPos[pos]
            let steps = try generator.extend(kept.map { ($0.parentState, $0.lastToken) }, allowed: stepAllowed)
            for (r, item) in kept.enumerated() {
                if pos == n {
                    finish(item.tokens, score: item.score + Double(steps[r].logProbabilities[0]))
                } else {
                    expand(tokens: item.tokens, score: item.score, logProbs: steps[r].logProbabilities,
                           allowed: stepAllowed, state: steps[r].state, pos: pos)
                }
            }
        }

        return done.map { GenerationResult(text: $0.key, score: $0.value.score, tokens: $0.value.tokens) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.text < b.text
            }
            .prefix(topk)
            .map { $0 }
    }

    /// Full pipeline: generate top-10, merge with AzooKey top-20, score union with `gen_score` and `lm_score`,
    /// and rank by `gen_score + 1.6 * lm_score`.
    func generateAndMerge(reading: String, context: String, azookey: [String],
                          beam: Int = defaultBeam, topk: Int = defaultTopK,
                          cancelled: () -> Bool = { false }) throws
        -> (generated: [GenerationResult], shown: [String], rescored: [String]) {
        let hira = Self.toHiragana(reading)
        let generated = try generate(reading: hira, context: context, beam: beam, topk: topk, cancelled: cancelled)
        let genTexts = generated.map(\.text)
        var union: [String] = []
        var seen: Set<String> = []
        for t in azookey + genTexts where !t.isEmpty && seen.insert(t).inserted {
            union.append(t)
        }
        let genScores = try scoreTask(reading: hira, context: context, candidates: union, cancelled: cancelled)
        let lmScores = try scoreLM(context: context, candidates: union, cancelled: cancelled)
        let shown = Self.mergeAndRank(azookey: azookey, generated: genTexts, genScores: genScores, lmScores: lmScores)

        var indexByText: [String: Int] = [:]
        for (i, t) in union.enumerated() { indexByText[t] = i }
        let rescored = genTexts.enumerated().sorted { a, b in
            let ia = indexByText[a.element]!, ib = indexByText[b.element]!
            let ka: Double = {
                if let g = genScores[ia], let l = lmScores[ia] { return g + Self.rescoreWeight * l }
                return genScores[ia] ?? -.infinity
            }()
            let kb: Double = {
                if let g = genScores[ib], let l = lmScores[ib] { return g + Self.rescoreWeight * l }
                return genScores[ib] ?? -.infinity
            }()
            if ka != kb { return ka > kb }
            return a.offset < b.offset
        }.map(\.element)

        return (generated, shown, rescored)
    }
}
