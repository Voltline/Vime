import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// Expanded-panel additions: width variants and enumerated prefix boundaries.
nonisolated extension JapaneseCandidateEngine {
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
}
