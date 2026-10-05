import Foundation

struct KeyboardPreferences {
    static let appGroup = "group.com.Voltline.Vime"
    static let heightRange = 0.85...1.60
    private let defaults: UserDefaults
    private let heightDefaults: UserDefaults
    init(defaults: UserDefaults = .standard, heightDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.heightDefaults = heightDefaults ?? (defaults === UserDefaults.standard
            && FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) != nil
            ? UserDefaults(suiteName: Self.appGroup) : nil) ?? defaults
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
    func reloadSharedHeight() { heightDefaults.synchronize() }
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
}

/// Swipe selection is reversible until release; cancelled gestures never insert.
struct KeySwipeSelection {
    private(set) var alternate = false
    mutating func move(x: Double, y: Double) {
        alternate = y <= -18 && abs(x) < max(36, abs(y))
    }
    mutating func reset() { alternate = false }
}
