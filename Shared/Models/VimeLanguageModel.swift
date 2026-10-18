import Foundation
import CoreML
import CSentencePiece
import Accelerate

/// Confined to the worker's model queue, independently of dictionary conversion.
nonisolated final class VimeSentenceTokenizer {
    private let processor: UnsafeMutableRawPointer
    init(url: URL) throws {
        guard let p = url.path.withCString({ vime_sp_load($0) }) else { throw VimeLanguageModel.Failure.tokenizer }
        processor = p
    }
    deinit { vime_sp_destroy(processor) }
    func encode(_ text: String) throws -> [Int32] {
        var ids: UnsafeMutablePointer<Int32>?
        var count = 0
        let bytes = Array(text.utf8)
        let ok = bytes.withUnsafeBytes { data in
            vime_sp_encode(processor, data.baseAddress?.assumingMemoryBound(to: CChar.self), data.count, &ids, &count)
        }
        defer { if let ids { vime_sp_free(ids) } }
        guard ok == 1 else { throw VimeLanguageModel.Failure.tokenizer }
        return ids.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
    }
    func decode(_ ids: [Int32]) throws -> String {
        var text: UnsafeMutablePointer<CChar>?
        var bytes = 0
        let ok = ids.withUnsafeBufferPointer { vime_sp_decode(processor, $0.baseAddress, $0.count, &text, &bytes) }
        defer { if let text { vime_sp_free(text) } }
        guard ok == 1, let text,
              let result = String(bytes: UnsafeRawBufferPointer(start: text, count: bytes), encoding: .utf8)
        else { throw VimeLanguageModel.Failure.tokenizer }
        return result
    }
}

