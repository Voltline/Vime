import Foundation

struct KeyboardPreferences {
    nonisolated static let appGroup = "group.com.Voltline.Vime"
    static let heightRange = 0.85...1.60
    static let keyCornerRadiusRange = 0.0...16.0
    static let defaultKeyCornerRadius = 6.2
    private let defaults: UserDefaults
    private let heightDefaults: UserDefaults
    private static let sharedStoreLock = NSLock()
    private nonisolated(unsafe) static var cachedSharedStore: UserDefaults?
    private nonisolated(unsafe) static var cachedSharedStoreChecked = false
    private nonisolated(unsafe) static var migratedDefaultSharedStore = false

    init(defaults: UserDefaults = .standard, heightDefaults: UserDefaults? = nil, sharedDefaults: UserDefaults? = nil) {
        let usesDefaultShared = sharedDefaults == nil && defaults === UserDefaults.standard
        let shared = sharedDefaults ?? (usesDefaultShared ? Self.sharedStore() : nil)
        self.defaults = shared ?? defaults
        self.heightDefaults = heightDefaults ?? shared ?? defaults
        if usesDefaultShared {
            Self.sharedStoreLock.lock()
            let shouldMigrate = !Self.migratedDefaultSharedStore
            if shouldMigrate { Self.migratedDefaultSharedStore = true }
            Self.sharedStoreLock.unlock()
            if shouldMigrate {
                Self.migrate(from: defaults, to: self.defaults, shared: shared)
            }
        } else {
            Self.migrate(from: defaults, to: self.defaults, shared: shared)
        }
    }

    private static func migrate(from defaults: UserDefaults, to target: UserDefaults, shared: UserDefaults?) {
        // Preserve each existing shared choice; migrate legacy per-process values
        // only when the corresponding App Group key has never been set.
        if let shared, shared !== defaults {
            for key in Self.sharedKeys where shared.object(forKey: key) == nil {
                if let value = defaults.object(forKey: key) { shared.set(value, forKey: key) }
            }
        }
        if target.object(forKey: "vime.hapticIntensity") == nil {
            let legacy = min(5, max(0, target.object(forKey: "vime.hapticLevel") as? Int ?? 3))
            target.set(Double(legacy) / 5, forKey: "vime.hapticIntensity")
        }
    }

