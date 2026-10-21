import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// Idle-time typo and phonetic correction search over the literal candidate pool.
nonisolated extension JapaneseCandidateEngine {
    typealias CorrectionMatch = (candidate: Candidate, variant: KeyboardCorrectionVariants.Variant, score: Double)

    func addingCorrections(to base: [CandidateSnapshot], for query: ComposingText, katakana: Bool,
                           revision: Int, cancelled: () -> Bool = { false },
                           now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> [CandidateSnapshot] {
        let started = now()
        let deadline = started + Self.correctionBudgetSeconds
        lastCorrectionMetrics = .init()
        correctionQueryDiagnostics = []
        defer { lastCorrectionMetrics.elapsedMs = (now() - started) * 1000 }
        func stopSearch() -> Bool {
            if cancelled() { lastCorrectionMetrics.cancelled = true; return true }
            if now() >= deadline { lastCorrectionMetrics.budgetExhausted = true; return true }
            return false
        }
        guard !stopSearch() else { return base }
        let literalReading = RomajiConverter.katakana(query.convertTarget)
        guard let variants = rankedCorrectionVariants(for: query, base: base, literalReading: literalReading, stopSearch: stopSearch)
        else { return base }
        lastCorrectionMetrics.variants = variants.count
        guard !variants.isEmpty, !stopSearch() else { return base }
        let originalQuality = base.filter {
            $0.remainingComposition.isEmpty && ($0.source == .conversion || $0.source == .readingAlternative || $0.source == .userDictionary)
                && ($0.source == .readingAlternative || $0.candidate.data.map(\.ruby).joined() == literalReading)
                && Self.hasDictionaryEvidence($0.candidate)
        }.map { Self.quality($0.candidate) }.max() ?? -8
        var correctionOptions = options
        correctionOptions.N_best = 2
        correctionOptions.requireJapanesePrediction = .disabled
        var matches = readingCorrections(variants, for: query, originalQuality: originalQuality,
                                         options: correctionOptions, stopSearch: stopSearch)
        if matches.isEmpty {
            matches = classicTypoCorrections(for: query, literalReading: literalReading, originalQuality: originalQuality,
                                             options: correctionOptions, stopSearch: stopSearch)
        }
        if matches.isEmpty {
            matches = experimentalTypoCorrections(for: query, literalReading: literalReading, originalQuality: originalQuality,
                                                  options: correctionOptions, stopSearch: stopSearch)
        }
        guard !cancelled(), !matches.isEmpty else { return base }
        return merging(matches, into: base, query: query, katakana: katakana, revision: revision,
                       literalReading: literalReading, originalQuality: originalQuality)
    }

    /// Candidate readings ordered by edit cost and the local lexical gain of the
    /// edited span over the literal reading's best segmentation. Nil on stop.
    func rankedCorrectionVariants(for query: ComposingText, base: [CandidateSnapshot], literalReading: String,
                                  stopSearch: () -> Bool) -> [KeyboardCorrectionVariants.Variant]? {
        let generated = KeyboardCorrectionVariants.generate(for: query, cancelled: stopSearch)
        guard !stopSearch() else { return nil }
        let evidence = base.first { $0.remainingComposition.isEmpty && $0.candidate.data.map(\.ruby).joined() == literalReading }
        var fallbackRanges: [Range<Int>] = []
        var segments: [Range<Int>] = []
        var offset = 0
        for element in evidence?.candidate.data ?? [] {
            let end = offset + element.ruby.count
            if end > offset { segments.append(offset..<end) }
            if Self.isKanaFallback(element) || element.ruby.unicodeScalars.contains(where: { $0.isASCII }) {
                fallbackRanges.append(offset..<end)
            }
            offset = end
        }
        let originalCharacters = Array(query.convertTarget)
        let originalData = evidence?.candidate.data ?? []
        func localGain(_ entry: CorrectionReadingIndex.Entry, start: Int, end: Int) -> Double {
            let left = start > 0 ? originalData[start - 1].rcid : CIDData.BOS.cid
            let right = end + 1 < originalData.count ? originalData[end + 1].lcid : CIDData.EOS.cid
            var old = 0.0, previous = left
            for element in originalData[start...end] {
                old += Double(element.value() + dictionary.getCCValue(previous, element.lcid))
                previous = element.rcid
            }
            old += Double(dictionary.getCCValue(previous, right))
            let new = entry.value + Double(dictionary.getCCValue(left, entry.lcid) + dictionary.getCCValue(entry.rcid, right))
            return new - old
        }
        func priority(_ variant: KeyboardCorrectionVariants.Variant) -> Double {
            guard !stopSearch() else { return .infinity }
            let characters = Array(variant.reading)
            let changed = Self.changedRange(originalCharacters, characters)
            let repairsFallback = fallbackRanges.contains { $0.overlaps(changed) }
            var gain: Double?
            let wholeWord = correctionIndex.entry(for: variant.reading)
            if let wholeWord, !originalData.isEmpty {
                gain = localGain(wholeWord, start: 0, end: originalData.count - 1)
            }
            let delta = characters.count - originalCharacters.count
            for index in segments.indices where segments[index].overlaps(changed) {
                guard !stopSearch() else { return .infinity }
                let minimumWordLength = segments[index].count == 1 ? 3 : 2
                for startIndex in max(0, index - 1)...index {
                    for endIndex in index...min(segments.count - 1, index + 1) {
                        let start = segments[startIndex].lowerBound
                        let originalEnd = segments[endIndex].upperBound
                        let end = originalEnd + delta
                        guard start <= changed.lowerBound, originalEnd >= changed.upperBound,
                              start >= 0, end <= characters.count, end - start >= minimumWordLength,
                              end - start <= 12 else { continue }
                        if let entry = correctionIndex.entry(for: String(characters[start..<end])) {
                            gain = max(gain ?? -.infinity, localGain(entry, start: startIndex, end: endIndex))
                        }
                    }
                }
            }
            return variant.suggestion.errorCost - (repairsFallback ? 0.25 : 0) - (gain ?? -4) / 4
                - (wholeWord == nil ? 0 : CandidateCorrectionPolicy.wholeWordPriorityBonus)
        }
        var weighted: [(variant: KeyboardCorrectionVariants.Variant, priority: Double, index: Int)] = []
        for (index, variant) in generated.enumerated() {
            guard !stopSearch() else { return nil }
            weighted.append((variant, priority(variant), index))
        }
        // Rank complete two-sound hypotheses using the same lexical hints as
        // single edits. Do not require either intermediate reading to be valid.
        // This supplementary work shares the existing deadline and query limit.
        let paired = KeyboardCorrectionVariants.phoneticPairs(for: query, priority: priority, cancelled: stopSearch)
        for (index, variant) in paired.enumerated() {
            guard !stopSearch() else { return nil }
            weighted.append((variant, priority(variant), generated.count + index))
        }
        guard !stopSearch() else { return nil }
        weighted.sort {
            $0.priority == $1.priority ? $0.index < $1.index : $0.priority < $1.priority
        }
        return weighted.map(\.variant)
    }

    /// Converts each ranked reading and admits words that beat the literal
    /// reading by a length-normalized margin.
    func readingCorrections(_ variants: [KeyboardCorrectionVariants.Variant], for query: ComposingText,
                            originalQuality: Double, options correctionOptions: ConvertRequestOptions,
                            stopSearch: () -> Bool) -> [CorrectionMatch] {
        var matches: [CorrectionMatch] = []
        var admittedReadings = Set<String>()
        for variant in variants {
            if stopSearch() { break }
            if admittedReadings.count >= CandidateCorrectionPolicy.maximumAdmittedReadings { break }
            // Preserve the existing first useful single-edit reading, while
            // allowing a paired sound reading to compete rather than being cut
            // off by an unrelated single-edit word found earlier.
            if !matches.isEmpty && variant.suggestion.editCount == 1 { continue }
            if lastCorrectionMetrics.queries >= Self.maximumCorrectionQueries {
                lastCorrectionMetrics.budgetExhausted = true; break
            }
            let candidates = verifiedCorrectionCandidates(for: variant, options: correctionOptions)
            for candidate in candidates {
                // Lattice scores include lexical and word-connection costs.
                // Normalize by reading length before comparing edits of unequal
                // length; this is a ranking heuristic, not a probability.
                let length = Double(max(3, variant.reading.count))
                let score = Self.quality(candidate) - variant.suggestion.errorCost * CandidateCorrectionPolicy.channelWeight / length
                let margin = ((query.convertTarget.count == 2 ? CandidateCorrectionPolicy.shortReadingMargin : CandidateCorrectionPolicy.admissionMargin)
                    + Double(variant.suggestion.editCount - 1) * CandidateCorrectionPolicy.additionalSoundEditMargin)
                    / Double(max(3, query.convertTarget.count))
                if Self.quality(candidate) > CandidateCorrectionPolicy.minimumQuality, score > originalQuality + margin {
                    matches.append((candidate, variant, score))
                    admittedReadings.insert(variant.reading)
                }
                if diagnosticsEnabled {
                    correctionQueryDiagnostics.append(.init(reading: variant.reading, editCount: variant.suggestion.editCount,
                        quality: Self.quality(candidate), adjustedQuality: score, requiredQuality: originalQuality + margin,
                        admitted: Self.quality(candidate) > CandidateCorrectionPolicy.minimumQuality && score > originalQuality + margin))
                }
            }
            if diagnosticsEnabled && candidates.isEmpty {
                correctionQueryDiagnostics.append(.init(reading: variant.reading, editCount: variant.suggestion.editCount,
                    quality: nil, adjustedQuality: nil, requiredQuality: nil, admitted: false))
            }
            // Admission and query counts stay bounded; after one reading only
            // paired hypotheses are considered, never more unrelated single edits.
        }
        return matches
    }

    /// Dictionary words that consume exactly this reading, cached across
    /// requests until the dictionary or learning state changes.
    func verifiedCorrectionCandidates(for variant: KeyboardCorrectionVariants.Variant,
                                      options correctionOptions: ConvertRequestOptions) -> [Candidate] {
        let reading = RomajiConverter.katakana(variant.reading)
        if let cached = correctionCache[reading] {
            lastCorrectionMetrics.cacheHits += 1
            return cached
        }
        lastCorrectionMetrics.queries += 1
        var corrected = ComposingText()
        corrected.insertAtCursorPosition(variant.reading, inputStyle: .direct)
        let session = correctionSession ?? converter.createSession()
        correctionSession = session
        let result = try? converter.withSession(session) {
            converter.stopComposition()
            return converter.requestCandidates(corrected, options: correctionOptions)
        }
        let candidates = (result?.mainResults ?? []).filter { candidate in
            guard candidate.inputable, candidate.data.map(\.ruby).joined() == reading,
                  Self.hasDictionaryEvidence(candidate) else { return false }
            var remaining = corrected
            remaining.prefixComplete(composingCount: candidate.composingCount)
            return remaining.isEmpty
        }
        correctionCache[reading] = candidates
        correctionCacheOrder.append(reading)
        if correctionCacheOrder.count > CandidateCorrectionPolicy.maximumCachedReadings {
            correctionCache.removeValue(forKey: correctionCacheOrder.removeFirst())
        }
        return candidates
    }

    func classicTypoCorrections(for query: ComposingText, literalReading: String, originalQuality: Double,
                                options correctionOptions: ConvertRequestOptions, stopSearch: () -> Bool) -> [CorrectionMatch] {
        let classicStarted = KeyboardPerformance.start()
        guard !stopSearch(), Self.supportsClassicTypo(query) else { return [] }
        var classicOptions = correctionOptions; classicOptions.typoCorrectionMode = .enabled
        let classicSession = classicTypoSession ?? converter.createSession(); classicTypoSession = classicSession
        let classic: [Candidate] = (try? converter.withSession(classicSession) {
            converter.stopComposition()
            return converter.requestCandidates(query, options: classicOptions).mainResults
        }) ?? []
        KeyboardPerformance.record(.classicTypo, since: classicStarted)
        // The pinned classic table supports a limited set of Roman substitutions
        // and kana voicing. Apply the same dictionary/evidence admission gate as
        // topology search; correct literal input must never become a correction.
        var matches: [CorrectionMatch] = []
        for candidate in classic where Self.hasDictionaryEvidence(candidate) {
            let ruby = candidate.data.map(\.ruby).joined()
            var remaining = query; remaining.prefixComplete(composingCount: candidate.composingCount)
            let score = Self.quality(candidate) - CandidateCorrectionPolicy.channelWeight / Double(max(3, ruby.count))
            guard remaining.isEmpty, ruby != literalReading, Self.quality(candidate) > CandidateCorrectionPolicy.minimumQuality,
                  score > originalQuality + CandidateCorrectionPolicy.admissionMargin / Double(max(3, query.convertTarget.count)) else { continue }
            let reading = Self.hiragana(ruby)
            let suggestion = CorrectionSuggestion(originalReading: query.convertTarget, suggestedReading: reading,
                correctedRomanInput: nil, kind: .phonetic, rangeOffset: 0,
                rangeLength: query.convertTarget.count, rangeUnit: .kanaReading, errorCost: 1,
                originalInput: Self.rawInput(query), method: "azooKeyClassic")
            matches.append((candidate, .init(reading: reading, suggestion: suggestion), score))
        }
        return matches
    }

    func experimentalTypoCorrections(for query: ComposingText, literalReading: String, originalQuality: Double,
                                     options correctionOptions: ConvertRequestOptions, stopSearch: () -> Bool) -> [CorrectionMatch] {
        guard let config = experimentalTypoConfig, !stopSearch() else { return [] }
        let lmStarted = KeyboardPerformance.start()
        let proposals = converter.experimentalRequestTypoCorrection(leftSideContext: committedContext,
            composingText: query, options: correctionOptions, inputStyle: .roman2kana, config: config)
        KeyboardPerformance.record(.experimentalTypo, since: lmStarted)
        var matches: [CorrectionMatch] = []
        for proposal in proposals where proposal.channelCost > 0 && proposal.prominence >= CandidateCorrectionPolicy.minimumProminence {
            guard !stopSearch() else { break }
            var corrected = ComposingText(); RomajiConverter.insert(proposal.correctedInput, into: &corrected)
            let reading = corrected.convertTarget
            guard RomajiConverter.katakana(reading) != literalReading else { continue }
            let session = correctionSession ?? converter.createSession(); correctionSession = session
            let verified: [Candidate] = (try? converter.withSession(session) {
                converter.stopComposition()
                return converter.requestCandidates(corrected, options: correctionOptions).mainResults
            }) ?? []
            for candidate in verified where Self.hasDictionaryEvidence(candidate)
                && candidate.data.map(\.ruby).joined() == RomajiConverter.katakana(reading) {
                var remainder = corrected; remainder.prefixComplete(composingCount: candidate.composingCount)
                let score = Self.quality(candidate) - Double(proposal.channelCost) / Double(max(3, reading.count))
                guard remainder.isEmpty, score > originalQuality + CandidateCorrectionPolicy.admissionMargin / Double(max(3, query.convertTarget.count)) else { continue }
                let suggestion = CorrectionSuggestion(originalReading: query.convertTarget, suggestedReading: reading,
                    correctedRomanInput: proposal.correctedInput, kind: .phonetic, rangeOffset: 0,
                    rangeLength: query.input.count, rangeUnit: .romanInput, errorCost: Double(proposal.channelCost),
                    originalInput: Self.rawInput(query), lmScore: Double(proposal.lmScore),
                    convertedText: proposal.convertedText, prominence: Double(proposal.prominence), method: "azooKeyExperimental")
                matches.append((candidate, .init(reading: reading, suggestion: suggestion), score))
            }
        }
        return matches
    }

    /// Adds admitted corrections (word and kana forms) to the pool, refreshing
    /// stale predictions of the same word, and reranks everything together.
    func merging(_ matches: [CorrectionMatch], into base: [CandidateSnapshot], query: ComposingText, katakana: Bool,
                 revision: Int, literalReading: String, originalQuality: Double) -> [CandidateSnapshot] {
        let matches = matches.sorted { $0.score == $1.score ? $0.candidate.text < $1.candidate.text : $0.score > $1.score }
        // First position of each identity, as base.firstIndex(where:) found it.
        var baseIndex: [CandidateIdentity: Int] = [:]
        for (index, value) in base.enumerated() where baseIndex[CandidateIdentity(value)] == nil {
            baseIndex[CandidateIdentity(value)] = index
        }
        var seen = Set(baseIndex.keys)
        var additions: [CandidateSnapshot] = []
        var replacements: [Int: CandidateSnapshot] = [:]
        var handled = Set<CandidateIdentity>()
        func append(_ candidate: Candidate, variant: KeyboardCorrectionVariants.Variant) {
            var snapshot = CandidateSnapshot(candidate: candidate, revision: revision, source: .typoCorrection,
                remainingComposition: ComposingText(), originalInputCount: query.input.count,
                consumedInputCount: query.input.count, correction: variant.suggestion,
                queryReading: literalReading, engineRank: 0)
            snapshot.interpretationGain = Self.quality(candidate)
                - variant.suggestion.errorCost * CandidateCorrectionPolicy.channelWeight / Double(max(3, snapshot.reading.count))
                - originalQuality
            let identity = CandidateIdentity(snapshot)
            guard handled.insert(identity).inserted else { return }
            if let index = baseIndex[identity] {
                let old = base[index]
                let ruby = old.candidate.data.map(\.ruby).joined()
                // Keep exact literal matches and actual prefix completions.
                // A stale upstream prediction of a different full reading may
                // share this word; refresh its verified correction metadata.
                if old.source == .readingAlternative || old.source == .scriptVariant || ruby == literalReading
                    || ruby.hasPrefix(literalReading) { return }
                replacements[index] = snapshot
            } else if seen.insert(identity).inserted { additions.append(snapshot) }
        }
        for (candidate, variant, _) in matches {
            append(candidate, variant: variant)
            if additions.count + replacements.count >= CandidateCorrectionPolicy.maximumPresentedCorrections { break }
            var kana = candidate
            kana.text = katakana ? RomajiConverter.katakana(variant.reading) : variant.reading
            kana.isLearningTarget = false
            append(kana, variant: variant)
            if additions.count + replacements.count >= CandidateCorrectionPolicy.maximumPresentedCorrections { break }
        }
        guard !additions.isEmpty || !replacements.isEmpty else { return base }
        let pool = (currentPool.first?.revision == revision ? currentPool : base).enumerated().map { item in
            if let replacement = replacements[baseIndex[CandidateIdentity(item.element)] ?? -1] {
                return replacement
            }
            return item.element
        } + additions
        return rank(pool, query: query, katakana: katakana)
    }

    /// Pinned classic Roman channels, not a word list. Bound the non-cancellable
    /// lattice call; the broader topology/phonetic search checks cancellation.
    static func supportsClassicTypo(_ query: ComposingText) -> Bool {
        guard query.input.count <= 12 else { return false }
        let roman = rawInput(query)
        let channels = ["bs", "no", "li", "lo", "lu", "my", "tp", "ts", "wi", "pu"]
        return query.input.allSatisfy { $0.inputStyle == .direct } || channels.contains { roman.contains($0) }
    }

    static func hiragana(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map {
            (0x30A1...0x30F6).contains($0.value) ? UnicodeScalar($0.value - 0x60)! : $0
        }))
    }

    static func quality(_ candidate: Candidate) -> Double {
        Double(candidate.value) / Double(max(3, candidate.data.map(\.ruby).joined().count))
    }

    static let literalSeparators = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)

    /// A literal conversion may contain an unknown name, number or Latin word
    /// alongside attested words. Corrections still require whole-candidate
    /// dictionary evidence through hasDictionaryEvidence below.
    static func hasConversionEvidence(_ candidate: Candidate) -> Bool {
        candidate.data.contains { element in
            !element.word.isEmpty && !element.ruby.isEmpty
                && !element.word.unicodeScalars.allSatisfy { literalSeparators.contains($0) }
                && !element.ruby.unicodeScalars.contains(where: { $0.isASCII })
                && (element.metadata.contains(.isFromUserDictionary) || !isKanaFallback(element))
        }
    }

    /// Literal separators are neutral: upstream can encode a bracket using the
    /// same IDs as an unknown kana fallback. Require at least one dictionary word
    /// and continue rejecting unknown word pieces anywhere in the sentence.
    static func hasDictionaryEvidence(_ candidate: Candidate) -> Bool {
        var hasWord = false
        for element in candidate.data {
            if !element.word.isEmpty, element.word == element.ruby,
               element.word.unicodeScalars.allSatisfy({ literalSeparators.contains($0) }) {
                continue
            }
            guard !element.ruby.isEmpty,
                  !element.ruby.unicodeScalars.contains(where: { $0.isASCII }) else { return false }
            guard element.metadata.contains(.isFromUserDictionary) || !isKanaFallback(element) else { return false }
            hasWord = true
        }
        return hasWord
    }

    static func isKanaFallback(_ element: DicdataElement) -> Bool {
        element.lcid == CIDData.固有名詞.cid && element.mid == MIDData.一般.mid
            && (element.word == element.ruby || RomajiConverter.katakana(element.word) == element.ruby)
    }

    static func changedRange(_ original: [Character], _ corrected: [Character]) -> Range<Int> {
        var prefix = 0
        while prefix < min(original.count, corrected.count), original[prefix] == corrected[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(original.count, corrected.count) - prefix,
              original[original.count - suffix - 1] == corrected[corrected.count - suffix - 1] { suffix += 1 }
        return prefix..<max(prefix + 1, original.count - suffix)
    }
}

nonisolated struct CorrectionSearchMetrics: Codable, Sendable {
    var variants = 0
    var queries = 0
    var cacheHits = 0
    var elapsedMs = 0.0
    var budgetExhausted = false
    var cancelled = false
}

nonisolated struct CorrectionQueryDiagnostic: Codable, Sendable {
    let reading: String
    let editCount: Int
    let quality: Double?
    let adjustedQuality: Double?
    let requiredQuality: Double?
    let admitted: Bool
}
