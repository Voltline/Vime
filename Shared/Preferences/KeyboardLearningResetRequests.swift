import Foundation

/// The app requests deletion; the converter queue performs it before its next
/// use. Keeping request and completion separate also survives process termination.
/// The default requests reset every language; `chinese` resets only pinyin.
nonisolated struct KeyboardLearningResetRequests: @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String
    init(defaults: UserDefaults? = nil) {
        self.init(defaults: defaults ?? (FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup) != nil
            ? UserDefaults(suiteName: KeyboardPreferences.appGroup) : nil) ?? .standard, prefix: "vime.learningReset")
    }
    private init(defaults: UserDefaults, prefix: String) {
        self.defaults = defaults
        self.prefix = prefix
    }
    /// Requests that clear only what pinyin input learned.
    var chinese: KeyboardLearningResetRequests { KeyboardLearningResetRequests(defaults: defaults, prefix: "vime.chineseLearningReset") }
    var requestKey: String { prefix + ".request" }
    var completedKey: String { prefix + ".completed" }
    var requestID: String? { defaults.string(forKey: requestKey) }
    var completedID: String? { defaults.string(forKey: completedKey) }
    var isPending: Bool { requestID != completedID }
    func request() { defaults.set(UUID().uuidString, forKey: requestKey) }
    func complete(_ id: String) { defaults.set(id, forKey: completedKey) }

    /// Another store of learning, such as one process's pinyin dictionary,
    /// keeps its own completion: the request it has not yet carried out.
    func pendingID(for store: String) -> String? {
        guard let id = requestID, id != defaults.string(forKey: completedKey + "." + store) else { return nil }
        return id
    }
    func complete(_ id: String, for store: String) {
        defaults.set(id, forKey: completedKey + "." + store)
        // The app shows the Chinese reset as done once a keyboard carried it out.
        if prefix != "vime.learningReset" { complete(id) }
    }
}