nonisolated final class VimeLanguageModel {
    enum Failure: Error { case resources, integrity, tokenizer, ineligible, tensor, cancelled }
    struct Manifest: Decodable {
        let format: String
        let architecture: String?
        let model_version: String?
        let special_ids: [String: Int]?
        let compute_units: String?
        let minimum_ios: Int
        let vocab_size: Int
        let context_length: Int
        let tokenizer_sha256: String
        let compiled_files_sha256: [String: String]
    }
    let tokenizer: VimeSentenceTokenizer
    private let model: MLModel
    static let vocabulary = 16384
    static let contextLength = 128
    /// Lives for one next-word request, never on the shared model. A score is
    /// reusable only for the same prompt, joint tokens and suffix boundary.
    final class SuggestionScoreCache {
        private struct Key: Hashable {
            let prompt: Data
            let sequence: [Int32]
            let common: Int
        }
        private var values: [Key: Double] = [:]
        private(set) var reuses = 0
        private(set) var scoringPasses = 0
        func value(prompt: String, sequence: [Int32], common: Int) -> Double? {
            let value = values[Key(prompt: Data(prompt.utf8), sequence: sequence, common: common)]
            if value != nil { reuses += 1 } else { scoringPasses += 1 }
            return value
        }
        func store(_ value: Double, prompt: String, sequence: [Int32], common: Int) {
            guard values.count < 32 else { return }
            values[Key(prompt: Data(prompt.utf8), sequence: sequence, common: common)] = value
        }
    }
    /// A failed model identity check uses the worker's dictionary fallback.
    let modelVersion: String
    init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .cpuOnly) throws {
        guard let modelURL = bundle.url(forResource: "TinyJapaneseV21INT8", withExtension: "mlmodelc"),
              let tokenizerURL = bundle.url(forResource: "VimeJapaneseTokenizerV2", withExtension: "model"),
              let manifestURL = bundle.url(forResource: "VimeLMManifestV21", withExtension: "json") else { throw Failure.resources }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.format == "vime_ios_lm_v2",
              manifest.architecture == "tiny_gpt_v2", manifest.compute_units == "CPU_ONLY",
              manifest.special_ids == ["pad": 0, "unk": 1, "bos": 2, "eos": 3],
              let version = manifest.model_version, !version.isEmpty,
              computeUnits == .cpuOnly else { throw Failure.integrity }
        modelVersion = version
        guard manifest.minimum_ios == 18, manifest.vocab_size == Self.vocabulary,
              manifest.context_length == Self.contextLength,
              !manifest.tokenizer_sha256.isEmpty,
              !manifest.compiled_files_sha256.isEmpty else { throw Failure.integrity }
        // Bundled resources are immutable. Both Release targets validate hashes
        // in validate_model_resources.py during the build; loading must not copy
        // the entire weights file into Data on every keyboard lifecycle.
        for (name, digest) in manifest.compiled_files_sha256 {
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
                  !digest.isEmpty else { throw Failure.integrity }
        }
        tokenizer = try VimeSentenceTokenizer(url: tokenizerURL)
        // This package computes in FP32, so the Neural Engine cannot run it, and its INT8 embedding
        // gather aborts inside MPS on .all/.cpuAndGPU (iPhone 16 Pro Max, iOS 27). Keep .cpuOnly.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }
    /// The model was trained on independent sentences (BOS + one sentence).
    /// Feed it only the unfinished sentence before the caret, bounded so the
    /// prompt stays short; scoring and generation still check the token limit.
    static func sentenceContext(_ text: String, limit: Int = 64) -> String {
        var tail = Substring(text.suffix(limit))
        if let end = tail.lastIndex(where: { $0.isNewline || "。！？!?".contains($0) }) {
            tail = tail[tail.index(after: end)...]
        }
        return String(tail.drop(while: \.isWhitespace))
    }
    private static func exactText(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    /// Process physical footprint (what jetsam limits), for load diagnostics.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
    func predict(_ ids: [Int32]) throws -> MLMultiArray {
        guard !ids.isEmpty, ids.count <= Self.contextLength,
              ids.allSatisfy({ $0 >= 0 && $0 < Self.vocabulary }) else { throw Failure.tensor }
        let input = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        let pointer = input.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
        for (i, id) in ids.enumerated() { pointer[i] = id }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_ids": input]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
              logits.dataType == .float32,
              logits.shape.map(\.intValue) == [1, ids.count, Self.vocabulary] else { throw Failure.tensor }
        return logits
    }
    static func logProbabilities(_ logits: MLMultiArray, row: Int) throws -> [Double] {
        guard row >= 0, row < logits.shape[1].intValue else { throw Failure.tensor }
        let pointer = logits.dataPointer.assumingMemoryBound(to: Float.self)
        let offset = row * logits.strides[1].intValue
        let stride = logits.strides[2].intValue
        var values = (0..<vocabulary).map { Double(pointer[offset + $0 * stride]) }
        guard values.allSatisfy(\.isFinite), let maximum = values.max() else { throw Failure.tensor }
        let normalizer = maximum + log(values.reduce(0) { $0 + exp($1 - maximum) })
        for i in values.indices { values[i] -= normalizer }
        return values
    }
    /// Exactly the frozen scorer: joint encoding, common prefix, full-vocabulary log-softmax,
    /// BOS=2, summed suffix scores, no candidate-final EOS or truncation. Causal
    /// logits are unchanged when unused right padding is omitted.
    func scores(context: String, candidates: [String], cache: SuggestionScoreCache? = nil,
                cancelled: () -> Bool = { false }) throws -> [Double] {
        try scores(context: context, candidates: candidates, progress: nil, cache: cache, cancelled: cancelled)
    }

    private func scores(context: String, candidates: [String], progress: (([Double]) -> Void)?,
                        cache: SuggestionScoreCache? = nil, cancelled: () -> Bool) throws -> [Double] {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.lmCandidateScoring, since: started) }
        guard !candidates.isEmpty, Set(candidates.map { Data($0.utf8) }).count == candidates.count,
              candidates.allSatisfy({ !$0.isEmpty }) else { throw Failure.ineligible }
        let contextTokens = try tokenizer.encode(context)
        guard Self.exactText(try tokenizer.decode(contextTokens), context),
              contextTokens.count + 1 <= Self.contextLength else { throw Failure.ineligible }
        let contextIDs: [Int32] = [2] + contextTokens
        let sequences: [[Int32]] = try candidates.map { text in
            let content = try tokenizer.encode(context + text)
            guard Self.exactText(try tokenizer.decode(content), context + text), !content.isEmpty,
                  content.count <= Self.contextLength else { throw Failure.ineligible }
            return [2] + content
        }
        var common = 0
        for i in 0..<([contextIDs] + sequences).map(\.count).min()! {
            if sequences.allSatisfy({ $0[i] == contextIDs[i] }) { common += 1 } else { break }
        }
        guard common >= 1, sequences.allSatisfy({ $0.count > common }) else { throw Failure.ineligible }
        return try sequenceScores(sequences, common: common, progress: progress,
            prompt: context, cache: cache, cancelled: cancelled)
    }

    private func sequenceScores(_ sequences: [[Int32]], common: Int,
                                progress: (([Double]) -> Void)? = nil,
                                prompt: String = "", cache: SuggestionScoreCache? = nil,
                                cancelled: () -> Bool) throws -> [Double] {
        var sums = [Double]()
        for sequence in sequences {
            if cancelled() { throw Failure.cancelled }
            if let cached = cache?.value(prompt: prompt, sequence: sequence, common: common) {
                sums.append(cached); progress?(sums); continue
            }
            // A long all-kana alternative must not force every short native
            // conversion through a larger transformer/output tensor. The
            // causal model cannot attend to the unused right padding anyway.
            let input = Array(sequence.dropLast())
            let sum: Double = try autoreleasepool {
                let logits = try predict(input)
                // Only the observed token's probability is needed. Reuse one
                // vocabulary buffer and vectorize the full normalizer instead
                // of allocating and normalizing a Swift array for every token.
                var scratch = [Double](repeating: 0, count: Self.vocabulary)
                var sum = 0.0
                for row in (common - 1)..<(sequence.count - 1) {
                    if cancelled() { throw Failure.cancelled }
                    sum += try Self.tokenLogProbability(logits, row: row, token: Int(sequence[row + 1]), scratch: &scratch)
                }
                return sum
            }
            guard sum.isFinite else { throw Failure.tensor }
            cache?.store(sum, prompt: prompt, sequence: sequence, common: common)
            sums.append(sum) // Release each candidate's full logits before the next prediction.
            progress?(sums)
        }
        return sums
    }
    private static func tokenLogProbability(_ logits: MLMultiArray, row: Int, token: Int,
                                            scratch: inout [Double]) throws -> Double {
        let pointer = logits.dataPointer.assumingMemoryBound(to: Float.self)
            .advanced(by: row * logits.strides[1].intValue)
        let stride = logits.strides[2].intValue
        let observed = Double(pointer[token * stride])
        return try scratch.withUnsafeMutableBufferPointer { buffer in
            let p = buffer.baseAddress!
            let count = vDSP_Length(vocabulary)
            vDSP_vspdp(pointer, vDSP_Stride(stride), p, 1, count)
            var finiteCheck = 0.0
            vDSP_sveD(p, 1, &finiteCheck, count)
            guard finiteCheck.isFinite else { throw Failure.tensor }
            var maximum = 0.0
            vDSP_maxvD(p, 1, &maximum, count)
            var shift = -maximum
            vDSP_vsaddD(p, 1, &shift, p, 1, count)
            var n = Int32(vocabulary)
            vvexp(p, p, &n)
            var total = 0.0
            vDSP_sveD(p, 1, &total, count)
            guard total.isFinite, total > 0 else { throw Failure.tensor }
            return observed - maximum - log(total)
        }
    }
    /// Compare native complete conversions and literal kana alternatives in
    /// their existing slots. Partial, width, correction and prediction entries
    /// keep their consumption and presentation semantics.
    static func rerankingSlots(_ values: [CandidateSnapshot], katakana: Bool) -> [Int] {
        guard !katakana else { return [] }
        var seen = Set<String>()
        return values.indices.filter { index in
            let value = values[index]
            let native = value.source == .conversion || value.source == .orthographicVariant || value.source == .userDictionary
            let kana = value.source == .scriptVariant && RomajiConverter.katakana(value.text) == value.reading
            return (native || kana) && value.widthVariant == nil && value.scopeFullConsumption
                && (value.fullConsumption || value.explicitScope) && value.exactReading
                && seen.insert(value.text).inserted
        }
    }
    func rerank(_ values: [CandidateSnapshot], context: String, katakana: Bool, maximumCandidates: Int? = nil,
                onRefinement: (([CandidateSnapshot]) -> Void)? = nil,
                cancelled: @escaping () -> Bool) -> [CandidateSnapshot] {
        guard !katakana, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cancelled() else { return values }
        let plan = CandidateCompetitionPolicy.plan(values, katakana: katakana, maximumCandidates: maximumCandidates ?? 8)
        let started = ProcessInfo.processInfo.systemUptime
        let stop = { cancelled() || ProcessInfo.processInfo.systemUptime - started > 0.250 }
        // One unsupported symbol or overlong alternative must not disable
        // scoring of every other candidate. Rejected entries keep their slots.
        let slots = plan.slots.filter { index in
            guard !stop(), let ids = try? tokenizer.encode(context + values[index].text),
                  !ids.isEmpty, ids.count <= Self.contextLength,
                  let decoded = try? tokenizer.decode(ids) else { return false }
            return Self.exactText(decoded, context + values[index].text)
        }
        guard slots.count > 1 else { return values }
        var result = values
        _ = try? scores(context: context, candidates: slots.map { values[$0].text }, progress: { sums in
            guard sums.count >= 2, !stop() else { return }
            result = CandidateCompetitionPolicy.applying(sums, slots: slots, to: values)
            onRefinement?(result)
        }, cancelled: stop)
        return result
    }
    struct Suggestion: Sendable {
        let text: String
        let tokenIDs: [Int32]
        let logProbabilitySum: Double
        let incomplete: Bool
    }
    /// Keyboard next-word prediction. Takes the most likely next tokens and extends each one
    /// greedily only while the model is confident (≥ `extendProbability`), so a suggestion is a
    /// word or short phrase, never a sentence. Stops before punctuation. At most
    /// 1 + 3 × count × (maxTokens − 1) forward passes in the worst case,
    /// including rejected starting tokens. Usually stops after count valid words.
    func nextWords(prompt: String, count: Int = 5, maxTokens: Int = 3, extendProbability: Double = 0.4,
                   cancelled: () -> Bool = { false }) throws -> [String] {
        try generateNextWords(prompt: prompt, count: count, maxTokens: maxTokens,
            extendProbability: extendProbability, cancelled: cancelled).map(\.text)
    }

    /// Native replacements expose a suffix for scoring but carry a full host edit.
    /// Score the common continuation boundary, never prompt + the repeated base word.
    func rerankPostComposition(_ values: [NextWordSuggestion], prompt: String,
                               cache: SuggestionScoreCache? = nil,
                               cancelled: @escaping () -> Bool = { false }) -> [NextWordSuggestion] {
        let started = ProcessInfo.processInfo.systemUptime
        let stop = { cancelled() || ProcessInfo.processInfo.systemUptime - started > 0.250 }
        let eligible = values.indices.filter { index in
            let value = values[index]
            let continuation = value.nativePrediction?.text ?? value.text
            guard !continuation.isEmpty, let ids = try? tokenizer.encode(prompt + continuation),
                  ids.count <= Self.contextLength, let decoded = try? tokenizer.decode(ids) else { return false }
            return Self.exactText(decoded, prompt + continuation)
        }
        guard !stop(), eligible.count > 1 else { return values }
        // Distinct host operations can share a scored continuation. Score it
        // once: scores() intentionally rejects duplicate input strings.
        let continuations = eligible.map { values[$0].nativePrediction?.text ?? values[$0].text }
        var unique: [String] = []
        var slots: [Data: Int] = [:]
        let scoreIndices = continuations.map { text -> Int in
            let key = Data(text.utf8)
            if let slot = slots[key] { return slot }
            let slot = unique.count
            unique.append(text); slots[key] = slot
            return slot
        }
        guard let uniqueSums = try? scores(context: prompt, candidates: unique, cache: cache, cancelled: stop),
              !stop() else { return values }
        let sums = scoreIndices.map { uniqueSums[$0] }
        let order = sums.indices.sorted { sums[$0] == sums[$1] ? $0 < $1 : sums[$0] > sums[$1] }
        var result = values
        for (rank, index) in order.enumerated() {
            let slot = eligible[index]
            result[slot].modelScore = sums[index]
            result[slot].score = PostCompositionSuggestionReranker.Policy.sourceEvidence
                - PostCompositionSuggestionReranker.Policy.orderCost * log1p(Double(rank)) + result[slot].userScore
        }
        return result.indices.sorted {
            result[$0].score == result[$1].score ? $0 < $1 : result[$0].score > result[$1].score
        }.map { result[$0] }
    }

    private(set) var nextWordScoreReuses = 0
    private(set) var nextWordScoringPasses = 0
    private struct GeneratedWord {
        let text: String
        let ids: [Int32]
        let score: Double
    }

    private func generateNextWords(prompt: String, count: Int = 5, maxTokens: Int = 3, extendProbability: Double = 0.4,
                                   cancelled: () -> Bool) throws -> [GeneratedWord] {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.lmNextWords, since: started) }
        guard !prompt.isEmpty, (1...8).contains(count), (1...4).contains(maxTokens) else { throw Failure.ineligible }
        let content = try tokenizer.encode(prompt)
        guard Self.exactText(try tokenizer.decode(content), prompt),
              content.count + maxTokens + 1 <= Self.contextLength else { throw Failure.ineligible }
        let prefix: [Int32] = [2] + content
        let boundaries = Set("。！？!?、，,「」『』（）()…・\n")
        // A lone character is usually an honorific prefix or a kanji stem (お, ご, 飲), not a word.
        let particles: Set<String> = ["は", "が", "を", "に", "で", "と", "も", "の", "へ", "や", "か", "ね", "よ", "な"]
        func suffix(_ ids: [Int32]) throws -> String? {
            let text = try tokenizer.decode(content + ids)
            guard text.utf8.starts(with: prompt.utf8) else { return nil }
            return String(decoding: text.utf8.dropFirst(prompt.utf8.count), as: UTF8.self)
        }
        func distribution(_ ids: [Int32]) throws -> [Double] {
            if cancelled() { throw Failure.cancelled }
            var values = try autoreleasepool {
                try Self.logProbabilities(predict(prefix + ids), row: prefix.count + ids.count - 1)
            }
            for token in 0...3 { values[token] = -.infinity } // PAD, UNK, BOS, EOS
            return values
        }
        if cancelled() { throw Failure.cancelled }
        let first = try distribution([])
        var candidates = [Int]()
        for token in first.indices where first[token].isFinite {
            if candidates.count == count * 3, first[token] <= first[candidates.last!] { continue }
            candidates.append(token)
            candidates.sort { first[$0] > first[$1] }
            if candidates.count > count * 3 { candidates.removeLast() }
        }
        var result = [GeneratedWord]()
        for token in candidates where result.count < count {
            if cancelled() { throw Failure.cancelled }
            var ids = [Int32(token)]
            var score = first[token]
            var word: String?
            while let text = try suffix(ids) {
                // Cut at the first boundary; a leading boundary means the token is punctuation.
                if let cut = text.firstIndex(where: { boundaries.contains($0) }) {
                    word = String(text[..<cut]); break
                }
                let complete = !text.contains("\u{fffd}")
                if ids.count == maxTokens { word = complete ? text : nil; break }
                let next = try distribution(ids)
                let best = next.indices.max { next[$0] < next[$1] }!
                // Byte-fallback pieces and lone stems must be extended; otherwise only when confident.
                let fragment = !complete || (text.count < 2 && !particles.contains(text))
                if !fragment && exp(next[best]) < extendProbability { word = text; break }
                ids.append(Int32(best))
                score += next[best]
            }
            guard let word, let lead = word.unicodeScalars.first, !lead.isASCII || lead.properties.isAlphabetic,
                  !word.trimmingCharacters(in: .whitespaces).isEmpty, !result.contains(where: { $0.text == word }) else { continue }
            result.append(GeneratedWord(text: word, ids: ids, score: score))
        }
        return result
    }

    /// Score the displayed strings (including punctuation cuts) and recalled
    /// history together. Joint tokenization shares the same context boundary,
    /// so generated and remembered phrases have comparable log probabilities.
    /// Reuses generated probabilities only when canonical tokenization and the
    /// scoring boundary match. At most eight extra passes; usually only history.
    func scoredNextWords(prompt: String, history: [String] = [], cache: SuggestionScoreCache? = nil,
                         cancelled: () -> Bool = { false }) throws
        -> (generated: [ScoredNextWord], history: [ScoredNextWord]) {
        nextWordScoreReuses = 0; nextWordScoringPasses = 0
        let generated = try generateNextWords(prompt: prompt, cancelled: cancelled)
        let words = generated.map(\.text)
        let remembered = history.filter {
            guard !words.contains($0), !$0.isEmpty, $0.count <= 64,
                  let tokens = try? tokenizer.encode(prompt + $0), tokens.count <= Self.contextLength,
                  let decoded = try? tokenizer.decode(tokens) else { return false }
            return Self.exactText(decoded, prompt + $0)
        }
            .prefix(CandidatePreferenceMemory.Policy.maximumRememberedSuggestions)
        let texts = words + Array(Set(remembered)).sorted()
        guard !texts.isEmpty else { return ([], []) }
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.lmNextWordScoring, since: started) }
        let contextIDs: [Int32] = [2] + (try tokenizer.encode(prompt))
        let sequences = try texts.map { text in
            let tokens = try tokenizer.encode(prompt + text)
            guard Self.exactText(try tokenizer.decode(tokens), prompt + text) else { throw Failure.ineligible }
            return [Int32(2)] + tokens
        }
        var common = 0
        for i in 0..<([contextIDs] + sequences).map(\.count).min()! {
            if sequences.allSatisfy({ $0[i] == contextIDs[i] }) { common += 1 } else { break }
        }
        guard common >= 1, sequences.allSatisfy({ $0.count > common && $0.count - 1 <= Self.contextLength }) else { throw Failure.ineligible }
        var values = Array(repeating: 0.0, count: texts.count)
        var uncached = [Int]()
        for i in texts.indices {
            if i < generated.count, common == contextIDs.count, sequences[i] == contextIDs + generated[i].ids {
                values[i] = generated[i].score
            } else { uncached.append(i) }
        }
        let fresh = try sequenceScores(uncached.map { sequences[$0] }, common: common, cancelled: cancelled)
        nextWordScoringPasses = uncached.count
        nextWordScoreReuses = texts.count - uncached.count
        for (index, value) in zip(uncached, fresh) { values[index] = value }
        if cancelled() { throw Failure.cancelled }
        for i in texts.indices { cache?.store(values[i], prompt: prompt, sequence: sequences[i], common: common) }
        let scored = texts.indices.map { ScoredNextWord(text: texts[$0], logProbabilitySum: values[$0],
            tokenCount: sequences[$0].count - common) }
        return (Array(scored.prefix(words.count)), Array(scored.dropFirst(words.count)))
    }

    /// Fixed beam search matching the Mac demo (sentence continuation). The keyboard uses
    /// `nextWords`; this remains the reference implementation checked against Mac fixtures.
    func suggestions(prompt: String, count: Int = 5, maxTokens: Int = 8,
                     cancelled: () -> Bool = { false }) throws -> [Suggestion] {
        guard !prompt.isEmpty, (1...5).contains(count), (1...8).contains(maxTokens) else { throw Failure.ineligible }
        let content = try tokenizer.encode(prompt)
        guard Self.exactText(try tokenizer.decode(content), prompt), content.count + 1 <= Self.contextLength else { throw Failure.ineligible }
        let prefix: [Int32] = [2] + content
        struct Beam { let ids: [Int32]; let score: Double; var incomplete = false }
        var active = [Beam(ids: [], score: 0)]
        var finished = [Beam]()
        let punctuation = CharacterSet(charactersIn: "。！？!?")
        let trim = CharacterSet(charactersIn: " 、，,。！？!?\n\t")
        func decodedSuffix(_ ids: [Int32]) throws -> String? {
            let text = try tokenizer.decode(content + ids)
            guard text.utf8.starts(with: prompt.utf8), !text.contains("\u{fffd}") else { return nil }
            return String(decoding: text.utf8.dropFirst(prompt.utf8.count), as: UTF8.self)
        }
        for depth in 0..<maxTokens {
            var expanded = [Beam]()
            for beam in active {
                if cancelled() { throw Failure.cancelled }
                if prefix.count + beam.ids.count > Self.contextLength {
                    finished.append(Beam(ids: beam.ids, score: beam.score, incomplete: true)); continue
                }
                var probabilities = try autoreleasepool {
                    let logits = try predict(prefix + beam.ids)
                    return try Self.logProbabilities(logits, row: prefix.count + beam.ids.count - 1)
                }
                for token in [0, 1, 2] { probabilities[token] = -.infinity }
                if (try decodedSuffix(beam.ids) ?? "").trimmingCharacters(in: trim).isEmpty {
                    probabilities[3] = -.infinity
                }
                var top = [Int]()
                for token in probabilities.indices {
                    if top.count == 8, probabilities[token] <= probabilities[top.last!] { continue }
                    top.append(token)
                    top.sort { probabilities[$0] == probabilities[$1] ? $0 < $1 : probabilities[$0] > probabilities[$1] }
                    if top.count > 8 { top.removeLast() }
                }
                for token in top where probabilities[token].isFinite {
                    let ids = beam.ids + [Int32(token)]
                    let next = Beam(ids: ids, score: beam.score + probabilities[token])
                    let suffix = try decodedSuffix(ids)
                    let stops = suffix?.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last
                        .map { punctuation.contains($0) } ?? false
                    if token == 3 || stops { finished.append(next) } else { expanded.append(next) }
                }
            }
            active = Array(expanded.sorted { $0.score > $1.score }.prefix(8))
            if depth == maxTokens - 1 { finished += active.map { Beam(ids: $0.ids, score: $0.score, incomplete: true) } }
            if active.isEmpty { break }
        }
        if cancelled() { throw Failure.cancelled }
        finished.sort { $0.score / pow(Double(max(1, $0.ids.count)), 0.7) > $1.score / pow(Double(max(1, $1.ids.count)), 0.7) }
        var seen = Set<String>()
        var result = [Suggestion]()
        for beam in finished {
            guard let raw = try decodedSuffix(beam.ids), !raw.trimmingCharacters(in: trim).isEmpty else { continue }
            let key = raw.trimmingCharacters(in: trim)
            guard seen.insert(key).inserted else { continue }
            let end = raw.firstIndex { "。！？!?\n".contains($0) }
            let text = end.map { String(raw[...$0]) } ?? raw
            result.append(Suggestion(text: text, tokenIDs: beam.ids, logProbabilitySum: beam.score,
                                     incomplete: beam.incomplete && !(text.unicodeScalars.last.map { punctuation.contains($0) } ?? false)))
            if result.count == count { break }
        }
        return result
    }

}
