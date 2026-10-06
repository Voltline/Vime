import Foundation

struct KeyboardPreferences {
    static let appGroup = "group.com.Voltline.Vime"
    static let heightRange = 0.85...1.60
    private let defaults: UserDefaults
    private let heightDefaults: UserDefaults
    init(defaults: UserDefaults = .standard, heightDefaults: UserDefaults? = nil, sharedDefaults: UserDefaults? = nil) {
        let shared = sharedDefaults ?? (defaults === UserDefaults.standard
            && FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) != nil
            ? UserDefaults(suiteName: Self.appGroup) : nil)
        self.defaults = shared ?? defaults
        self.heightDefaults = heightDefaults ?? shared ?? defaults
        // Preserve each existing shared choice; migrate legacy per-process values
        // only when the corresponding App Group key has never been set.
        if let shared, shared !== defaults {
            for key in Self.sharedKeys where shared.object(forKey: key) == nil {
                if let value = defaults.object(forKey: key) { shared.set(value, forKey: key) }
            }
        }
    }
    private static let sharedKeys = ["vime.sound", "vime.hapticLevel", "vime.nineKeyNumbers",
        "vime.prolongedKey", "vime.previews", "vime.theme", "vime.candidateRanking", "vime.phraseSuggestions"]
    var store: UserDefaults { defaults }
    struct Snapshot: Equatable {
        let heightFactor: Double
        let sound: Bool
        let hapticLevel: Int
        let nineKeyNumbers: Bool
        let prolongedKey: Bool
        let previews: Bool
        let theme: KeyboardTheme
        let candidateRanking: CandidateRankingMode
        let phraseSuggestions: Bool
    }
    var snapshot: Snapshot {
        Snapshot(heightFactor: heightFactor, sound: sound, hapticLevel: hapticLevel,
            nineKeyNumbers: nineKeyNumbers, prolongedKey: prolongedKey, previews: previews,
            theme: theme, candidateRanking: candidateRanking, phraseSuggestions: phraseSuggestions)
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
    /// 0 = disabled; 1...5 = increasing intensity, with heavy impact at maximum.
    var hapticLevel: Int {
        get { min(5, max(0, defaults.object(forKey: "vime.hapticLevel") as? Int ?? 3)) }
        nonmutating set { defaults.set(min(5, max(0, newValue)), forKey: "vime.hapticLevel") }
    }
    var nineKeyNumbers: Bool {
        get { defaults.object(forKey: "vime.nineKeyNumbers") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.nineKeyNumbers") }
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
    var candidateRanking: CandidateRankingMode {
        get { CandidateRankingMode(rawValue: defaults.string(forKey: "vime.candidateRanking") ?? "") ?? .languageModel }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "vime.candidateRanking") }
    }
    var phraseSuggestions: Bool {
        get { defaults.object(forKey: "vime.phraseSuggestions") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.phraseSuggestions") }
    }
}

/// Order of full dictionary conversions. The engine order already contains
/// AzooKey learning and Vime's feature reranker; the LM order replaces it.
nonisolated enum CandidateRankingMode: String, CaseIterable, Sendable {
    case engine, languageModel
    var title: String {
        switch self {
        case .engine: "词典排序"
        case .languageModel: "智能排序"
        }
    }
}

/// Swipe selection is reversible until release; cancelled gestures never insert.
struct KeySwipeSelection {
    private(set) var alternate = false
    mutating func move(x: Double, y: Double) {
        alternate = y <= -18 && abs(x) < max(36, abs(y))
    }
    mutating func reset() { alternate = false }
}
