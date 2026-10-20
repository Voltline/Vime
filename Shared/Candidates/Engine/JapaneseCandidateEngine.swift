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
    private var primaryQuery: ComposingText?
    private var committedContext = ""
    private var contextCandidate: Candidate?
    private let userDictionary: JapaneseUserDictionaryStore
    private let textReplacer = TextReplacer.withDefaultEmojiDictionary()
    private let specialProviders: [any SpecialCandidateProvider] = [
        CalendarSpecialCandidateProvider(), TimeExpressionSpecialCandidateProvider(),
        CommaSeparatedNumberSpecialCandidateProvider()
    ]
    private let asciiSpecialProviders: [any SpecialCandidateProvider] = [UnicodeSpecialCandidateProvider(), EmailAddressSpecialCandidateProvider()]
    private var installedShortcuts: [DicdataElement] = []
    private var contextSession: KanaKanjiConverter.ConversionSessionID?
    private var learningDirty = false
    private var learningSession: KanaKanjiConverter.ConversionSessionID?
    private struct PendingFeedback {
        var snapshot: CandidateSnapshot? = nil
        let text: String
        let event: CandidateLearningFeedback
        let learningEpoch: UUID?
        var nativePrediction: NativePostCompositionPrediction? = nil
    }
    private var pendingFeedback: PendingFeedback?
    private(set) var feedbackAccepted = 0
    private(set) var feedbackCancelled = 0
    private let preferenceMemory: CandidatePreferenceMemory?
    var diagnosticsEnabled = false
    private(set) var rawDiagnostics: [CandidateDiagnostic] = []
    private(set) var finalDiagnostics: [CandidateDiagnostic] = []
    private(set) var correctionQueryDiagnostics: [CorrectionQueryDiagnostic] = []
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
    private struct AlternativeShape: Hashable {
        let separator: Int
        let inserted: Int
    }
    private var alternativeSessions: [AlternativeShape: KanaKanjiConverter.ConversionSessionID] = [:]
    private var alternativeSessionOrder: [AlternativeShape] = []
    static let maximumAlternativeSessions = 6
    private var classicTypoSession: KanaKanjiConverter.ConversionSessionID?
    private var prefixSession: KanaKanjiConverter.ConversionSessionID?
    private var widthSession: KanaKanjiConverter.ConversionSessionID?
    private var installedWords: [DicdataElement] = []
    private var correctionSession: KanaKanjiConverter.ConversionSessionID?
    private var correctionCache: [String: [Candidate]] = [:]
    private var correctionCacheOrder: [String] = []
    private lazy var correctionIndex = CorrectionReadingIndex()
    /// Native results for one exact input under the current dictionary and
    /// learning state. Typing at the end usually keeps the first clause intact,
    /// so its prefix query repeats across keystrokes.
    struct NativeResultCache {
        struct Key: Hashable {
            let pieces: [InputPiece]
            let styles: [InputStyle]
            init(_ text: ComposingText) { pieces = text.input.map(\.piece); styles = text.input.map(\.inputStyle) }
        }
        private var values: [Key: [Candidate]] = [:]
        private var order: [Key] = []
        let capacity: Int
        init(capacity: Int) { self.capacity = capacity }
        func results(for text: ComposingText) -> [Candidate]? { values[Key(text)] }
        mutating func insert(_ results: [Candidate], for text: ComposingText) {
            let key = Key(text)
            if values.updateValue(results, forKey: key) == nil {
                order.append(key)
                if order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
            }
        }
        mutating func removeAll() { values.removeAll(keepingCapacity: false); order.removeAll(keepingCapacity: false) }
    }
    private var firstClausePrefixCache = NativeResultCache(capacity: 8)
    /// Every change to the dynamic dictionary or native learning invalidates
    /// results reused across requests.
    private func invalidateNativeResults() {
        correctionCache = [:]; correctionCacheOrder = []
        firstClausePrefixCache.removeAll()
        removeAlternativeSessions()
    }

    private func alternativeSession(for alternative: ComposingText, query: ComposingText) -> KanaKanjiConverter.ConversionSessionID {
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

    private func removeAlternativeSessions() {
        for session in alternativeSessions.values { converter.removeSession(session) }
        alternativeSessions = [:]; alternativeSessionOrder = []
    }
    static let maximumCorrectionQueries = 24
    static let correctionBudgetSeconds: TimeInterval = 0.060
    private(set) var lastCorrectionMetrics = CorrectionSearchMetrics()
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

    /// Expanded-panel formatting uses native options on isolated queries. Raw
    /// Roman input is queried directly for full-width letters, so resolved kana
    /// does not replace the user's original spelling. No dictionary is duplicated
    func addingWidthCandidates(to base: [CandidateSnapshot], for composing: ComposingText,
                               katakana: Bool, revision: Int, conversionLength: Int? = nil,
                               cancelled: () -> Bool = { false }) -> [CandidateSnapshot] {
        guard !composing.isEmpty, !cancelled() else { return base }
        var query = composing
        if let length = conversionLength {
            _ = query.moveCursorFromCursorPosition(count: length - query.convertTargetCursorPosition)
            query = query.prefixToCursorPosition()
        }
        let raw = Self.rawInput(query)
        let reading = RomajiConverter.katakana(query.convertTarget)
        var requests: [(ComposingText, CandidateWidthVariant, String)] = []
        if !reading.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }),
           let half = reading.applyingTransform(.fullwidthToHalfwidth, reverse: false),
           half != reading, half.unicodeScalars.contains(where: { (0xFF66...0xFF9D).contains($0.value) }) {
            requests.append((query, .halfWidthKatakana, half))
        }
        if !raw.isEmpty, raw.unicodeScalars.allSatisfy(\.isASCII),
           raw.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }),
           let full = raw.applyingTransform(.fullwidthToHalfwidth, reverse: true), full != raw {
            var direct = ComposingText(); direct.insertAtCursorPosition(raw, inputStyle: .direct)
            requests.append((direct, .fullWidthAlphanumeric, full))
        }
        guard !requests.isEmpty else { return base }
        let session = widthSession ?? converter.createSession(); widthSession = session
        var pool = base
        for (input, kind, surface) in requests {
            guard !cancelled() else { return base }
            var widthOptions = options
            widthOptions.requireJapanesePrediction = .disabled
            widthOptions.fullWidthRomanCandidate = kind == .fullWidthAlphanumeric
            widthOptions.halfWidthKanaCandidate = kind == .halfWidthKatakana
            let result = try? converter.withSession(session) {
                converter.stopComposition()
                return converter.requestCandidates(input, options: widthOptions)
            }
            guard var candidate = result?.mainResults.first(where: { $0.inputable && $0.text == surface }) else { continue }
            var rest = input; rest.prefixComplete(composingCount: candidate.composingCount)
            guard rest.isEmpty else { continue }
            // A direct query counts raw characters differently from Roman input
            candidate.composingCount = .inputCount(query.input.count)
            candidate.isLearningTarget = false
            let remainder = conversionLength == nil ? ComposingText()
                : CompositionSegmentBoundary.remainder(of: composing, consuming: query.convertTarget.count)
            var value = CandidateSnapshot(candidate: candidate, revision: revision, source: .scriptVariant,
                remainingComposition: remainder, originalInputCount: composing.input.count,
                consumedInputCount: composing.input.count - remainder.input.count,
                queryReading: RomajiConverter.katakana(composing.convertTarget), engineFullConsumption: true, readingOverride: reading)
            value.widthVariant = kind
            value.consumedReadingCount = query.convertTarget.count
            if conversionLength != nil { value.scopeReading = reading; value.explicitScope = true }
            pool.append(value)
        }
        guard !cancelled() else { return base }
        currentPool = pool
        return rank(pool, query: composing, katakana: katakana)
    }

    /// Rich segmentation is requested only for the expanded panel. Enumerate
    /// short kana boundaries (including single kana), plus attested longer word
    /// boundaries. Every entry still goes through the same reranker/identity.
    /// No word-specific exception or reserved presentation slot is used.
    func addingPrefixCandidates(to base: [CandidateSnapshot], for composing: ComposingText,
                                katakana: Bool, revision: Int,
                                cancelled: () -> Bool = { false }) -> [CandidateSnapshot] {
        let reading = composing.convertTarget
        guard reading.count > 1 else { return base }
        var boundaries = Set(1..<min(reading.count, 9))
        for value in base where value.fullConsumption && value.lexical && !value.isPrediction {
            var count = 0
            for element in value.candidate.data {
                count += element.ruby.count
                if count > 0 && count < reading.count { boundaries.insert(count) }
            }
        }
        let session = prefixSession ?? converter.createSession(); prefixSession = session
        var prefixOptions = options
        prefixOptions.N_best = 20
        prefixOptions.requireJapanesePrediction = .disabled
        var pool = base
        // Many native candidates consume the same kana prefix. Computing each
        // suffix separately copies the entire remaining Roman input per
        // candidate, including duplicates discarded later by the reranker.
        // Share immutable COW storage for each boundary within this request.
        var remainders: [Int: ComposingText] = [:]
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.prefixConversion, since: started) }
        // At most twelve cached dictionary queries, off the input/UI thread.
        for length in boundaries.sorted().prefix(12) {
            guard !cancelled() else { return base }
            var prefix = composing
            _ = prefix.moveCursorFromCursorPosition(count: length - prefix.convertTargetCursorPosition)
            prefix = prefix.prefixToCursorPosition()
            guard let result = try? converter.withSession(session, operation: {
                converter.stopComposition()
                return converter.requestCandidates(prefix, options: prefixOptions)
            }) else { continue }
            let scripts = [prefix.convertTarget, RomajiConverter.katakana(prefix.convertTarget)].map {
                Candidate(text: $0, value: .zero, composingCount: .inputCount(prefix.input.count),
                    lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false)
            }
            for (index, candidate) in (result.mainResults + scripts).enumerated() where candidate.inputable {
                var rest = prefix; rest.prefixComplete(composingCount: candidate.composingCount)
                let count = prefix.convertTarget.count - rest.convertTarget.count
                guard count > 0 && count < reading.count else { continue }
                let remainder: ComposingText
                if let cached = remainders[count] { remainder = cached }
                else {
                    remainder = CompositionSegmentBoundary.remainder(of: composing, consuming: count)
                    remainders[count] = remainder
                }
                var value = CandidateSnapshot(candidate: candidate, revision: revision,
                    source: index < result.mainResults.count ? .conversion : .scriptVariant,
                    remainingComposition: remainder, originalInputCount: composing.input.count,
                    consumedInputCount: composing.input.count - remainder.input.count,
                    queryReading: RomajiConverter.katakana(reading), engineRank: index, engineFullConsumption: rest.isEmpty,
                    readingOverride: candidate.data.isEmpty ? RomajiConverter.katakana(String(reading.prefix(count))) : nil)
                value.consumedReadingCount = count
                value.scopeReading = RomajiConverter.katakana(String(reading.prefix(count)))
                pool.append(value)
            }
        }
        guard !cancelled() else { return base }
        // Typo supplementation uses this pool; it must not discard prefixes.
        currentPool = pool
        return rank(pool, query: composing, katakana: katakana)
    }

    func seedContinuity(_ previous: CandidateContinuity?) { previousTop = previous }

    private func rank(_ pool: [CandidateSnapshot], query: ComposingText, katakana: Bool) -> [CandidateSnapshot] {
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

    /// `Array.firstIndex(of:)` for repeated lookups. Candidate is Equatable but
    /// not Hashable; bucket by text and keep the first fully equal element.
    struct FirstIndex {
        private var buckets: [String: [(candidate: Candidate, index: Int)]] = [:]
        init(_ candidates: [Candidate]) {
            for (index, candidate) in candidates.enumerated() {
                if buckets[candidate.text]?.contains(where: { $0.candidate == candidate }) == true { continue }
                buckets[candidate.text, default: []].append((candidate, index))
            }
        }
        subscript(_ candidate: Candidate) -> Int? {
            buckets[candidate.text]?.first { $0.candidate == candidate }?.index
        }
    }

    private static func rawInput(_ query: ComposingText) -> String {
        query.input.compactMap { if case .character(let c) = $0.piece { return String(c) }; return nil }.joined()
    }

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
        let generated = KeyboardCorrectionVariants.generate(for: query, cancelled: stopSearch)
        guard !stopSearch() else { return base }
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
            guard !stopSearch() else { return base }
            weighted.append((variant, priority(variant), index))
        }
        // Rank complete two-sound hypotheses using the same lexical hints as
        // single edits. Do not require either intermediate reading to be valid.
        // This supplementary work shares the existing deadline and query limit.
        let paired = KeyboardCorrectionVariants.phoneticPairs(for: query, priority: priority, cancelled: stopSearch)
        for (index, variant) in paired.enumerated() {
            guard !stopSearch() else { return base }
            weighted.append((variant, priority(variant), generated.count + index))
        }
        guard !stopSearch() else { return base }
        weighted.sort {
            $0.priority == $1.priority ? $0.index < $1.index : $0.priority < $1.priority
        }
        let variants = weighted.map(\.variant)
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
        var matches: [(Candidate, KeyboardCorrectionVariants.Variant, Double)] = []
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
        let classicStarted = KeyboardPerformance.start()
        if matches.isEmpty, !stopSearch(), Self.supportsClassicTypo(query) {
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
        if matches.isEmpty, let config = experimentalTypoConfig, !stopSearch() {
            let lmStarted = KeyboardPerformance.start()
            let proposals = converter.experimentalRequestTypoCorrection(leftSideContext: committedContext,
                composingText: query, options: correctionOptions, inputStyle: .roman2kana, config: config)
            KeyboardPerformance.record(.experimentalTypo, since: lmStarted)
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
        }
        guard !cancelled(), !matches.isEmpty else { return base }
        matches.sort { $0.2 == $1.2 ? $0.0.text < $1.0.text : $0.2 > $1.2 }
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

    private static let literalSeparators = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)

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
        // Queries may observe a stale remote proxy while the previous commit
        // is still awaiting its receipt. Only the session's verified verdict
        // may accept/reject that feedback; query context is not a receipt.
        preferenceMemory?.resetRecent()
        if let learningSession { try? converter.withSession(learningSession) { converter.stopComposition() } }
        committedContext = text; contextCandidate = nil; previousTop = nil
        converter.stopComposition()
        primaryQuery = nil
        invalidateNativeResults()
        contextCandidate = parseCommittedContext()
    }

    private func parseCommittedContext() -> Candidate? {
        guard !committedContext.isEmpty else { return nil }
        var query = ComposingText(); query.insertAtCursorPosition(committedContext, inputStyle: .direct)
        let session = contextSession ?? converter.createSession(); contextSession = session
        var contextOptions = options; contextOptions.N_best = 1
        contextOptions.requireJapanesePrediction = .disabled
        return try? converter.withSession(session) {
            converter.stopComposition()
            return converter.requestCandidates(query, options: contextOptions).mainResults.first
        }
    }

    private func completeConversionContext(_ snapshot: CandidateSnapshot) {
        // Prefix queries are isolated from the original full-query lattice.
        // Map only its completion count into that original lattice; learning
        // always receives the untouched native Candidate below.
        if snapshot.source != .rememberedConversion, snapshot.displaySurface == nil, let query = primaryQuery,
           Array(query.input.suffix(snapshot.remainingComposition.input.count)) == snapshot.remainingComposition.input {
            var completion = snapshot.candidate
            completion.composingCount = .inputCount(snapshot.consumedInputCount)
            converter.setCompletedData(completion)
        } else {
            converter.stopComposition()
            primaryQuery = nil
        }
    }

    func complete(_ snapshot: CandidateSnapshot, explicit: Bool = true) {
        completeConversionContext(snapshot)
        if snapshot.learningEligible {
            converter.updateLearningData(snapshot.candidate)
            learningDirty = true
            invalidateNativeResults()
        }
        if let scope = snapshot.preferenceScope {
            preferenceMemory?.record(reading: snapshot.reading, surface: snapshot.text, scope: scope)
        }
        if explicit { recordChoice(snapshot, context: committedContext, weight: 1, now: Date()) }
        committedContext = String((committedContext + snapshot.text).suffix(96))
        contextCandidate = snapshot.lexical && snapshot.displaySurface == nil && !snapshot.candidate.data.isEmpty ? snapshot.candidate : nil
    }

    /// Context completion is immediate; learning waits for a verified host receipt.
    func stageSelection(_ snapshot: CandidateSnapshot, event: CandidateLearningFeedback) {
        if let pendingFeedback { resolveFeedback(pendingFeedback.event.id, accepted: false) }
        preferenceMemory?.refreshIfChanged()
        completeConversionContext(snapshot)
        committedContext = String((committedContext + snapshot.text).suffix(96))
        contextCandidate = snapshot.lexical && snapshot.displaySurface == nil && !snapshot.candidate.data.isEmpty ? snapshot.candidate : nil
        pendingFeedback = PendingFeedback(snapshot: snapshot, text: snapshot.text, event: event,
            learningEpoch: preferenceMemory?.clearEpoch)
        if let scope = snapshot.preferenceScope {
            preferenceMemory?.stage(id: event.id, reading: snapshot.reading, surface: snapshot.text,
                context: event.context, scope: scope,
                weight: event.weight, now: event.selectedAt)
        }
    }

    func stageNextWord(_ text: String, event: CandidateLearningFeedback) {
        if let pendingFeedback { resolveFeedback(pendingFeedback.event.id, accepted: false) }
        preferenceMemory?.refreshIfChanged()
        pendingFeedback = PendingFeedback(text: text, event: event, learningEpoch: preferenceMemory?.clearEpoch)
        committedContext = String((committedContext + text).suffix(96))
        contextCandidate = nil
        if let learningSession { try? converter.withSession(learningSession) { converter.stopComposition() } }
        preferenceMemory?.stage(id: event.id, reading: "", surface: text, context: event.context,
            scope: "nextWord", weight: event.weight, now: event.selectedAt)
    }

    func postCompositionSuggestions(leftContext: String) -> [NextWordSuggestion] {
        preferenceMemory?.refreshIfChanged()
        reconcileContext(leftContext)
        if contextCandidate == nil { contextCandidate = parseCommittedContext() }
        guard let base = contextCandidate, !base.data.isEmpty,
              committedContext.hasSuffix(base.text) else { return [] }
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.nativeNextWords, since: started) }
        return converter.requestPostCompositionPredictionCandidates(leftSideCandidate: base, options: options).enumerated().compactMap { rank, candidate in
            guard !candidate.text.isEmpty, candidate.text.count <= 128 else { return nil }
            let native = NativePostCompositionPrediction(base: base, text: candidate.text, value: candidate.value,
                type: candidate.type, isTerminal: candidate.isTerminal, expectedLeftContext: committedContext)
            if native.isReplacement && (native.replacedText.isEmpty || !committedContext.hasSuffix(native.replacedText)) { return nil }
            let emoji = candidate.text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            return NextWordSuggestion(text: native.insertionText, source: emoji ? .emoji : .enginePrediction,
                score: -Double(rank), userScore: preferenceMemory?.nextWordScore(native.insertionText, context: VimeLanguageModel.sentenceContext(leftContext)) ?? 0,
                nativePrediction: native)
        }
    }

    func stageNativePrediction(_ prediction: NativePostCompositionPrediction, event: CandidateLearningFeedback) {
        if let pendingFeedback { resolveFeedback(pendingFeedback.event.id, accepted: false) }
        guard committedContext == prediction.expectedLeftContext else { return }
        preferenceMemory?.refreshIfChanged()
        pendingFeedback = PendingFeedback(text: prediction.insertionText, event: event,
            learningEpoch: preferenceMemory?.clearEpoch, nativePrediction: prediction)
        committedContext = String((String(committedContext.dropLast(prediction.replacedText.count)) + prediction.insertionText).suffix(96))
        contextCandidate = prediction.joined
        preferenceMemory?.stage(id: event.id, reading: "", surface: prediction.insertionText, context: event.context,
            scope: "nextWord", weight: event.weight, now: event.selectedAt)
    }

    func completeNativePrediction(_ prediction: NativePostCompositionPrediction) {
        guard committedContext == prediction.expectedLeftContext else { return }
        converter.updateLearningData(prediction.base, with: prediction.native)
        learningDirty = true
        invalidateNativeResults()
        committedContext = String((String(committedContext.dropLast(prediction.replacedText.count)) + prediction.insertionText).suffix(96))
        contextCandidate = prediction.joined
        flushLearning()
    }

    func resolveFeedback(_ id: UUID, accepted: Bool) {
        guard let pending = pendingFeedback, pending.event.id == id else { return }
        pendingFeedback = nil
        if accepted { preferenceMemory?.refreshIfChanged() }
        guard accepted, pending.learningEpoch == preferenceMemory?.clearEpoch else {
            preferenceMemory?.cancel(id); feedbackCancelled += 1; return
        }
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.learningAcceptance, since: started) }
        feedbackAccepted += 1
        if let snapshot = pending.snapshot {
            if snapshot.learningEligible {
                // Query sessions reset lastData while typing. Keep accepted-word
                // chronology in a separate azooKey session, on the same queue.
                let session = learningSession ?? converter.createSession(); learningSession = session
                try? converter.withSession(session) {
                    converter.setCompletedData(snapshot.candidate)
                    converter.updateLearningData(snapshot.candidate)
                }
                learningDirty = true
                invalidateNativeResults()
            } else if let learningSession {
                try? converter.withSession(learningSession) { converter.stopComposition() }
            }
            if let scope = snapshot.preferenceScope {
                preferenceMemory?.record(reading: snapshot.reading, surface: snapshot.text, context: pending.event.context,
                    scope: scope, weight: pending.event.weight,
                    now: pending.event.selectedAt)
                if pending.event.isDeliberateChoice {
                    recordChoice(snapshot, context: pending.event.context, weight: pending.event.weight, now: pending.event.selectedAt)
                }
            }
        } else if let nativePrediction = pending.nativePrediction {
            let session = learningSession ?? converter.createSession(); learningSession = session
            try? converter.withSession(session) {
                converter.updateLearningData(nativePrediction.base, with: nativePrediction.native)
                converter.setCompletedData(nativePrediction.joined)
            }
            learningDirty = true
            invalidateNativeResults()
            preferenceMemory?.recordNextWord(pending.text, context: pending.event.context,
                weight: pending.event.weight, now: pending.event.selectedAt)
        } else {
            preferenceMemory?.recordNextWord(pending.text, context: pending.event.context,
                weight: pending.event.weight, now: pending.event.selectedAt)
        }
        flushLearning()
    }

    private func recordChoice(_ snapshot: CandidateSnapshot, context: String, weight: Double, now: Date) {
        guard snapshot.preferenceScope != nil else { return }
        preferenceMemory?.record(reading: snapshot.reading, surface: snapshot.text, context: context,
                                 scope: "choice", weight: weight, now: now)
        // Share modest word preferences across phrases. Never teach transformed
        // display text as if it were the native word segmentation.
        guard snapshot.learningEligible else { return }
        var left = context
        var seen = Set<String>()
        var recorded = 0
        for element in snapshot.candidate.data {
            let key = element.ruby + "\0" + element.word
            if recorded < 6, element.ruby.count >= 2,
               seen.insert(key).inserted,
               element.metadata.contains(.isFromUserDictionary) || !Self.isKanaFallback(element),
               !element.word.unicodeScalars.allSatisfy({ Self.literalSeparators.contains($0) }) {
                preferenceMemory?.record(reading: element.ruby, surface: element.word, context: left,
                                         scope: "wordChoice", weight: weight, now: now)
                recorded += 1
            }
            left = String((left + element.word).suffix(96))
        }
    }

    func flushLearning() {
        let startedAt = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.learningPersistence, since: startedAt) }
        preferenceMemory?.flush()
        guard learningDirty else { return }
        converter.commitUpdateLearningData(); learningDirty = false
    }

    @discardableResult func clearLearning() -> Bool {
        // This pinned version exposes LearningConfig without a public initializer.
        // A nonempty request applies our existing public request configuration.
        var bootstrap = ComposingText(); bootstrap.insertAtCursorPosition("　", inputStyle: .direct)
        _ = converter.requestCandidates(bootstrap, options: options)
        converter.resetMemory(); learningDirty = false
        preferenceMemory?.clear()
        invalidateNativeResults()
        reset()
        // The upstream reset API logs filesystem errors instead of returning
        // them. Verify deletion before acknowledging an app reset request.
        guard preferenceMemory != nil, preferenceMemory?.persistenceError == nil,
              let files = try? FileManager.default.contentsOfDirectory(at: memoryDirectoryURL,
                includingPropertiesForKeys: nil) else { return false }
        let nativeSuffixes = [".loudstxt3", ".loudschars2", ".memorymetadata", ".louds",
            ".loudstxt3.2", ".loudschars2.2", ".memorymetadata.2", ".louds.2", ".pause", "learningMemory.txt"]
        return !files.contains { file in nativeSuffixes.contains { file.lastPathComponent.hasSuffix($0) } }
    }

    func rememberedNextWords(context: String) -> [String] {
        preferenceMemory?.rememberedNextWords(context: context) ?? []
    }
    func personalizedNextWords(_ words: [ScoredNextWord], history: [ScoredNextWord], context: String) -> [NextWordSuggestion] {
        preferenceMemory?.nextWords(words, history: history, context: context) ?? words.map {
            NextWordSuggestion(text: $0.text, source: .contextPrediction,
                score: $0.logProbabilitySum, userScore: 0, modelScore: $0.logProbabilitySum, tokenCount: $0.tokenCount)
        }
    }
    func completeNextWord(_ text: String, context: String) {
        preferenceMemory?.recordNextWord(text, context: context)
        preferenceMemory?.flush()
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
