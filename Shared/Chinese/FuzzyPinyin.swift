import Foundation

/// Fuzzy pinyin groups. Each combination is a schema of its own,
/// vime_pinyin_fuzzy<rawValue>, prebuilt by Scripts/build_rime_data.sh from
/// the groups in Scripts/generate_pinyin_algebra.py (same bits, same order).
nonisolated struct FuzzyPinyin: OptionSet, Hashable, Sendable {
    let rawValue: Int
    /// z/zh, c/ch, s/sh
    static let retroflex = FuzzyPinyin(rawValue: 1)
    /// an/ang, en/eng, in/ing
    static let nasal = FuzzyPinyin(rawValue: 2)
    /// n/l, f/h, r/l
    static let initials = FuzzyPinyin(rawValue: 4)
    static let allCases: [FuzzyPinyin] = [.retroflex, .nasal, .initials]

    /// The preference that stores a single group.
    var key: String {
        switch self {
        case .retroflex: "vime.fuzzyRetroflex"
        case .nasal: "vime.fuzzyNasal"
        default: "vime.fuzzyInitials"
        }
    }
    var schema: String { isEmpty ? "vime_pinyin" : "vime_pinyin_fuzzy\(rawValue)" }
}