    /// The App Group store when this process can reach it (cached per process).
    nonisolated static func sharedStore() -> UserDefaults? {
        sharedStoreLock.lock()
        defer { sharedStoreLock.unlock() }
        if cachedSharedStoreChecked { return cachedSharedStore }
        cachedSharedStoreChecked = true
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil {
            cachedSharedStore = UserDefaults(suiteName: appGroup)
        }
        return cachedSharedStore
    }
    private static let sharedKeys = ["vime.sound", "vime.hapticLevel", "vime.hapticIntensity", "vime.nineKeyNumbers", "vime.kanaLayout",
        "vime.prolongedKey", "vime.previews", "vime.previewHold", "vime.theme", "vime.candidateRanking", "vime.phraseSuggestions", "vime.clipboardSuggestions", "vime.autoPairBrackets", "vime.autoCapitalize", "vime.doubleSpacePeriod", "vime.undoConversionOnBackspace", "vime.fullWidthSpace", "vime.liveConversion", "vime.textReplacements", "vime.englishCompletion", "vime.oneHanded", "vime.customSkinID", "vime.skinRevision", "vime.numberSymbols", "vime.inputLanguage",
        "vime.chineseInputEnabled", "vime.japaneseInputEnabled", "vime.koreanInputEnabled", "vime.pinyinLookupInJapanese", "vime.traditionalChinese", "vime.chineseLanguageModel", "vime.chineseModelVersion", "vime.japaneseModelVersion",
        "vime.fuzzyRetroflex", "vime.fuzzyNasal", "vime.fuzzyInitials", "vime.chinesePunctuation", "vime.japaneseFullWidthSymbols", "vime.correctionSpellingHints",
        "vime.chineseDateFormat", "vime.chineseTimeFormat", "vime.chineseLayout", "vime.shuangpinScheme"]
    var store: UserDefaults { defaults }
    struct Snapshot: Equatable {
        let heightFactor: Double
        let keyCornerRadius: Double
        let sound: Bool
        let hapticIntensity: Double
        let nineKeyNumbers: Bool
        let kanaLayout: Bool
        let prolongedKey: Bool
        let previews: Bool
        let previewHold: Double
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
        let fullWidthSpace: Bool
        let liveConversion: Bool
        let textReplacements: Bool
        let englishCompletion: Bool
        let oneHanded: KeyboardOneHandedSide
        let numberSymbols: [String]
        let neuralRetryID: String?
        let learningResetID: String?
        let inputLanguage: KeyboardInputLanguage
        let chineseInputEnabled: Bool
        let japaneseInputEnabled: Bool
        let koreanInputEnabled: Bool
        let pinyinLookupInJapanese: Bool
        let traditionalChinese: Bool
        let chineseLanguageModel: Bool
        let chineseModelVersion: ChineseLanguageModel.Version
        let japaneseModelVersion: JapaneseLanguageModelV6.Version
        let fuzzyPinyin: FuzzyPinyin
        let chinesePunctuation: Bool
        let japaneseFullWidthSymbols: Bool
        let correctionSpellingHints: Bool
        let chineseDateFormat: ChineseSpecialConversions.DateFormat
        let chineseTimeFormat: ChineseSpecialConversions.TimeFormat
        let chineseLayout: ChineseKeyboardLayout
        let shuangpinScheme: ShuangpinScheme
    }
    var snapshot: Snapshot {
        Snapshot(heightFactor: heightFactor, keyCornerRadius: keyCornerRadius, sound: sound, hapticIntensity: hapticIntensity,
            nineKeyNumbers: nineKeyNumbers, kanaLayout: kanaLayout, prolongedKey: prolongedKey, previews: previews,
            previewHold: previewHold,
            theme: theme, customSkinID: customSkinID, skinRevision: skinRevision, candidateRanking: candidateRanking, phraseSuggestions: phraseSuggestions,
            clipboardSuggestions: clipboardSuggestions, autoPairBrackets: autoPairBrackets,
            autoCapitalize: autoCapitalize, doubleSpacePeriod: doubleSpacePeriod,
            undoConversionOnBackspace: undoConversionOnBackspace, fullWidthSpace: fullWidthSpace, liveConversion: liveConversion, textReplacements: textReplacements,
            englishCompletion: englishCompletion, oneHanded: oneHanded, numberSymbols: numberSymbols,
            neuralRetryID: neuralRetryID,
            learningResetID: [learningResetRequests.requestID, learningResetRequests.chinese.requestID]
                .map { $0 ?? "" }.joined(separator: "|"),
            inputLanguage: inputLanguage, chineseInputEnabled: chineseInputEnabled, japaneseInputEnabled: japaneseInputEnabled,
            koreanInputEnabled: koreanInputEnabled,
            pinyinLookupInJapanese: pinyinLookupInJapanese, traditionalChinese: traditionalChinese,
            chineseLanguageModel: chineseLanguageModel, chineseModelVersion: chineseModelVersion, japaneseModelVersion: japaneseModelVersion, fuzzyPinyin: fuzzyPinyin,
            chinesePunctuation: chinesePunctuation, japaneseFullWidthSymbols: japaneseFullWidthSymbols,
            correctionSpellingHints: correctionSpellingHints,
            chineseDateFormat: chineseDateFormat, chineseTimeFormat: chineseTimeFormat, chineseLayout: chineseLayout,
            shuangpinScheme: shuangpinScheme)
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
    /// The corner radius of keys under the built-in themes; custom skins keep their own.
    var keyCornerRadius: Double {
        get {
            let value = defaults.object(forKey: "vime.keyCornerRadius") as? Double ?? Self.defaultKeyCornerRadius
            return value.isFinite ? min(Self.keyCornerRadiusRange.upperBound, max(Self.keyCornerRadiusRange.lowerBound, value))
                : Self.defaultKeyCornerRadius
        }
        nonmutating set {
            let value = newValue.isFinite ? newValue : Self.defaultKeyCornerRadius
            defaults.set(min(Self.keyCornerRadiusRange.upperBound, max(Self.keyCornerRadiusRange.lowerBound, value)),
                         forKey: "vime.keyCornerRadius")
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
    /// The keyboard's primary language, one of the input methods turned on.
    /// Chinese also needs the bundled Rime data. A stored language that is
    /// turned off reads as the first enabled language and comes back when turned on again.
    var inputLanguage: KeyboardInputLanguage {
        get {
            let stored = KeyboardInputLanguage(rawValue: defaults.string(forKey: "vime.inputLanguage") ?? "") ?? .japanese
            switch stored {
            case .japanese where japaneseInputEnabled: return .japanese
            case .chinese where chineseInputEnabled: return .chinese
            case .korean where koreanInputEnabled: return .korean
            default:
                if japaneseInputEnabled { return .japanese }
                if chineseInputEnabled { return .chinese }
                if koreanInputEnabled { return .korean }
                return .japanese
            }
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "vime.inputLanguage") }
    }
    /// Offers Chinese pinyin input. Off, the keyboard never starts the Rime engine.
    var chineseInputEnabled: Bool {
        get { defaults.object(forKey: "vime.chineseInputEnabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.chineseInputEnabled") }
    }
    /// Offers Korean 2-beolsik input. Off by default; never loads Korean lexicon data while off.
    var koreanInputEnabled: Bool {
        get { defaults.object(forKey: "vime.koreanInputEnabled") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.koreanInputEnabled") }
    }
    /// Offers Japanese input, in the romaji or kana layout. It is off only
    /// while at least one other primary input method is on: one input method always stays.
    var japaneseInputEnabled: Bool {
        get { (!chineseInputEnabled && !koreanInputEnabled) || (defaults.object(forKey: "vime.japaneseInputEnabled") as? Bool ?? true) }
        nonmutating set { defaults.set(newValue, forKey: "vime.japaneseInputEnabled") }
    }
    /// Japanese mode: a kanji word's Mandarin pinyin, alone or mixed with
    /// romaji, also finds it. Part of Chinese input, so false while that is off.
    var pinyinLookupInJapanese: Bool {
        get { chineseInputEnabled && (defaults.object(forKey: "vime.pinyinLookupInJapanese") as? Bool ?? true) }
        nonmutating set { defaults.set(newValue, forKey: "vime.pinyinLookupInJapanese") }
    }
    /// Chinese input shows traditional characters (OpenCC s2t), toggled by
    /// the 简/繁 button where Japanese has the kana toggle.
    var traditionalChinese: Bool {
        get { defaults.object(forKey: "vime.traditionalChinese") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.traditionalChinese") }
    }
    /// Chinese input lets the local Chinese model reorder Rime's candidates.
    /// Separate from candidateRanking, which is Japanese's.
    var chineseLanguageModel: Bool {
        get { defaults.object(forKey: "vime.chineseLanguageModel") as? Bool ?? true }
        nonmutating set {
            if newValue && !chineseLanguageModel { requestNeuralRetry() }
            defaults.set(newValue, forKey: "vime.chineseLanguageModel")
        }
    }
    /// Which bundled Chinese model (and matching decoding mode) is active:
    /// v2 (task mode + self rescoring, default) or v1 (lm mode fallback).
    var chineseModelVersion: ChineseLanguageModel.Version {
        get { .v2 }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: ChineseLanguageModel.versionPreferenceKey)
        }
    }
    var japaneseModelVersion: JapaneseLanguageModelV6.Version {
        get { .v6 }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: JapaneseLanguageModelV6.versionPreferenceKey)
        }
    }
    /// Fuzzy pinyin groups for Chinese input, all off by default.
    var fuzzyPinyin: FuzzyPinyin {
        get { FuzzyPinyin.allCases.reduce(into: FuzzyPinyin()) { if defaults.bool(forKey: $1.key) { $0.insert($1) } } }
        nonmutating set { for group in FuzzyPinyin.allCases { defaults.set(newValue.contains(group), forKey: group.key) } }
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
    /// Seconds a key preview stays after the finger lifts.
    static let previewHoldRange: ClosedRange<Double> = 0...0.5
    var previewHold: Double {
        get { Self.clampedPreviewHold(defaults.object(forKey: "vime.previewHold") as? Double ?? 0) }
        nonmutating set { defaults.set(Self.clampedPreviewHold(newValue), forKey: "vime.previewHold") }
    }
    static func clampedPreviewHold(_ value: Double) -> Double {
        value.isFinite ? min(previewHoldRange.upperBound, max(previewHoldRange.lowerBound, value)) : 0
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
        get { defaults.object(forKey: "vime.undoConversionOnBackspace") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.undoConversionOnBackspace") }
    }
    /// Japanese mode only; what space inserts when nothing is being composed.
    /// Swipe-up symbols on the Chinese letter keys use Chinese punctuation.
    var chinesePunctuation: Bool {
        get { defaults.object(forKey: "vime.chinesePunctuation") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.chinesePunctuation") }
    }
    /// Chinese typo corrections show the pinyin they were found by.
    var correctionSpellingHints: Bool {
        get { defaults.object(forKey: "vime.correctionSpellingHints") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.correctionSpellingHints") }
    }
    /// Swipe-up symbols on the Japanese letter keys are full width.
    var japaneseFullWidthSymbols: Bool {
        get { defaults.object(forKey: "vime.japaneseFullWidthSymbols") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.japaneseFullWidthSymbols") }
    }
    var fullWidthSpace: Bool {
        get { defaults.object(forKey: "vime.fullWidthSpace") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.fullWidthSpace") }
    }
    /// The preedit shows the best conversion while typing kana.
    var liveConversion: Bool {
        get { defaults.object(forKey: "vime.liveConversion") as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: "vime.liveConversion") }
    }
    /// Offers the iOS text replacements the keyboard can read as candidates.
    var textReplacements: Bool {
        get { defaults.object(forKey: "vime.textReplacements") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.textReplacements") }
    }
    /// English mode only; spelling completions in the candidate bar.
    var englishCompletion: Bool {
        get { defaults.object(forKey: "vime.englishCompletion") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "vime.englishCompletion") }
    }
    /// Upright iPhone only; narrows the keys toward one side.
    var oneHanded: KeyboardOneHandedSide {
        get { defaults.string(forKey: "vime.oneHanded").flatMap(KeyboardOneHandedSide.init(rawValue:)) ?? .off }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "vime.oneHanded") }
    }
    /// Date format for Chinese special conversions (`rq`, `jt`, etc.).
    var chineseDateFormat: ChineseSpecialConversions.DateFormat {
        get { defaults.string(forKey: "vime.chineseDateFormat").flatMap(ChineseSpecialConversions.DateFormat.init(rawValue:)) ?? .chinese }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "vime.chineseDateFormat") }
    }
    /// Time format for Chinese special conversions (`sj`, `xz`, etc.).
    var chineseTimeFormat: ChineseSpecialConversions.TimeFormat {
        get { defaults.string(forKey: "vime.chineseTimeFormat").flatMap(ChineseSpecialConversions.TimeFormat.init(rawValue:)) ?? .colon }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "vime.chineseTimeFormat") }
    }
    /// How Chinese is typed: full pinyin on QWERTY, or pinyin on nine keys.
    var chineseLayout: ChineseKeyboardLayout {
        get { defaults.string(forKey: "vime.chineseLayout").flatMap(ChineseKeyboardLayout.init(rawValue:)) ?? .fullPinyin }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "vime.chineseLayout") }
    }
    var shuangpinScheme: ShuangpinScheme {
        get { defaults.string(forKey: "vime.shuangpinScheme").flatMap(ShuangpinScheme.init(rawValue:)) ?? .flypy }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "vime.shuangpinScheme") }
    }
}

/// The Chinese key plane: full pinyin on QWERTY, pinyin on a phone keypad,
/// or 双拼 on QWERTY.
nonisolated enum ChineseKeyboardLayout: String, CaseIterable, Sendable { case fullPinyin, nineKey, shuangpin }

nonisolated enum KeyboardOneHandedSide: String, CaseIterable, Sendable { case off, left, right }

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
