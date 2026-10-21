import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// Request-scoped construction of CandidateSnapshot values from native results.
nonisolated extension JapaneseCandidateEngine {
    /// Maps native candidates of one request onto the user's composition. It
    /// owns the per-request caches that every native list shares.
    final class SnapshotBuilder {
        let query: ComposingText
        let composing: ComposingText
        let revision: Int
        let explicitScope: Bool
        let kana: String
        let queryReading: String
        private let registered: (words: [DicdataElement], shortcuts: [DicdataElement])
        private var registeredKeys: Set<String>?
        // Each prefixComplete re-runs Roman conversion over the remaining input,
        // and a segment remainder also rebuilds the input/surface boundary map.
        // Native lists share a handful of consuming counts; resolve each once.
        private var completions: [(count: ComposingCount, text: ComposingText)] = []
        private var segmentRemainders: [Int: ComposingText] = [:]

        init(query: ComposingText, composing: ComposingText, revision: Int, explicitScope: Bool,
             registered: (words: [DicdataElement], shortcuts: [DicdataElement])) {
            self.query = query
            self.composing = composing
            self.revision = revision
            self.explicitScope = explicitScope
            self.registered = registered
            kana = query.convertTarget
            queryReading = RomajiConverter.katakana(kana)
        }

        func completed(_ count: ComposingCount) -> ComposingText {
            if let cached = completions.first(where: { $0.count == count }) { return cached.text }
            var text = query; text.prefixComplete(composingCount: count)
            completions.append((count, text))
            return text
        }

        func remainder(consuming readingCount: Int) -> ComposingText {
            if let cached = segmentRemainders[readingCount] { return cached }
            let remainder = CompositionSegmentBoundary.remainder(of: composing, consuming: readingCount)
            segmentRemainders[readingCount] = remainder
            return remainder
        }

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
            if explicitScope || !remaining.isEmpty { remaining = remainder(consuming: consumedReading) }
            let isRegistered = (source == .conversion || source == .prediction) && candidate.data.contains { element in
                element.metadata.contains(.isFromUserDictionary) && isRegisteredEntry(element)
            }
            var value = CandidateSnapshot(candidate: candidate, revision: revision, source: isRegistered ? .userDictionary : source, remainingComposition: remaining,
                originalInputCount: composing.input.count, consumedInputCount: max(0, composing.input.count - remaining.input.count),
                queryReading: queryReading, engineRank: engineRank,
                engineFullConsumption: engineRemainder.isEmpty,
                readingOverride: source == .readingAlternative && candidate.data.isEmpty ? candidate.text : nil,
                predictionStatus: source == .prediction)
            value.consumedReadingCount = consumedReading
            if explicitScope {
                value.scopeReading = queryReading
                value.explicitScope = true
            } else if !remaining.isEmpty {
                value.scopeReading = RomajiConverter.katakana(String(kana.prefix(consumedReading)))
            }
            return value
        }

        /// A candidate that consumes the whole query without native word data.
        func wholeQuery(_ text: String, value: PValue = .zero, lastMid: Int = MIDData.EOS.mid) -> Candidate {
            Candidate(text: text, value: value, composingCount: .inputCount(query.input.count),
                      lastMid: lastMid, data: [], isLearningTarget: false)
        }

        private func isRegisteredEntry(_ element: DicdataElement) -> Bool {
            if registeredKeys == nil {
                registeredKeys = Set((registered.shortcuts + registered.words).map { $0.word + "\u{0}" + $0.ruby })
            }
            return registeredKeys!.contains(element.word + "\u{0}" + element.ruby)
        }
    }
}
