import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Offline conversion uses azooKey's dictionary lattice and connection costs.
/// Neural models, network access, typo correction and persistent learning are disabled.
nonisolated final class JapaneseCandidateEngine {
    private let converter = KanaKanjiConverter.withDefaultDictionary()
    private let options: ConvertRequestOptions = {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return ConvertRequestOptions(
            N_best: 10, requireJapanesePrediction: .autoMix,
            requireEnglishPrediction: .disabled, keyboardLanguage: .ja_JP,
            learningType: .nothing, memoryDirectoryURL: directory,
            sharedContainerURL: directory, textReplacer: .empty,
            specialCandidateProviders: [], typoCorrectionMode: .disabled,
            metadata: .init(versionString: "Vime"))
    }()

    func candidates(for composing: ComposingText, katakana: Bool = false, revision: Int) -> [CandidateSnapshot] {
        guard !composing.isEmpty else { return [] }
        let query = composing
        let result = converter.requestCandidates(query, options: options)
        let kana = query.convertTarget
        func snapshot(_ candidate: Candidate, source: CandidateSource) -> CandidateSnapshot {
            var remaining = query
            // Prediction selection commits the suggested completion of the
            // entire query, including an unresolved suffix. The upstream count
            // can describe only the resolved base; keep it intact as metadata.
            // acceptPredictionCandidate is a different API: it expands an
            // UNCOMMITTED composition and constrains subsequent neural queries.
            remaining.prefixComplete(composingCount: source == .prediction ? .inputCount(query.input.count) : candidate.composingCount)
            return CandidateSnapshot(candidate: candidate, revision: revision, source: source, remainingComposition: remaining)
        }
        let scripts = katakana ? [RomajiConverter.katakana(kana), kana] : [kana, RomajiConverter.katakana(kana)]
        let scriptCandidates = scripts.map {
            snapshot(Candidate(text: $0, value: .zero, composingCount: .inputCount(query.input.count),
                               lastMid: MIDData.EOS.mid, data: [], isLearningTarget: false), source: .kana)
        }
        let conversions = result.mainResults.filter(\.inputable).map {
            snapshot($0, source: result.predictionResults.contains($0) ? .prediction : .conversion)
        }
        let predictions = result.predictionResults.filter(\.inputable).map { snapshot($0, source: .prediction) }
        let reading = RomajiConverter.katakana(kana)
        func isExactReading(_ value: CandidateSnapshot) -> Bool {
            let ruby = value.candidate.data.map(\.ruby).joined()
            return value.remainingComposition.isEmpty && ruby == reading
                && !ruby.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        }
        // autoMix correctly promotes compatible predictions for unresolved
        // consonants, but its longer predictions can outrank a completed word.
        // Prefer full-reading conversions, keeping upstream order within each
        // group. This policy depends on ruby/consumption, never word spellings.
        let values = (katakana ? scriptCandidates : []) + conversions.filter(isExactReading)
            + conversions.filter { $0.remainingComposition.isEmpty && !isExactReading($0) }
            + scriptCandidates + predictions + conversions.filter { !$0.remainingComposition.isEmpty }
        var seen = Set<String>()
        return Array(values.filter { !$0.text.isEmpty && seen.insert($0.text).inserted }.prefix(15))
    }

    func complete(_ candidate: Candidate) { converter.setCompletedData(candidate) }

    func reset() { converter.stopComposition() }
}
