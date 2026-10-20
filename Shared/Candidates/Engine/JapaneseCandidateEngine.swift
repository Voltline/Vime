import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// azooKey generates candidates; Vime normalizes/reranks all sources together.
/// State and dictionary caches are confined to the worker queue in production.
nonisolated final class JapaneseCandidateEngine {
    let dictionary = DicdataStore.withDefaultDictionary()
    let converter: KanaKanjiConverter
    var options: ConvertRequestOptions
    let reranker = CandidateReranker()
    var previousTop: CandidateContinuity?
    var currentContinuity: CandidateContinuity?
    var currentPool: [CandidateSnapshot] = []
    var primaryQuery: ComposingText?
    var committedContext = ""
    var contextCandidate: Candidate?
    let userDictionary: JapaneseUserDictionaryStore
    let textReplacer = TextReplacer.withDefaultEmojiDictionary()
    let specialProviders: [any SpecialCandidateProvider] = [
        CalendarSpecialCandidateProvider(), TimeExpressionSpecialCandidateProvider(),
        CommaSeparatedNumberSpecialCandidateProvider()
    ]
    let asciiSpecialProviders: [any SpecialCandidateProvider] = [UnicodeSpecialCandidateProvider(), EmailAddressSpecialCandidateProvider()]
    var installedShortcuts: [DicdataElement] = []
    var contextSession: KanaKanjiConverter.ConversionSessionID?
    var learningDirty = false
    var learningSession: KanaKanjiConverter.ConversionSessionID?
    struct PendingFeedback {
        var snapshot: CandidateSnapshot? = nil
        let text: String
        let event: CandidateLearningFeedback
        let learningEpoch: UUID?
        var nativePrediction: NativePostCompositionPrediction? = nil
    }
    var pendingFeedback: PendingFeedback?
    var feedbackAccepted = 0
    var feedbackCancelled = 0
    let preferenceMemory: CandidatePreferenceMemory?
    var diagnosticsEnabled = false
    private(set) var rawDiagnostics: [CandidateDiagnostic] = []
    private(set) var finalDiagnostics: [CandidateDiagnostic] = []
    var correctionQueryDiagnostics: [CorrectionQueryDiagnostic] = []
    let memoryDirectoryURL: URL
    // An optional trained n-gram model; absent models never trigger LM work.
    var experimentalTypoConfig: ExperimentalTypoCorrectionConfig?

    init(memoryDirectoryURL: URL? = nil, learningEnabled: Bool = false, userDictionary: JapaneseUserDictionaryStore? = nil,
         conversionCandidateLimit: Int = 10) {
        self.userDictionary = userDictionary ?? JapaneseUserDictionaryStore()
        converter = KanaKanjiConverter(dicdataStore: dictionary)
        let localRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sharedRoot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.Voltline.Vime")
        let root = sharedRoot ?? localRoot
        var directory = memoryDirectoryURL ?? root.appendingPathComponent("Vime/AzooKeyMemory", isDirectory: true)
#if DEBUG && targetEnvironment(simulator)
        // Installed-extension UI tests use their own archive, never normal history.
        if memoryDirectoryURL == nil,
           let id = UserDefaults(suiteName: KeyboardPreferences.appGroup)?.string(forKey: "VimeExtensionLearningTestID"),
           let uuid = UUID(uuidString: id) {
            directory = root.appendingPathComponent("Vime/Testing/Learning/" + uuid.uuidString, isDirectory: true)
        }
#endif
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
        options = ConvertRequestOptions(N_best: max(1, conversionCandidateLimit), requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled, keyboardLanguage: .ja_JP,
            learningType: learningEnabled && writable ? .inputAndOutput : .nothing,
            maxMemoryCount: Self.maximumLearningEntries, memoryDirectoryURL: directory,
            sharedContainerURL: root, textReplacer: textReplacer, specialCandidateProviders: [],
            typoCorrectionMode: .disabled, metadata: .init(versionString: "Vime"))
    }
    static let maximumLearningEntries = 8192

    /// Parse small bundled packs and the user's dictionary before the first
    /// key. Native dictionary shards remain demand-loaded; no synthetic input
    /// or learning event is needed to prepare a newly created engine.
    func prepareForInput() {
        _ = JapaneseLanguageResources.shared
        _ = userDictionary.nativeEntries()
    }

    /// An n-boundary alternate keeps its separator at a fixed input index while
    /// typing continues at the end, so one session per shape extends its lattice
    /// incrementally. Moving a separator within one session is never attempted.
    struct AlternativeShape: Hashable {
        let separator: Int
        let inserted: Int
    }
    var alternativeSessions: [AlternativeShape: KanaKanjiConverter.ConversionSessionID] = [:]
    var alternativeSessionOrder: [AlternativeShape] = []
    static let maximumAlternativeSessions = 6
    var classicTypoSession: KanaKanjiConverter.ConversionSessionID?
    var prefixSession: KanaKanjiConverter.ConversionSessionID?
    var widthSession: KanaKanjiConverter.ConversionSessionID?
    var installedWords: [DicdataElement] = []
    var correctionSession: KanaKanjiConverter.ConversionSessionID?
    var correctionCache: [String: [Candidate]] = [:]
    var correctionCacheOrder: [String] = []
    lazy var correctionIndex = CorrectionReadingIndex()
    var firstClausePrefixCache = NativeResultCache(capacity: 8)
    /// Every change to the dynamic dictionary or native learning invalidates
    /// results reused across requests.
    func invalidateNativeResults() {
        correctionCache = [:]; correctionCacheOrder = []
        firstClausePrefixCache.removeAll()
        removeAlternativeSessions()
    }

    func alternativeSession(for alternative: ComposingText, query: ComposingText) -> KanaKanjiConverter.ConversionSessionID {
        let shape = AlternativeShape(separator: alternative.input.firstIndex { $0.piece == .compositionSeparator } ?? -1,
                                     inserted: alternative.input.count - query.input.count)
        if let session = alternativeSessions[shape] {
            if let index = alternativeSessionOrder.firstIndex(of: shape) { alternativeSessionOrder.remove(at: index) }
            alternativeSessionOrder.append(shape)
            return session
        }
        if alternativeSessionOrder.count >= Self.maximumAlternativeSessions,
           let session = alternativeSessions.removeValue(forKey: alternativeSessionOrder.removeFirst()) {
            converter.removeSession(session)
        }
        let session = converter.createSession()
        alternativeSessions[shape] = session
        alternativeSessionOrder.append(shape)
        return session
    }

    func removeAlternativeSessions() {
        for session in alternativeSessions.values { converter.removeSession(session) }
        alternativeSessions = [:]; alternativeSessionOrder = []
    }
    static let maximumCorrectionQueries = 24
    static let correctionBudgetSeconds: TimeInterval = 0.060
    var lastCorrectionMetrics = CorrectionSearchMetrics()
    func candidates(for composing: ComposingText, katakana: Bool = false, revision: Int,
                    includeCorrections: Bool = true, conversionLength: Int? = nil,
                    trace: CandidatePipelineTrace? = nil,
                    cancelled: () -> Bool = { false }) -> [CandidateSnapshot] {
        guard !cancelled() else { return [] }
        preferenceMemory?.refreshIfChanged()
        guard !composing.isEmpty, !cancelled() else { return [] }
        var query = composing
        if let length = conversionLength {
            _ = query.moveCursorFromCursorPosition(count: length - query.convertTargetCursorPosition)
            query = query.prefixToCursorPosition()
        }
        let lexiconStarted = KeyboardPerformance.start()
        let resources = JapaneseLanguageResources.shared
        let registered = userDictionary.nativeEntries()
        let matching = resources.matchingWords(RomajiConverter.katakana(query.convertTarget)) + registered.words
        if matching != installedWords || registered.shortcuts != installedShortcuts {
            converter.importDynamicUserDictionary(matching, shortcuts: registered.shortcuts)
            converter.stopComposition()
            primaryQuery = nil
            invalidateNativeResults()
            installedWords = matching
            installedShortcuts = registered.shortcuts
        }
        KeyboardPerformance.record(.lexiconLookup, since: lexiconStarted)
        guard !cancelled() else { return [] }
        currentContinuity = previousTop
        let conversionStarted = KeyboardPerformance.start()
        var requestOptions = options
        if conversionLength != nil {
            requestOptions.N_best = 40
            requestOptions.requireJapanesePrediction = .disabled
        }
        let result: ConversionResult
        if conversionLength != nil {
            let session = prefixSession ?? converter.createSession(); prefixSession = session
            if let isolated = try? converter.withSession(session, operation: {
                converter.stopComposition()
                return converter.requestCandidates(query, options: requestOptions)
            }) { result = isolated }
            else {
                result = converter.requestCandidates(query, options: requestOptions)
                primaryQuery = query
            }
        } else {
            result = converter.requestCandidates(query, options: requestOptions)
            primaryQuery = query
        }
        KeyboardPerformance.record(.baseConversion, since: conversionStarted)
        // Finish each native call atomically, then abandon obsolete work before
        // building snapshots or starting unrelated conversion sessions.
        guard !cancelled() else { return [] }
        let kana = query.convertTarget
        let queryReading = RomajiConverter.katakana(kana)
        // Each prefixComplete re-runs Roman conversion over the remaining input,
        // and a segment remainder also rebuilds the input/surface boundary map.
        // Native lists share a handful of consuming counts; resolve each once.
        var completions: [(count: ComposingCount, text: ComposingText)] = []
        func completed(_ count: ComposingCount) -> ComposingText {
            if let cached = completions.first(where: { $0.count == count }) { return cached.text }
            var text = query; text.prefixComplete(composingCount: count)
            completions.append((count, text))
            return text
        }
        var segmentRemainders: [Int: ComposingText] = [:]
        var registeredKeys: Set<String>?
        func snapshot(_ candidate: Candidate, source: CandidateSource, engineRank: Int = 0) -> CandidateSnapshot {
            let engineRemainder = completed(candidate.composingCount)
            // Prediction selection commits the suggested completion of the
            // entire query, including an unresolved suffix. The upstream count
            // can describe only the resolved base; keep it intact as metadata.
            // acceptPredictionCandidate is a different API: it expands an
            // UNCOMMITTED composition and constrains subsequent neural queries.
            var remaining = source == .prediction || source == .readingAlternative
                ? completed(.inputCount(query.input.count)) : engineRemainder
            let consumedReading = query.convertTarget.count - remaining.convertTarget.count
            if conversionLength != nil || !remaining.isEmpty {
                if let cached = segmentRemainders[consumedReading] { remaining = cached }
                else {
                    remaining = CompositionSegmentBoundary.remainder(of: composing, consuming: consumedReading)
                    segmentRemainders[consumedReading] = remaining
                }
            }
            let isRegistered = (source == .conversion || source == .prediction) && candidate.data.contains { element in
                guard element.metadata.contains(.isFromUserDictionary) else { return false }
                if registeredKeys == nil {
                    registeredKeys = Set((installedShortcuts + registered.words).map { $0.word + "\u{0}" + $0.ruby })
                }
                return registeredKeys!.contains(element.word + "\u{0}" + element.ruby)
            }
            var value = CandidateSnapshot(candidate: candidate, revision: revision, source: isRegistered ? .userDictionary : source, remainingComposition: remaining,
                originalInputCount: composing.input.count, consumedInputCount: max(0, composing.input.count - remaining.input.count),
                queryReading: queryReading, engineRank: engineRank,
                engineFullConsumption: engineRemainder.isEmpty,
                readingOverride: source == .readingAlternative && candidate.data.isEmpty ? candidate.text : nil,
                predictionStatus: source == .prediction)
            value.consumedReadingCount = consumedReading
            if conversionLength != nil {
                value.scopeReading = queryReading
                value.explicitScope = true
            } else if !remaining.isEmpty {
                value.scopeReading = RomajiConverter.katakana(String(kana.prefix(consumedReading)))
            }
            return value
        }
        let scripts = katakana ? [queryReading, kana] : [kana, queryReading]
        let scriptCandidates = scripts.map {
            snapshot(Candidate(text: $0, value: .zero, composingCount: .inputCount(query.input.count),
                               lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false), source: .scriptVariant)
        }
        // Conversion order excludes interleaved autoMix predictions, which have
        // their own list and score scale. mainResults otherwise keeps azooKey's
        // order (sentences, clauses, words) including its learning placement.
        let predictionIndex = Self.FirstIndex(result.predictionResults)
        let interleavedPrediction = result.mainResults.map { predictionIndex[$0] != nil }
        let mainConversions = Self.FirstIndex(zip(result.mainResults, interleavedPrediction).filter { !$0.1 }.map(\.0))
        let mainIndex = Self.FirstIndex(result.mainResults)
        let conversions = result.mainResults.enumerated().filter { $0.element.inputable }.map {
            let prediction = interleavedPrediction[$0.offset]
            return snapshot($0.element, source: prediction ? .prediction : .conversion,
                engineRank: prediction ? $0.offset : mainConversions[$0.element] ?? $0.offset)
        }
        guard !cancelled() else { return [] }
        let predictions = result.predictionResults.enumerated().filter { $0.element.inputable }.map {
            snapshot($0.element, source: .prediction, engineRank: mainIndex[$0.element] ?? $0.offset)
        }
        guard !cancelled() else { return [] }
        var provided = specialProviders.flatMap {
            $0.provideCandidates(converter: converter, inputData: query, options: requestOptions).enumerated().map { ($0.element, $0.offset) }
        }
        let asciiInput = Self.rawInput(query)
        if (asciiInput.hasPrefix("u") || asciiInput.hasPrefix("U") || asciiInput.contains("@"))
            && asciiInput.unicodeScalars.allSatisfy(\.isASCII) {
            var direct = ComposingText(); direct.insertAtCursorPosition(asciiInput, inputStyle: .direct)
            provided += asciiSpecialProviders.flatMap {
                $0.provideCandidates(converter: converter, inputData: direct, options: requestOptions).enumerated().map { ($0.element, $0.offset) }
            }
        }
        let specialCandidates = provided.map { original, rank in
            var candidate = original; candidate.isLearningTarget = false
            candidate.composingCount = .inputCount(query.input.count)
            return snapshot(candidate, source: .specialConversion, engineRank: rank)
        }
        let emojiCandidates = textReplacer.getSearchResult(query: kana, target: [.emoji], ignoreNonBaseEmoji: true).prefix(6).map {
            snapshot(Candidate(text: $0.text, value: -3, composingCount: .inputCount(query.input.count),
                lastMid: MIDData.一般.mid, data: [], isLearningTarget: false), source: .emoji)
        }
        var alternatives: [CandidateSnapshot] = []
        // Alternate readings only need exact conversions. Running prediction
        // for every alternate repeats expensive work that cannot be selected.
        var alternativeOptions = options
        alternativeOptions.N_best = 3
        alternativeOptions.requireJapanesePrediction = .disabled
        // Only a single dictionary word may consume an alternate reading, and
        // the lattice never spans a word past `maxlength` input elements or
        // surface characters; longer alternates cannot produce a match.
        let maxWordLength = dictionary.maxlength
        for alternative in RomajiConverter.nReadingAlternatives(for: query)
        where alternative.input.count <= maxWordLength || alternative.convertTarget.count <= maxWordLength {
            guard !cancelled() else { return [] }
            // Separate conversion state, shared dictionary/cache; no second
            // dictionary instance and no mutation of the literal query session.
            let session = alternativeSession(for: alternative, query: query)
            guard let result = try? converter.withSession(session, operation: {
                converter.requestCandidates(alternative, options: alternativeOptions)
            }) else { continue }
            guard !cancelled() else { return [] }
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
        // First-clause order ranks one bunsetsu, not sentences. When a clause
        // consumes the whole query, its sentence position in mainResults also
        // applies; otherwise 「…市ます」 (clause #0, main #4) ties the real best
        // sentence 「…します」 at rank zero.
        let clauses = result.firstClauseResults.enumerated().filter { $0.element.inputable }.map { offset, candidate in
            let sentenceRank = completed(candidate.composingCount).isEmpty ? mainConversions[candidate] ?? offset : offset
            return snapshot(candidate, source: .conversion, engineRank: max(offset, sentenceRank))
        }
        trace?.record(.native, values: conversions + predictions + clauses)
        guard !cancelled() else { return [] }
        currentPool = conversions + predictions + scriptCandidates + alternatives + clauses + specialCandidates + emojiCandidates
        // Query the most likely first lexical boundary once, rather than converting
        // every possible prefix on every key. Explicit controls cover shorter units.
        if conversionLength == nil, let length = clauses.filter({ !$0.fullConsumption && $0.consumedReadingCount > 0 })
            .map(\.consumedReadingCount).max(), length < query.convertTarget.count {
            var prefix = query
            _ = prefix.moveCursorFromCursorPosition(count: length - prefix.convertTargetCursorPosition)
            prefix = prefix.prefixToCursorPosition()
            var prefixOptions = options; prefixOptions.N_best = 10; prefixOptions.requireJapanesePrediction = .disabled
            let session = prefixSession ?? converter.createSession(); prefixSession = session
            let prefixStarted = KeyboardPerformance.start()
            var results = firstClausePrefixCache.results(for: prefix)
            if results == nil {
                results = try? converter.withSession(session) {
                    converter.stopComposition()
                    return converter.requestCandidates(prefix, options: prefixOptions).mainResults
                }
                if let results { firstClausePrefixCache.insert(results, for: prefix) }
            }
            KeyboardPerformance.record(.prefixConversion, since: prefixStarted)
            // Prefix results share a few consuming counts; resolve each once.
            var consumedCounts: [(count: ComposingCount, consumed: Int)] = []
            for (index, candidate) in (results ?? []).enumerated() where candidate.inputable {
                guard !cancelled() else { return [] }
                let count: Int
                if let cached = consumedCounts.first(where: { $0.count == candidate.composingCount }) { count = cached.consumed }
                else {
                    var rest = prefix; rest.prefixComplete(composingCount: candidate.composingCount)
                    count = prefix.convertTarget.count - rest.convertTarget.count
                    consumedCounts.append((candidate.composingCount, count))
                }
                guard count > 0 else { continue }
                let remainder: ComposingText
                if let cached = segmentRemainders[count] { remainder = cached }
                else {
                    remainder = CompositionSegmentBoundary.remainder(of: composing, consuming: count)
                    segmentRemainders[count] = remainder
                }
                var value = CandidateSnapshot(candidate: candidate, revision: revision, source: .conversion,
                    remainingComposition: remainder, originalInputCount: composing.input.count,
                    consumedInputCount: max(0, composing.input.count - remainder.input.count),
                    queryReading: queryReading, engineRank: index)
                value.consumedReadingCount = count
                value.scopeReading = RomajiConverter.katakana(String(query.convertTarget.prefix(count)))
                currentPool.append(value)
            }
        }
        var spellingVariants: [CandidateSnapshot] = []
        for original in currentPool where original.lexical && original.source == .conversion {
            guard !cancelled() else { return [] }
            let preferred = resources.preferredSurface(original.candidate)
            guard !preferred.isEmpty, preferred != original.text else { continue }
            var variant = CandidateSnapshot(candidate: original.candidate, revision: revision, source: .orthographicVariant,
                remainingComposition: original.remainingComposition, originalInputCount: original.originalInputCount,
                consumedInputCount: original.consumedInputCount, queryReading: original.queryReading, engineRank: original.engineRank)
            variant.consumedReadingCount = original.consumedReadingCount
            variant.scopeReading = original.scopeReading
            variant.explicitScope = original.explicitScope
            variant.displaySurface = preferred
            spellingVariants.append(variant)
        }
        currentPool += spellingVariants
        let remembered = preferenceMemory?.rememberedConversions(reading: queryReading, context: committedContext) ?? []
        for (index, surface) in remembered.enumerated() {
            // Exact scoped recall only. The normal snapshot builder maps input
            // counts/remainders, including explicit prefix selection. No fake
            // word IDs enter native completion or its learning archive.
            let candidate = Candidate(text: surface, value: .zero, composingCount: .inputCount(query.input.count),
                lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false)
            currentPool.append(snapshot(candidate, source: .rememberedConversion, engineRank: 10 + index))
        }
        trace?.record(.pooled, values: currentPool)
        if diagnosticsEnabled {
            rawDiagnostics = currentPool.enumerated().map { CandidateDiagnostic($0.element, rank: $0.offset + 1) }
        }
        guard !cancelled() else { return [] }
        let base = rank(currentPool, query: query, katakana: katakana)
        trace?.record(.ranked, values: base)
        guard !cancelled() else { return [] }
        previousTop = base.first.map { .init(surface: $0.text, reading: $0.reading, input: Self.rawInput(query)) }
        return includeCorrections && conversionLength == nil ? addingCorrections(to: base, for: query, katakana: katakana, revision: revision, cancelled: cancelled) : base
    }

    func seedContinuity(_ previous: CandidateContinuity?) { previousTop = previous }

    func rank(_ pool: [CandidateSnapshot], query: ComposingText, katakana: Bool) -> [CandidateSnapshot] {
        let hasSentenceContext = !VimeLanguageModel.sentenceContext(committedContext).isEmpty
        let personalized = pool.map { original in
            var value = original
            if let scope = value.preferenceScope {
                value.userPreferenceScore = preferenceMemory?.score(reading: value.reading, surface: value.text,
                    context: committedContext, scope: scope) ?? 0
                if let memory = preferenceMemory {
                    let choice = memory.choicePreference(reading: value.reading, surface: value.text, context: committedContext)
                    var wordBonus = value.source == .rememberedConversion
                        ? memory.choicePreference(reading: value.reading, surface: value.text, context: committedContext, word: true).bonus : 0
                    if value.displaySurface == nil {
                        var left = committedContext
                        for element in value.candidate.data {
                            if element.ruby.count >= 2 {
                                wordBonus = max(wordBonus, memory.choicePreference(reading: element.ruby,
                                    surface: element.word, context: left, word: true).bonus)
                            }
                            left = String((left + element.word).suffix(96))
                        }
                    }
                    value.userPreferenceScore = min(CandidatePreferenceMemory.Policy.maximumChoiceBonus,
                        value.userPreferenceScore + choice.bonus + wordBonus)
                    value.userPreferenceConfidence = choice.confidence
                    value.modelPreferenceScoreLimit = hasSentenceContext && !choice.matchesExactContext
                        ? CandidatePreferenceMemory.Policy.maximumBackoffModelScore : CandidatePreferenceMemory.Policy.maximumChoiceBonus
                }
            }
            value.orthographyScore = JapaneseLanguageResources.shared.preference(value)
            return value
        }
        let result = reranker.rank(personalized, input: Self.rawInput(query), katakana: katakana, previous: currentContinuity,
            context: { [self] value in contextGain(value) })
        if diagnosticsEnabled {
            finalDiagnostics = result.enumerated().map { CandidateDiagnostic($0.element, rank: $0.offset + 1) }
        }
        return result
    }

    static func rawInput(_ query: ComposingText) -> String {
        query.input.compactMap { if case .character(let c) = $0.piece { return String(c) }; return nil }.joined()
    }

    func contextGain(_ value: CandidateSnapshot) -> Double {
        guard let left = contextCandidate?.data.last, let right = value.candidate.data.first,
              value.lexical else { return 0 }
        return Double(dictionary.getCCValue(left.rcid, right.lcid)
            - dictionary.getCCValue(CIDData.BOS.cid, right.lcid)
            + dictionary.getMMValue(left.mid, right.mid))
    }

    func reset(preservingContext: Bool = false) {
        primaryQuery = nil
        converter.stopComposition(); previousTop = nil; currentContinuity = nil; currentPool = []
        if !preservingContext {
            committedContext = ""; contextCandidate = nil
            if let pendingFeedback { resolveFeedback(pendingFeedback.event.id, accepted: false) }
            preferenceMemory?.resetRecent()
            if let learningSession { try? converter.withSession(learningSession) { converter.stopComposition() } }
        }
        removeAlternativeSessions()
        for session in [correctionSession, classicTypoSession, contextSession, prefixSession, widthSession].compactMap({ $0 }) {
            try? converter.withSession(session) { converter.stopComposition() }
        }
    }

    /// No converter/session reset: current candidates and staged learning must
    /// remain usable when UIKit asks the keyboard to reduce memory
    func discardTransientCaches() {
        correctionCache.removeAll(keepingCapacity: false)
        correctionCacheOrder.removeAll(keepingCapacity: false)
        firstClausePrefixCache.removeAll()
        removeAlternativeSessions()
        rawDiagnostics.removeAll(keepingCapacity: false)
        finalDiagnostics.removeAll(keepingCapacity: false)
        correctionQueryDiagnostics.removeAll(keepingCapacity: false)
    }

}
