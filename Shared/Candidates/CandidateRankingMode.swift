/// Order of full dictionary conversions. Engine mode includes azooKey learning
/// and Vime features; languageModel adds the frozen neural reranking pass.
nonisolated enum CandidateRankingMode: String, CaseIterable, Sendable {
    case engine, languageModel
    var title: String {
        switch self {
        case .engine: "词典排序"
        case .languageModel: "智能排序"
        }
    }
}
