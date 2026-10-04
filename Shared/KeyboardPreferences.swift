import Foundation

struct KeyboardPreferences {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
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
}

/// Swipe selection is reversible until release; cancelled gestures never insert.
struct KeySwipeSelection {
    private(set) var alternate = false
    mutating func move(x: Double, y: Double) {
        alternate = y <= -18 && abs(x) < max(36, abs(y))
    }
    mutating func reset() { alternate = false }
}
