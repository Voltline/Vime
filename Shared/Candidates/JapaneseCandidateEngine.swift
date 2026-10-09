import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// azooKey generates candidates; Vime normalizes/reranks all sources together.
/// State and dictionary caches are confined to the worker queue in production.
nonisolated final class JapaneseCandidateEngine {
    private let dictionary = DicdataStore.withDefaultDictionary()
    private let converter: KanaKanjiConverter
    private var options: ConvertRequestOptions
    private let reranker = CandidateReranker()
    private var previousTop: CandidateContinuity?
    private var currentContinuity: CandidateContinuity?
    private var currentPool: [CandidateSnapshot] = []
    private var committedContext = ""
    private var contextCandidate: Candidate?
    private var contextSession: KanaKanjiConverter.ConversionSessionID?
    private var learningDirty = false
    private let preferenceMemory: CandidatePreferenceMemory?
    var diagnosticsEnabled = false
    private(set) var rawDiagnostics: [CandidateDiagnostic] = []
    private(set) var finalDiagnostics: [CandidateDiagnostic] = []
    private(set) var correctionQueryDiagnostics: [CorrectionQueryDiagnostic] = []
    let memoryDirectoryURL: URL
    // An optional trained n-gram model; absent models never trigger LM work.
    var experimentalTypoConfig: ExperimentalTypoCorrectionConfig?

    init(memoryDirectoryURL: URL? = nil, learningEnabled: Bool = false) {
        converter = KanaKanjiConverter(dicdataStore: dictionary)
        let localRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sharedRoot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.Voltline.Vime")
        let root = sharedRoot ?? localRoot
        var directory = memoryDirectoryURL ?? root.appendingPathComponent("Vime/AzooKeyMemory", isDirectory: true)
        var writable = true
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch {
            // An extension without shared-container access still learns locally.
            if memoryDirectoryURL == nil {
                directory = localRoot.appendingPathComponent("Vime/AzooKeyMemory", isDirectory: true)
                do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
                catch { writable = false }
            } else { writable = false }
        }
        self.memoryDirectoryURL = directory
        preferenceMemory = learningEnabled && writable ? CandidatePreferenceMemory(directory: directory) : nil
        options = ConvertRequestOptions(N_best: 10, requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled, keyboardLanguage: .ja_JP,
            learningType: learningEnabled && writable ? .inputAndOutput : .nothing,
            maxMemoryCount: Self.maximumLearningEntries, memoryDirectoryURL: directory,
            sharedContainerURL: root, textReplacer: .empty, specialCandidateProviders: [],
            typoCorrectionMode: .disabled, metadata: .init(versionString: "Vime"))
    }
    static let maximumLearningEntries = 8192
    private var alternativeSession: KanaKanjiConverter.ConversionSessionID?
    private var classicTypoSession: KanaKanjiConverter.ConversionSessionID?
    private var correctionSession: KanaKanjiConverter.ConversionSessionID?
    private var correctionCache: [String: [Candidate]] = [:]
    private var correctionCacheOrder: [String] = []
    private lazy var correctionIndex = CorrectionReadingIndex()
    static let maximumCorrectionQueries = 24
    static let correctionBudgetSeconds: TimeInterval = 0.060
    private(set) var lastCorrectionMetrics = CorrectionSearchMetrics()
    func candidates(for composing: ComposingText, katakana: Bool = false, revision: Int,
                    includeCorrections: Bool = true) -> [CandidateSnapshot] {
        guard !composing.isEmpty else { return [] }
        let query = composing
        currentContinuity = previousTop
        let conversionStarted = KeyboardPerformance.start()
        let result = converter.requestCandidates(query, options: options)
        KeyboardPerformance.record(.baseConversion, since: conversionStarted)
        let kana = query.convertTarget
        func snapshot(_ candidate: Candidate, source: CandidateSource, engineRank: Int = 0) -> CandidateSnapshot {
            var engineRemainder = query
            engineRemainder.prefixComplete(composingCount: candidate.composingCount)
            var remaining = query
            // Prediction selection commits the suggested completion of the
            // entire query, including an unresolved suffix. The upstream count
            // can describe only the resolved base; keep it intact as metadata.
            // acceptPredictionCandidate is a different API: it expands an
            // UNCOMMITTED composition and constrains subsequent neural queries.
            remaining.prefixComplete(composingCount: source == .prediction || source == .readingAlternative
                ? .inputCount(query.input.count) : candidate.composingCount)
            return CandidateSnapshot(candidate: candidate, revision: revision, source: source, remainingComposition: remaining,
                originalInputCount: query.input.count, consumedInputCount: query.input.count - remaining.input.count,
                queryReading: RomajiConverter.katakana(kana), engineRank: engineRank,
                engineFullConsumption: engineRemainder.isEmpty,
                readingOverride: source == .readingAlternative && candidate.data.isEmpty ? candidate.text : nil)
        }
        let scripts = katakana ? [RomajiConverter.katakana(kana), kana] : [kana, RomajiConverter.katakana(kana)]
        let scriptCandidates = scripts.map {
            snapshot(Candidate(text: $0, value: .zero, composingCount: .inputCount(query.input.count),
                               lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false), source: .scriptVariant)
        }
        let conversions = result.mainResults.enumerated().filter { $0.element.inputable }.map {
            snapshot($0.element, source: result.predictionResults.contains($0.element) ? .prediction : .conversion, engineRank: $0.offset)
        }
        let predictions = result.predictionResults.enumerated().filter { $0.element.inputable }.map {
            snapshot($0.element, source: .prediction,
                engineRank: result.mainResults.firstIndex(of: $0.element) ?? $0.offset)
        }
        var alternatives: [CandidateSnapshot] = []
        // Alternate readings only need exact conversions. Running prediction
        // for every alternate repeats expensive work that cannot be selected.
        var alternativeOptions = options
        alternativeOptions.N_best = 3
        alternativeOptions.requireJapanesePrediction = .disabled
        for alternative in RomajiConverter.nReadingAlternatives(for: query) {
            let session = alternativeSession ?? converter.createSession()
            alternativeSession = session
            // Separate conversion state, shared dictionary/cache; no second
            // dictionary instance and no mutation of the literal query session.
            guard let result = try? converter.withSession(session, operation: {
                // Alternative boundaries are unrelated queries. Incremental
                // separator replacement can leave invalid upstream lattice
                // ranges on long sentences; retain caches, discard that state.
                converter.stopComposition()
                return converter.requestCandidates(alternative, options: alternativeOptions)
            }) else { continue }
            let reading = RomajiConverter.katakana(alternative.convertTarget)
            let matches = result.mainResults.filter { candidate in
                guard candidate.inputable, candidate.data.count == 1,
                      candidate.text != reading,
                      candidate.data.map(\.ruby).joined() == reading else { return false }
                // Upstream injects a fixed-score hiragana fallback as a proper
                // noun/general entry. It is presentation, not dictionary evidence.
                if candidate.text == alternative.convertTarget,
                   candidate.data.first?.lcid == CIDData.固有名詞.cid,
                   candidate.data.first?.mid == MIDData.一般.mid { return false }
                var remainder = alternative; remainder.prefixComplete(composingCount: candidate.composingCount)
                return remainder.isEmpty
            }
            for candidate in matches {
                alternatives.append(snapshot(candidate, source: .readingAlternative))
            }
            // Keep the alternate kana selectable even if the dictionary prefers
            // a kanji spelling; only offer it when this reading has a match.
            if let best = matches.first {
                let kana = Candidate(text: alternative.convertTarget, value: best.value - 1,
                    composingCount: .inputCount(query.input.count), lastMid: MIDData.EOS.mid,
                    data: [], isLearningTarget: false)
                alternatives.append(snapshot(kana, source: .readingAlternative))
            }
        }
        // Preserve the established n interpretation's dictionary-score evidence
        // inside the unified model, instead of placing its array before literals.
        let literalScore = conversions.first { $0.exactReading && $0.fullConsumption }?.engineScore
        alternatives = alternatives.map { original in
            var value = original
            if let literalScore {
                value.interpretationGain = (value.engineScore - literalScore) / Double(max(3, value.reading.count))
            }
            return value
        }
        currentPool = conversions + predictions + scriptCandidates + alternatives
        if diagnosticsEnabled {
            rawDiagnostics = currentPool.enumerated().map { CandidateDiagnostic($0.element, rank: $0.offset + 1) }
        }
        let base = rank(currentPool, query: query, katakana: katakana)
        previousTop = base.first.map { .init(surface: $0.text, reading: $0.reading, input: Self.rawInput(query)) }
        return includeCorrections ? addingCorrections(to: base, for: query, katakana: katakana, revision: revision) : base
    }

    func seedContinuity(_ previous: CandidateContinuity?) { previousTop = previous }

    private func rank(_ pool: [CandidateSnapshot], query: ComposingText, katakana: Bool) -> [CandidateSnapshot] {
        let personalized = pool.map { original in
            var value = original
            if value.learningEligible && value.fullConsumption {
                value.userPreferenceScore = preferenceMemory?.score(reading: value.reading, surface: value.text) ?? 0
            }
            return value
        }
        let result = reranker.rank(personalized, input: Self.rawInput(query), katakana: katakana, previous: currentContinuity,
            context: { [self] value in contextGain(value) })
        if diagnosticsEnabled {
            finalDiagnostics = result.enumerated().map { CandidateDiagnostic($0.element, rank: $0.offset + 1) }
        }
        return Array(result.prefix(15))
    }

    private static func rawInput(_ query: ComposingText) -> String {
        query.input.compactMap { if case .character(let c) = $0.piece { return String(c) }; return nil }.joined()
    }

    func addingCorrections(to base: [CandidateSnapshot], for query: ComposingText, katakana: Bool,
                           revision: Int, cancelled: () -> Bool = { false }) -> [CandidateSnapshot] {
        let started = ProcessInfo.processInfo.systemUptime
        lastCorrectionMetrics = .init()
        correctionQueryDiagnostics = []
        defer { lastCorrectionMetrics.elapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        let generated = KeyboardCorrectionVariants.generate(for: query, cancelled: cancelled)
        let literalReading = RomajiConverter.katakana(query.convertTarget)
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
        for (index, variant) in generated.enumerated() { weighted.append((variant, priority(variant), index)) }
        // Rank complete two-sound hypotheses using the same lexical hints as
        // single edits. Do not require either intermediate reading to be valid.
        // This supplementary work shares the existing deadline and query limit.
        let paired = KeyboardCorrectionVariants.phoneticPairs(for: query, priority: priority,
            cancelled: { cancelled() || ProcessInfo.processInfo.systemUptime - started >= Self.correctionBudgetSeconds })
        for (index, variant) in paired.enumerated() {
            weighted.append((variant, priority(variant), generated.count + index))
        }
        weighted.sort {
            $0.priority == $1.priority ? $0.index < $1.index : $0.priority < $1.priority
        }
        let variants = weighted.map(\.variant)
        lastCorrectionMetrics.variants = variants.count
        guard !variants.isEmpty, !cancelled() else { return base }
        let originalQuality = base.filter {
            $0.remainingComposition.isEmpty && ($0.source == .conversion || $0.source == .readingAlternative)
                && ($0.source == .readingAlternative || $0.candidate.data.map(\.ruby).joined() == literalReading)
                && Self.hasDictionaryEvidence($0.candidate)
        }.map { Self.quality($0.candidate) }.max() ?? -8
        var correctionOptions = options
        correctionOptions.N_best = 2
        correctionOptions.requireJapanesePrediction = .disabled
        var matches: [(Candidate, KeyboardCorrectionVariants.Variant, Double)] = []
        var admittedReadings = Set<String>()
        for variant in variants {
            if admittedReadings.count >= CandidateCorrectionPolicy.maximumAdmittedReadings { break }
            // Preserve the existing first useful single-edit reading, while
            // allowing a paired sound reading to compete rather than being cut
            // off by an unrelated single-edit word found earlier.
            if !matches.isEmpty && variant.suggestion.editCount == 1 { continue }
            if cancelled() { lastCorrectionMetrics.cancelled = true; break }
            if lastCorrectionMetrics.queries >= Self.maximumCorrectionQueries
                || ProcessInfo.processInfo.systemUptime - started >= Self.correctionBudgetSeconds {
                lastCorrectionMetrics.budgetExhausted = true; break
            }
            let reading = RomajiConverter.katakana(variant.reading)
            let candidates: [Candidate]
            if let cached = correctionCache[reading] {
                lastCorrectionMetrics.cacheHits += 1
                candidates = cached
            } else {
                lastCorrectionMetrics.queries += 1
                var corrected = ComposingText()
                corrected.insertAtCursorPosition(variant.reading, inputStyle: .direct)
                let session = correctionSession ?? converter.createSession()
                correctionSession = session
                let result = try? converter.withSession(session) {
                    converter.stopComposition()
                    return converter.requestCandidates(corrected, options: correctionOptions)
                }
                candidates = (result?.mainResults ?? []).filter { candidate in
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
            }
            for candidate in candidates {
                // Lattice scores include lexical and word-connection costs.
                // Normalize by reading length before comparing edits of unequal
                // length; this is a ranking heuristic, not a probability.
                let length = Double(max(3, variant.reading.count))
                let score = Self.quality(candidate) - variant.suggestion.errorCost * CandidateCorrectionPolicy.channelWeight / length
                let margin = (CandidateCorrectionPolicy.admissionMargin
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
        let classicStarted = KeyboardPerformance.start()
        if matches.isEmpty, !cancelled(), Self.supportsClassicTypo(query) {
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
        }
        if matches.isEmpty, let config = experimentalTypoConfig, !cancelled() {
            let lmStarted = KeyboardPerformance.start()
            let proposals = converter.experimentalRequestTypoCorrection(leftSideContext: committedContext,
                composingText: query, options: correctionOptions, inputStyle: .roman2kana, config: config)
            KeyboardPerformance.record(.experimentalTypo, since: lmStarted)
            for proposal in proposals where proposal.channelCost > 0 && proposal.prominence >= CandidateCorrectionPolicy.minimumProminence {
                guard !cancelled() else { break }
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
        }
        guard !cancelled(), !matches.isEmpty else { return base }
        matches.sort { $0.2 == $1.2 ? $0.0.text < $1.0.text : $0.2 > $1.2 }
        var seen = Set(base.map(CandidateIdentity.init))
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
            if let index = base.firstIndex(where: { CandidateIdentity($0) == identity }) {
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
            if let replacement = replacements[base.firstIndex(where: { CandidateIdentity($0) == CandidateIdentity(item.element) }) ?? -1] {
                return replacement
            }
            return item.element
        } + additions
        return rank(pool, query: query, katakana: katakana)
    }

    /// Pinned classic Roman channels, not a word list. Bound the non-cancellable
    /// lattice call; the broader topology/phonetic search checks cancellation.
    private static func supportsClassicTypo(_ query: ComposingText) -> Bool {
        guard query.input.count <= 12 else { return false }
        let roman = rawInput(query)
        let channels = ["bs", "no", "li", "lo", "lu", "my", "tp", "ts", "wi", "pu"]
        return query.input.allSatisfy { $0.inputStyle == .direct } || channels.contains { roman.contains($0) }
    }

    private static func hiragana(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map {
            (0x30A1...0x30F6).contains($0.value) ? UnicodeScalar($0.value - 0x60)! : $0
        }))
    }

    private static func quality(_ candidate: Candidate) -> Double {
        Double(candidate.value) / Double(max(3, candidate.data.map(\.ruby).joined().count))
    }

    /// Reject upstream's presentation-only kana fallbacks, including ones used
    /// as lattice pieces. A sentence can contain multiple real dictionary words.
    static func hasDictionaryEvidence(_ candidate: Candidate) -> Bool {
        !candidate.data.isEmpty && candidate.data.allSatisfy { element in
            guard !element.ruby.isEmpty,
                  !element.ruby.unicodeScalars.contains(where: { $0.isASCII }) else { return false }
            return !isKanaFallback(element)
        }
    }

    private static func isKanaFallback(_ element: DicdataElement) -> Bool {
        element.lcid == CIDData.固有名詞.cid && element.mid == MIDData.一般.mid
            && (element.word == element.ruby || RomajiConverter.katakana(element.word) == element.ruby)
    }

    private static func changedRange(_ original: [Character], _ corrected: [Character]) -> Range<Int> {
        var prefix = 0
        while prefix < min(original.count, corrected.count), original[prefix] == corrected[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(original.count, corrected.count) - prefix,
              original[original.count - suffix - 1] == corrected[corrected.count - suffix - 1] { suffix += 1 }
        return prefix..<max(prefix + 1, original.count - suffix)
    }

    private func contextGain(_ value: CandidateSnapshot) -> Double {
        guard let left = contextCandidate?.data.last, let right = value.candidate.data.first,
              value.lexical else { return 0 }
        return Double(dictionary.getCCValue(left.rcid, right.lcid)
            - dictionary.getCCValue(CIDData.BOS.cid, right.lcid)
            + dictionary.getMMValue(left.mid, right.mid))
    }

    /// Reconcile against real host text (already excluding the marked range).
    /// No replayed learning: parsing external context only supplies POS evidence.
    func reconcileContext(_ left: String?) {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.contextEvaluation, since: started) }
        let text = String((left ?? "").suffix(96))
        guard text != committedContext else { return }
        committedContext = text; contextCandidate = nil; previousTop = nil
        converter.stopComposition()
        correctionCache = [:]; correctionCacheOrder = []
        guard !text.isEmpty else { return }
        var query = ComposingText(); query.insertAtCursorPosition(text, inputStyle: .direct)
        let session = contextSession ?? converter.createSession(); contextSession = session
        var contextOptions = options; contextOptions.N_best = 1
        contextOptions.requireJapanesePrediction = .disabled
        contextCandidate = try? converter.withSession(session) {
            converter.stopComposition()
            return converter.requestCandidates(query, options: contextOptions).mainResults.first
        }
    }

    func complete(_ snapshot: CandidateSnapshot) {
        converter.setCompletedData(snapshot.candidate)
        if snapshot.learningEligible {
            converter.updateLearningData(snapshot.candidate)
            if snapshot.fullConsumption { preferenceMemory?.record(reading: snapshot.reading, surface: snapshot.text) }
            learningDirty = true
            correctionCache = [:]; correctionCacheOrder = []
        }
        committedContext = String((committedContext + snapshot.text).suffix(96))
        contextCandidate = snapshot.lexical ? snapshot.candidate : nil
    }

    func flushLearning() {
        preferenceMemory?.flush()
        guard learningDirty else { return }
        converter.commitUpdateLearningData(); learningDirty = false
    }

    func clearLearning() {
        // This pinned version exposes LearningConfig without a public initializer.
        // A nonempty request applies our existing public request configuration.
        var bootstrap = ComposingText(); bootstrap.insertAtCursorPosition("　", inputStyle: .direct)
        _ = converter.requestCandidates(bootstrap, options: options)
        converter.resetMemory(); learningDirty = false
        preferenceMemory?.clear()
        correctionCache = [:]; correctionCacheOrder = []
        reset()
    }

    func personalizedNextWords(_ words: [String], context: String) -> [NextWordSuggestion] {
        preferenceMemory?.nextWords(words, context: context) ?? words.enumerated().map {
            NextWordSuggestion(text: $0.element, source: .contextPrediction,
                score: -Double($0.offset) * CandidatePreferenceMemory.Policy.nextWordOrderWeight, userScore: 0)
        }
    }
    func completeNextWord(_ text: String, context: String) {
        preferenceMemory?.recordNextWord(text, context: context)
        preferenceMemory?.flush()
    }

    func reset(preservingContext: Bool = false) {
        converter.stopComposition(); previousTop = nil; currentContinuity = nil; currentPool = []
        if !preservingContext { committedContext = ""; contextCandidate = nil }
        for session in [alternativeSession, correctionSession, classicTypoSession, contextSession].compactMap({ $0 }) {
            try? converter.withSession(session) { converter.stopComposition() }
        }
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
