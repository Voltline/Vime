import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// The candidate sources pooled by `candidates(for:)`, in pipeline order. A nil
// result means the request was cancelled midway and must be abandoned.
nonisolated extension JapaneseCandidateEngine {
    /// Installs the lexicon words matching this query plus the user's
    /// registered entries; a changed set invalidates native state.
    func installDynamicDictionary(for query: ComposingText) -> (words: [DicdataElement], shortcuts: [DicdataElement]) {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.lexiconLookup, since: started) }
        let registered = userDictionary.nativeEntries()
        let matching = JapaneseLanguageResources.shared.matchingWords(RomajiConverter.katakana(query.convertTarget)) + registered.words
        if matching != installedWords || registered.shortcuts != installedShortcuts {
            converter.importDynamicUserDictionary(matching, shortcuts: registered.shortcuts)
            converter.stopComposition()
            primaryQuery = nil
            invalidateNativeResults()
            installedWords = matching
            installedShortcuts = registered.shortcuts
        }
        return registered
    }

    /// The literal query's conversion. An explicitly scoped prefix runs in its
    /// own session so the incremental primary lattice survives.
    func baseConversion(of query: ComposingText, explicitScope: Bool) -> (ConversionResult, ConvertRequestOptions) {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.baseConversion, since: started) }
        var requestOptions = options
        if explicitScope {
            requestOptions.N_best = 40
            requestOptions.requireJapanesePrediction = .disabled
            let session = prefixSession ?? converter.createSession(); prefixSession = session
            if let isolated = try? converter.withSession(session, operation: {
                converter.stopComposition()
                return converter.requestCandidates(query, options: requestOptions)
            }) { return (isolated, requestOptions) }
        }
        primaryQuery = query
        return (converter.requestCandidates(query, options: requestOptions), requestOptions)
    }

    struct NativeCandidates {
        let conversions: [CandidateSnapshot]
        let predictions: [CandidateSnapshot]
        let clauses: [CandidateSnapshot]
    }

    func nativeCandidates(from result: ConversionResult, builder: SnapshotBuilder,
                          cancelled: () -> Bool) -> NativeCandidates? {
        // Conversion order excludes interleaved autoMix predictions, which have
        // their own list and score scale. mainResults otherwise keeps azooKey's
        // order (sentences, clauses, words) including its learning placement.
        let predictionIndex = Self.FirstIndex(result.predictionResults)
        let interleavedPrediction = result.mainResults.map { predictionIndex[$0] != nil }
        let mainConversions = Self.FirstIndex(zip(result.mainResults, interleavedPrediction).filter { !$0.1 }.map(\.0))
        let mainIndex = Self.FirstIndex(result.mainResults)
        let conversions = result.mainResults.enumerated().filter { $0.element.inputable }.map {
            let prediction = interleavedPrediction[$0.offset]
            return builder.snapshot($0.element, source: prediction ? .prediction : .conversion,
                engineRank: prediction ? $0.offset : mainConversions[$0.element] ?? $0.offset)
        }
        guard !cancelled() else { return nil }
        let predictions = result.predictionResults.enumerated().filter { $0.element.inputable }.map {
            builder.snapshot($0.element, source: .prediction, engineRank: mainIndex[$0.element] ?? $0.offset)
        }
        guard !cancelled() else { return nil }
        // First-clause order ranks one bunsetsu, not sentences. When a clause
        // consumes the whole query, its sentence position in mainResults also
        // applies; otherwise 「…市ます」 (clause #0, main #4) ties the real best
        // sentence 「…します」 at rank zero.
        let clauses = result.firstClauseResults.enumerated().filter { $0.element.inputable }.map { offset, candidate in
            let sentenceRank = builder.completed(candidate.composingCount).isEmpty ? mainConversions[candidate] ?? offset : offset
            return builder.snapshot(candidate, source: .conversion, engineRank: max(offset, sentenceRank))
        }
        return NativeCandidates(conversions: conversions, predictions: predictions, clauses: clauses)
    }

    /// Calendar, time, number and (for raw ASCII input) Unicode/e-mail forms.
    func specialCandidates(for query: ComposingText, options requestOptions: ConvertRequestOptions,
                           builder: SnapshotBuilder) -> [CandidateSnapshot] {
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
        return provided.map { original, rank in
            var candidate = original; candidate.isLearningTarget = false
            candidate.composingCount = .inputCount(builder.query.input.count)
            return builder.snapshot(candidate, source: .specialConversion, engineRank: rank)
        }
    }

    static let relativeDays: [String: Int] = ["きょう": 0, "ほんじつ": 0, "あした": 1, "あす": 1, "みょうにち": 1,
                                              "あさって": 2, "きのう": -1, "さくじつ": -1, "おととい": -2]

    /// Today's date for きょう (and nearby days), the time for いま. Below the
    /// word itself, beside its kana.
    func dateCandidates(builder: SnapshotBuilder, now: Date = Date()) -> [CandidateSnapshot] {
        let texts: [String]
        if let offset = Self.relativeDays[builder.kana] {
            let gregorian = Calendar(identifier: .gregorian)
            guard let day = gregorian.date(byAdding: .day, value: offset, to: now) else { return [] }
            texts = ["yyyy/MM/dd", "yyyy年M月d日", "M月d日(E)"].map { Self.format(day, $0, calendar: gregorian) }
                + [Self.format(day, "GGGGy年M月d日", calendar: Calendar(identifier: .japanese))]
        } else if builder.kana == "いま" {
            texts = ["H:mm", "H時m分"].map { Self.format(now, $0, calendar: Calendar(identifier: .gregorian)) }
        } else { return [] }
        return texts.enumerated().map { offset, text in
            builder.snapshot(builder.wholeQuery(text), source: .specialConversion, engineRank: 1 + offset)
        }
    }

    static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = calendar
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// The letters as typed (iphone, Iphone) for words romaji cannot spell.
    /// They lead only while the kana still holds bare letters (いpほね).
    func typedLetterCandidates(for query: ComposingText, builder: SnapshotBuilder) -> [CandidateSnapshot] {
        let typed = Self.rawInput(query)
        guard typed.count >= 2, typed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              typed.contains(where: \.isLetter) else { return [] }
        // While a consonant is pending the user is most likely still typing.
        let pending = builder.kana.last.map { $0.isASCII && $0.isLetter } ?? false
        let rank = Self.romajiCannotSpell(builder.kana) ? 0 : pending ? 40 : 8
        let capitalized = typed.prefix(1).uppercased() + typed.dropFirst()
        return [typed, capitalized].enumerated().map { offset, text in
            builder.snapshot(builder.wholeQuery(text), source: .specialConversion, engineRank: rank + offset)
        }
    }

    /// Letters left inside the kana (いpほね), or a trailing run no romaji
    /// continues (おrz). A pending consonant (なにm, きょうs) is still typing.
    static func romajiCannotSpell(_ kana: String) -> Bool {
        let tail = String(kana.reversed().prefix { $0.isASCII && $0.isLetter }.reversed())
        if kana.dropLast(tail.count).contains(where: { $0.isASCII && $0.isLetter }) { return true }
        switch tail.count {
        case 0, 1: return false
        case 2: return !("yhw".contains(tail.last!) || ["ts", "xt", "lt"].contains(tail))
        default: return true
        }
    }

    /// Dictionary words reachable only through another reading of an
    /// ambiguous n, scored against the literal reading's best conversion.
    func readingAlternatives(for query: ComposingText, literalScore: Double?, builder: SnapshotBuilder,
                             cancelled: () -> Bool) -> [CandidateSnapshot]? {
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
            guard !cancelled() else { return nil }
            // Separate conversion state, shared dictionary/cache; no second
            // dictionary instance and no mutation of the literal query session.
            let session = alternativeSession(for: alternative, query: query)
            guard let result = try? converter.withSession(session, operation: {
                converter.requestCandidates(alternative, options: alternativeOptions)
            }) else { continue }
            guard !cancelled() else { return nil }
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
                alternatives.append(builder.snapshot(candidate, source: .readingAlternative))
            }
            // Keep the alternate kana selectable even if the dictionary prefers
            // a kanji spelling; only offer it when this reading has a match.
            if let best = matches.first {
                let kana = builder.wholeQuery(alternative.convertTarget, value: best.value - 1)
                alternatives.append(builder.snapshot(kana, source: .readingAlternative))
            }
        }
        // Preserve the established n interpretation's dictionary-score evidence
        // inside the unified model, instead of placing its array before literals.
        guard let literalScore else { return alternatives }
        return alternatives.map { original in
            var value = original
            value.interpretationGain = (value.engineScore - literalScore) / Double(max(3, value.reading.count))
            return value
        }
    }

    /// Query the most likely first lexical boundary once, rather than converting
    /// every possible prefix on every key. Explicit controls cover shorter units.
    func firstClausePrefixCandidates(after clauses: [CandidateSnapshot], builder: SnapshotBuilder,
                                     cancelled: () -> Bool) -> [CandidateSnapshot]? {
        let query = builder.query
        guard let length = clauses.filter({ !$0.fullConsumption && $0.consumedReadingCount > 0 })
            .map(\.consumedReadingCount).max(), length < query.convertTarget.count else { return [] }
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
        var prefixed: [CandidateSnapshot] = []
        // Prefix results share a few consuming counts; resolve each once.
        var consumedCounts: [(count: ComposingCount, consumed: Int)] = []
        for (index, candidate) in (results ?? []).enumerated() where candidate.inputable {
            guard !cancelled() else { return nil }
            let count: Int
            if let cached = consumedCounts.first(where: { $0.count == candidate.composingCount }) { count = cached.consumed }
            else {
                var rest = prefix; rest.prefixComplete(composingCount: candidate.composingCount)
                count = prefix.convertTarget.count - rest.convertTarget.count
                consumedCounts.append((candidate.composingCount, count))
            }
            guard count > 0 else { continue }
            let remainder = builder.remainder(consuming: count)
            var value = CandidateSnapshot(candidate: candidate, revision: builder.revision, source: .conversion,
                remainingComposition: remainder, originalInputCount: builder.composing.input.count,
                consumedInputCount: max(0, builder.composing.input.count - remainder.input.count),
                queryReading: builder.queryReading, engineRank: index)
            value.consumedReadingCount = count
            value.scopeReading = RomajiConverter.katakana(String(query.convertTarget.prefix(count)))
            prefixed.append(value)
        }
        return prefixed
    }

    /// The preferred orthography of each lexical conversion, as its own entry.
    func spellingVariants(of pool: [CandidateSnapshot], cancelled: () -> Bool) -> [CandidateSnapshot]? {
        let resources = JapaneseLanguageResources.shared
        var variants: [CandidateSnapshot] = []
        for original in pool where original.lexical && original.source == .conversion {
            guard !cancelled() else { return nil }
            let preferred = resources.preferredSurface(original.candidate)
            guard !preferred.isEmpty, preferred != original.text else { continue }
            var variant = CandidateSnapshot(candidate: original.candidate, revision: original.revision, source: .orthographicVariant,
                remainingComposition: original.remainingComposition, originalInputCount: original.originalInputCount,
                consumedInputCount: original.consumedInputCount, queryReading: original.queryReading, engineRank: original.engineRank)
            variant.consumedReadingCount = original.consumedReadingCount
            variant.scopeReading = original.scopeReading
            variant.explicitScope = original.explicitScope
            variant.displaySurface = preferred
            variants.append(variant)
        }
        return variants
    }

    /// Dictionary artifacts no one types on purpose: combining voiced marks
    /// (ン゙), a small kana after a kanji or the other script (自ゃ, くァ), and a
    /// number with only some digits converted (一00%, 1零0). Units such as
    /// 1万 stay. A mark the reading itself contains is kept.
    static func isMalformedSurface(_ text: String, reading: String) -> Bool {
        let combining: Set<Unicode.Scalar> = ["\u{3099}", "\u{309A}"]
        if text.unicodeScalars.contains(where: combining.contains),
           !reading.unicodeScalars.contains(where: combining.contains) { return true }
        let smallHiragana = Set("ぁぃぅぇぉゃゅょゎ"), smallKatakana = Set("ァィゥェォャュョヮ")
        func isHiragana(_ c: Character) -> Bool { ("ぁ"..."ゖ").contains(c) }
        func isKatakana(_ c: Character) -> Bool { ("ァ"..."ヺ").contains(c) }
        func isKanji(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || $0 == "々" } }
        let characters = Array(text)
        for (index, c) in characters.enumerated().dropFirst() where smallHiragana.contains(c) || smallKatakana.contains(c) {
            let previous = characters[index - 1]
            if isKanji(previous) { return true }
            if smallHiragana.contains(c) ? isKatakana(previous) : isHiragana(previous) { return true }
        }
        let kanjiDigits = Set("〇零一二三四五六七八九")
        var run: [Character] = []
        for c in characters + [" "] {
            if c.isNumber || kanjiDigits.contains(c) { run.append(c); continue }
            if run.contains(where: kanjiDigits.contains), run.contains(where: { $0.isASCII || ("０"..."９").contains($0) }) { return true }
            run = []
        }
        return false
    }

    func rememberedConversions(builder: SnapshotBuilder) -> [CandidateSnapshot] {
        let remembered = preferenceMemory?.rememberedConversions(reading: builder.queryReading, context: committedContext) ?? []
        // Exact scoped recall only. The normal snapshot builder maps input
        // counts/remainders, including explicit prefix selection. No fake
        // word IDs enter native completion or its learning archive.
        return remembered.enumerated().map { index, surface in
            builder.snapshot(builder.wholeQuery(surface), source: .rememberedConversion, engineRank: 10 + index)
        }
    }
}
