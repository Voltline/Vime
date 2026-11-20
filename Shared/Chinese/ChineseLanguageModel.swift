import Foundation

/// The Chinese keyboard's model: VimeML's `vimeml-zh-v2-20m` (default) or
/// `vimeml-tiny-zh-v1` (fallback) as the kvbatch-v4 fp32kv package, with their
/// shared tokenizer. One instance, held by
/// `JapaneseCandidateWorker.LanguageModelStorage` like the Japanese model
/// (never both at once), serves reranking (`scores`), sentence correction
/// (`tokenScores`, `ChinesePrefixScoring`) and sentence generation (`batch`).
///
/// Model queue, like the package.
nonisolated final class ChineseLanguageModel {
    enum Version: String, CaseIterable, Sendable {
        case v1
        case v2

        var variant: VimeKVBatchLanguageModel.Variant {
            switch self {
            case .v1: .v1
            case .v2: .v2
            }
        }

        var decodingMode: ChineseConstrainedGeneration.Mode {
            switch self {
            case .v1: .lm
            case .v2: .task
            }
        }

        var displayVersion: String {
            switch self {
            case .v1: "1"
            case .v2: "2"
            }
        }
    }

    static let tokenizerResource = "VimeChineseTokenizerV1"
    static let vocabulary = 12288
    static let defaultVersion: Version = .v2
    static let versionPreferenceKey = "vime.chineseModelVersion"
    static var configuredVersion: Version {
        guard let raw = UserDefaults(suiteName: KeyboardPreferences.appGroup)?.string(forKey: versionPreferenceKey),
              let version = Version(rawValue: raw) else { return defaultVersion }
        return version
    }
    /// Effective version taking automatic v2→v1 fallback into account.
    static var effectiveVersion: Version {
        let configured = configuredVersion
        guard configured == .v2 else { return .v1 }
        return ChineseModelFallback.shared.isFallenBackToV1 ? .v1 : .v2
    }
    static var displayVersion: String { effectiveVersion.displayVersion }
    /// <CTX>, <READ> and <OUT>: the three-task model's markers, never part of a scored sentence.
    static let reservedTokens: Set<Int32> = [4, 5, 6]

    let version: Version
    var decodingMode: ChineseConstrainedGeneration.Mode { version.decodingMode }
    let batch: VimeKVBatchLanguageModel
    let tokenizer: VimeSentenceTokenizer
    var modelVersion: String { batch.modelVersion }

    /// `preload` loads only `score` now so a cold load does not hold the first
    /// scoring request; `scored` stays lazy until generation needs it,
    /// avoiding ~27 MB of eager footprint on rerank-only sessions.
    init(bundle: Bundle = .main, version: Version = ChineseLanguageModel.effectiveVersion, preload: Bool = false) throws {
        guard let tokenizerURL = bundle.url(forResource: Self.tokenizerResource, withExtension: "model")
        else { throw VimeLanguageModel.Failure.resources }
        self.version = version
        batch = try VimeKVBatchLanguageModel(bundle: bundle, variant: version.variant)
        tokenizer = try VimeSentenceTokenizer(url: tokenizerURL, vocabulary: Self.vocabulary)
        if preload { try batch.preload(.score) }
    }

    /// Reranking: each candidate's summed log probability after `context`,
    /// all of them from the token where the first one parts from the
    /// context, so that they compare over the same tokens. Distinct,
    /// non-empty candidates only.
    func scores(context: String, candidates: [String], cancelled: () -> Bool = { false }) throws -> [Double] {
        let started = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.lmCandidateScoring, since: started) }
        guard !cancelled() else { throw VimeLanguageModel.Failure.cancelled }
        guard Set(candidates.map { Data($0.utf8) }).count == candidates.count
        else { throw VimeLanguageModel.Failure.ineligible }
        return try ChinesePrefixScoring.scores(context: context, candidates: candidates, sharedStart: true,
                                               model: batch, tokenizer: tokenizer, cancelled: cancelled)
    }

    /// The tokens of `text` after `context`, each with its log probability.
    func tokenScores(context: String, text: String) throws -> [(text: String, logProbability: Double)] {
        try ChinesePrefixScoring.tokenScores(context: context, text: text, model: batch, tokenizer: tokenizer)
            .map { (try tokenizer.decode([$0.id]), $0.logProbability) }
    }
}
