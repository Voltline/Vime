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
        let registered = installDynamicDictionary(for: query)
        guard !cancelled() else { return [] }
        currentContinuity = previousTop
        let (result, requestOptions) = baseConversion(of: query, explicitScope: conversionLength != nil)
        // Finish each native call atomically, then abandon obsolete work before
        // building snapshots or starting unrelated conversion sessions.
        guard !cancelled() else { return [] }
        let builder = SnapshotBuilder(query: query, composing: composing, revision: revision,
                                      explicitScope: conversionLength != nil, registered: registered)
        let scripts = (katakana ? [builder.queryReading, builder.kana] : [builder.kana, builder.queryReading]).map {
            builder.snapshot(builder.wholeQuery($0), source: .scriptVariant)
        }
        guard let native = nativeCandidates(from: result, builder: builder, cancelled: cancelled) else { return [] }
        let special = specialCandidates(for: query, options: requestOptions, builder: builder)
        let emoji = textReplacer.getSearchResult(query: builder.kana, target: [.emoji], ignoreNonBaseEmoji: true).prefix(6).map {
            builder.snapshot(builder.wholeQuery($0.text, value: -3, lastMid: MIDData.一般.mid), source: .emoji)
        }
        let literalScore = native.conversions.first { $0.exactReading && $0.fullConsumption }?.engineScore
        guard let alternatives = readingAlternatives(for: query, literalScore: literalScore, builder: builder, cancelled: cancelled)
        else { return [] }
        trace?.record(.native, values: native.conversions + native.predictions + native.clauses)
        guard !cancelled() else { return [] }
        currentPool = native.conversions + native.predictions + scripts + alternatives + native.clauses + special + emoji
        if conversionLength == nil {
            guard let prefixed = firstClausePrefixCandidates(after: native.clauses, builder: builder, cancelled: cancelled)
            else { return [] }
            currentPool += prefixed
        }
        guard let variants = spellingVariants(of: currentPool, cancelled: cancelled) else { return [] }
        currentPool += variants
        currentPool += rememberedConversions(builder: builder)
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
