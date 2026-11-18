import Foundation

/// Sexually explicit and obscene terms that are never offered unasked: not as
/// next-word suggestions, completions or corrections. It applies to every user
/// in every region. Typing a term still converts it as usual.
///
/// `PredictionBlocklist.bin` has the `LearningExclusionList` layout, built by
/// `Scripts/build_prediction_blocklist.sh` from a word list that stays local,
/// and opened from `ci_scripts/PredictionBlocklist.sealed` on Xcode Cloud.
/// Without the file nothing is filtered.
nonisolated enum PredictionBlocklist {
    static let shared = LearningExclusionList(bundle: .main, resource: "PredictionBlocklist")
}
