import Foundation

struct KeyboardPreferences {
    nonisolated static let appGroup = "group.com.Voltline.Vime"
    static let heightRange = 0.85...1.60
    private let defaults: UserDefaults
    private let heightDefaults: UserDefaults
    init(defaults: UserDefaults = .standard, heightDefaults: UserDefaults? = nil, sharedDefaults: UserDefaults? = nil) {
        let shared = sharedDefaults ?? (defaults === UserDefaults.standard ? Self.sharedStore() : nil)
        self.defaults = shared ?? defaults
        self.heightDefaults = heightDefaults ?? shared ?? defaults
        // Preserve each existing shared choice; migrate legacy per-process values
        // only when the corresponding App Group key has never been set.
        if let shared, shared !== defaults {
            for key in Self.sharedKeys where shared.object(forKey: key) == nil {
                if let value = defaults.object(forKey: key) { shared.set(value, forKey: key) }
            }
        }
        if self.defaults.object(forKey: "vime.hapticIntensity") == nil {
            let legacy = min(5, max(0, self.defaults.object(forKey: "vime.hapticLevel") as? Int ?? 3))
            self.defaults.set(Double(legacy) / 5, forKey: "vime.hapticIntensity")
        }
    }
    /// The App Group store when this process can reach it.
    nonisolated static func sharedStore() -> UserDefaults? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil ? UserDefaults(suiteName: appGroup) : nil
    }
    private static let sharedKeys = ["vime.sound", "vime.hapticLevel", "vime.hapticIntensity", "vime.nineKeyNumbers", "vime.kanaLayout",
        "vime.prolongedKey", "vime.previews", "vime.theme", "vime.candidateRanking", "vime.phraseSuggestions", "vime.clipboardSuggestions", "vime.autoPairBrackets", "vime.autoCapitalize", "vime.doubleSpacePeriod", "vime.undoConversionOnBackspace", "vime.textReplacements", "vime.customSkinID", "vime.skinRevision", "vime.numberSymbols"]
    var store: UserDefaults { defaults }
    struct Snapshot: Equatable {
        let heightFactor: Double
        let sound: Bool
        let hapticIntensity: Double
        let nineKeyNumbers: Bool
        let kanaLayout: Bool
        let prolongedKey: Bool
        let previews: Bool
        let theme: KeyboardTheme
        let customSkinID: String
        let skinRevision: Int
        let candidateRanking: CandidateRankingMode
        let phraseSuggestions: Bool
        let clipboardSuggestions: Bool
        let autoPairBrackets: Bool
        let autoCapitalize: Bool
        let doubleSpacePeriod: Bool
        let undoConversionOnBackspace: Bool
        let textReplacements: Bool
        let numberSymbols: [String]
        let neuralRetryID: String?
        let learningResetID: String?
    }
    var snapshot: Snapshot {
        Snapshot(heightFactor: heightFactor, sound: sound, hapticIntensity: hapticIntensity,
            nineKeyNumbers: nineKeyNumbers, kanaLayout: kanaLayout, prolongedKey: prolongedKey, previews: previews,
            theme: theme, customSkinID: customSkinID, skinRevision: skinRevision, candidateRanking: candidateRanking, phraseSuggestions: phraseSuggestions,
            clipboardSuggestions: clipboardSuggestions, autoPairBrackets: autoPairBrackets,
            autoCapitalize: autoCapitalize, doubleSpacePeriod: doubleSpacePeriod,
            undoConversionOnBackspace: undoConversionOnBackspace, textReplacements: textReplacements, numberSymbols: numberSymbols,
            neuralRetryID: neuralRetryID, learningResetID: learningResetRequests.requestID)
    }
    var heightFactor: Double {
        get {
            let value = heightDefaults.object(forKey: "vime.heightFactor") as? Double ?? 1
            return value.isFinite ? min(Self.heightRange.upperBound, max(Self.heightRange.lowerBound, value)) : 1
        }
        nonmutating set {
            heightDefaults.set(newValue.isFinite ? min(Self.heightRange.upperBound, max(Self.heightRange.lowerBound, newValue)) : 1,
                               forKey: "vime.heightFactor")
        }
    }
    var sound: Bool {
        get { defaults.object(forKey: "vime.sound") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.sound") }
    }
    /// Continuous requested strength; actual feedback depends on device hardware.
    var hapticIntensity: Double {
        get { HapticIntensity.normalized(defaults.double(forKey: "vime.hapticIntensity")) }
        nonmutating set { defaults.set(HapticIntensity.normalized(newValue), forKey: "vime.hapticIntensity") }
    }
    /// Compatibility for callers using the original six-level setting.
    var hapticLevel: Int {
        get { Int((hapticIntensity * 5).rounded()) }
        nonmutating set { hapticIntensity = Double(min(5, max(0, newValue))) / 5 }
    }
    var nineKeyNumbers: Bool {
        get { defaults.object(forKey: "vime.nineKeyNumbers") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.nineKeyNumbers") }
    }
    /// Japanese letters on a 12-key flick pad instead of romaji QWERTY.
    var kanaLayout: Bool {
        get { defaults.object(forKey: "vime.kanaLayout") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.kanaLayout") }
    }
    var numberSymbols: [String] {
        get { KeyboardNumberSymbols.normalized(defaults.stringArray(forKey: "vime.numberSymbols") ?? KeyboardNumberSymbols.defaults) }
        nonmutating set { defaults.set(KeyboardNumberSymbols.normalized(newValue), forKey: "vime.numberSymbols") }
    }
    static let emojiRecentLimit = 30
    /// Most recent first; shown as the first emoji category.
    var emojiRecents: [String] { Array((defaults.stringArray(forKey: "vime.emojiRecents") ?? []).prefix(Self.emojiRecentLimit)) }
    func recordEmoji(_ text: String) {
        let values = [text] + emojiRecents.filter { $0 != text }
        defaults.set(Array(values.prefix(Self.emojiRecentLimit)), forKey: "vime.emojiRecents")
    }
    var prolongedKey: Bool {
        get { defaults.object(forKey: "vime.prolongedKey") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.prolongedKey") }
    }
    var previews: Bool {
        get { defaults.object(forKey: "vime.previews") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.previews") }
    }
    var theme: KeyboardTheme {
        get { KeyboardTheme(rawValue: defaults.string(forKey: "vime.theme") ?? "") ?? .system }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "vime.theme") }
    }
    var customSkinID: String {
        get { defaults.string(forKey: "vime.customSkinID") ?? "" }
        nonmutating set { defaults.set(newValue, forKey: "vime.customSkinID") }
    }
    var skinRevision: Int {
        get { defaults.integer(forKey: "vime.skinRevision") }
        nonmutating set { defaults.set(newValue, forKey: "vime.skinRevision") }
    }
    var candidateRanking: CandidateRankingMode {
        get { Self.candidateRanking(in: defaults) }
        nonmutating set {
            if newValue == .languageModel && candidateRanking != .languageModel { requestNeuralRetry() }
            defaults.set(newValue.rawValue, forKey: "vime.candidateRanking")
        }
    }
    /// Also read by the extension audit off the main actor.
    nonisolated static func candidateRanking(in defaults: UserDefaults) -> CandidateRankingMode {
        CandidateRankingMode(rawValue: defaults.string(forKey: "vime.candidateRanking") ?? "") ?? .languageModel
    }
    var neuralRetryID: String? { defaults.string(forKey: "vime.neuralRetryID") }
    func requestNeuralRetry() { defaults.set(UUID().uuidString, forKey: "vime.neuralRetryID") }
    var learningResetRequests: KeyboardLearningResetRequests { KeyboardLearningResetRequests(defaults: defaults) }
    var phraseSuggestions: Bool {
        get { Self.phraseSuggestions(in: defaults) }
        nonmutating set { defaults.set(newValue, forKey: "vime.phraseSuggestions") }
    }
    nonisolated static func phraseSuggestions(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "vime.phraseSuggestions") as? Bool ?? true
    }
    /// Only the containing app exposes the opt-in, alongside its explanation.
    var clipboardSuggestions: Bool {
        get { defaults.object(forKey: "vime.clipboardSuggestions") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.clipboardSuggestions") }
    }
    var autoPairBrackets: Bool {
        get { defaults.object(forKey: "vime.autoPairBrackets") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.autoPairBrackets") }
    }
    /// English mode only; capitalizes as the field asks.
    var autoCapitalize: Bool {
        get { defaults.object(forKey: "vime.autoCapitalize") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.autoCapitalize") }
    }
    /// English mode only; two quick spaces after a word insert ". ".
    var doubleSpacePeriod: Bool {
        get { defaults.object(forKey: "vime.doubleSpacePeriod") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.doubleSpacePeriod") }
    }
    var undoConversionOnBackspace: Bool {
        get { defaults.object(forKey: "vime.undoConversionOnBackspace") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.undoConversionOnBackspace") }
    }
    /// Offers the iOS text replacements the keyboard can read as candidates.
    var textReplacements: Bool {
        get { defaults.object(forKey: "vime.textReplacements") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.textReplacements") }
    }
}

/// Swipe selection is reversible until release; cancelled gestures never insert.
struct KeySwipeSelection {
    enum Policy {
        static let activationDistance = 28.0 // Scaled points; ignore tap/rolling drift.
        static let retentionDistance = 18.0 // Hysteresis avoids preview flicker.
        static let activationDominance = 1.5
        static let retentionDominance = 1.1
    }
    private(set) var alternate = false
    mutating func move(x: Double, y: Double, scale: Double = 1, allowActivation: Bool = true) {
        let up = -y / max(0.01, scale), sideways = abs(x) / max(0.01, scale)
        if alternate {
            alternate = up >= Policy.retentionDistance && up >= sideways * Policy.retentionDominance
        } else {
            alternate = allowActivation && up >= Policy.activationDistance
                && up >= sideways * Policy.activationDominance
        }
    }
    mutating func reset() { alternate = false }
}
