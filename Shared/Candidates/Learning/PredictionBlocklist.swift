import Foundation

/// Terms unsuitable for suggestions, which are never offered unasked: not as
/// next-word suggestions, completions or corrections. It applies to every user
/// in every region. Typing a term still converts it as usual.
///
/// Each language keeps its own list so their standards can be tuned apart:
/// Chinese input uses the broad `shared` list, Japanese input the narrower
/// `japanese` one, which holds only plainly explicit terms.
///
/// Both files have the `LearningExclusionList` layout, built by
/// `Scripts/build_prediction_blocklist.sh` from word lists that stay local,
/// and opened from their sealed copies in `ci_scripts` on Xcode Cloud.
/// Without a file nothing is filtered for that language.
nonisolated enum PredictionBlocklist {
    static let shared = LearningExclusionList(bundle: .main, resource: "PredictionBlocklist")
    static let japanese = LearningExclusionList(bundle: .main, resource: "PredictionBlocklistJapanese")
}
