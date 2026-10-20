import Foundation

/// The keyboard extension's last report to the containing app. A keyboard can
/// write the App Group only with full access, so a record proves both that Vime
/// was added and that full access was on when it last ran. No input text,
/// context or candidates are stored.
nonisolated struct KeyboardExtensionStatus: Codable, Equatable, Sendable {
    var lastSeen: Date
    var fullAccess: Bool
    /// Manifest version of the loaded language model; nil until first loaded.
    var modelVersion: String?
    var modelPaused = false

    static let key = "vime.extensionStatus"

    /// "4.2-epoch20-…" → "4.2". Unknown formats are shown unchanged.
    var modelShortVersion: String? {
        modelVersion.map { String($0.split(separator: "-").first ?? Substring($0)) }
    }

    static func load(from defaults: UserDefaults? = UserDefaults(suiteName: KeyboardPreferences.appGroup)) -> Self? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Only the extension process reports. The app and its test host also run
    /// the shared worker, and must never pretend that the keyboard is active.
    static var isExtensionProcess: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    static func update(defaults: UserDefaults? = UserDefaults(suiteName: KeyboardPreferences.appGroup),
                       requireExtension: Bool = true, _ change: (inout Self) -> Void) {
        guard !requireExtension || isExtensionProcess, let defaults else { return }
        var status = load(from: defaults) ?? Self(lastSeen: Date(), fullAccess: false)
        change(&status)
        guard let data = try? JSONEncoder().encode(status) else { return }
        defaults.set(data, forKey: key)
    }
}
