import Foundation

/// The app requests deletion; the converter queue performs it before its next
/// use. Keeping request and completion separate also survives process termination.
nonisolated struct KeyboardLearningResetRequests: @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? (FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardPreferences.appGroup) != nil
            ? UserDefaults(suiteName: KeyboardPreferences.appGroup) : nil) ?? .standard
    }
    var requestID: String? { defaults.string(forKey: "vime.learningReset.request") }
    var completedID: String? { defaults.string(forKey: "vime.learningReset.completed") }
    var isPending: Bool { requestID != completedID }
    func request() { defaults.set(UUID().uuidString, forKey: "vime.learningReset.request") }
    func complete(_ id: String) { defaults.set(id, forKey: "vime.learningReset.completed") }
}
