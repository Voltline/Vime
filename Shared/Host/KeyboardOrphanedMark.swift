import Foundation

/// Marked text the keyboard left in the host when it went away.
///
/// Some hosts (WeChat) dismiss the keyboard on scroll but keep the
/// underlined preedit in their field. When the keyboard shows again, it
/// clears that leftover, as the host's own keyboards do.
///
/// Only a flag is stored, never the text. It lives in the App Group's
/// defaults because the extension process is often ended while hidden.
/// Clearing sends an empty mark: on a field that kept no mark, that changes
/// nothing, so the host's text need not be matched first. The proxy context
/// may arrive after the keyboard appears, so each showing tries a few times
/// and stops once the user types.
@MainActor
final class KeyboardOrphanedMark {
    static let defaultsKey = "vime.host.orphanedMark"
    /// Delays after appearing at which a clear is retried.
    static let retryDelays: [TimeInterval] = [0.1, 0.3]
    /// Where the keyboard keeps the flag. Tests point this at a private suite.
    nonisolated(unsafe) static var sharedDefaults = UserDefaults(suiteName: KeyboardPreferences.appGroup)

    private let defaults: UserDefaults?
    /// Clears may be attempted during this showing.
    private(set) var isArmed = false
    /// A clear was sent during this showing.
    private var cleared = false

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    var isRecorded: Bool { defaults?.bool(forKey: Self.defaultsKey) == true }

    /// The keyboard is going away, or the host moved on, while its preedit was still marked.
    /// Ends this showing's clears, so its last retry cannot drop the new flag.
    func record() {
        isArmed = false
        defaults?.set(true, forKey: Self.defaultsKey)
    }

    /// A new showing begins; arms clearing when a leftover was recorded.
    func beginShowing() {
        isArmed = isRecorded
        cleared = false
    }

    /// Whether to send the clear now. Never over a selection, which an empty
    /// mark would delete, nor over the keyboard's own new composition.
    func shouldClear(hasComposition: Bool, selectedText: String?) -> Bool {
        guard isArmed, !hasComposition else { return false }
        return selectedText?.isEmpty != false
    }

    /// The user typed: their input replaces any leftover mark.
    func cancel() {
        guard isArmed || isRecorded else { return }
        isArmed = false
        defaults?.removeObject(forKey: Self.defaultsKey)
    }

    /// A clear was sent to the host.
    func noteCleared() {
        cleared = true
    }

    /// The last retry of this showing ran. The flag stays when no clear could
    /// be sent (the keyboard went away first), so the next showing tries again.
    func finishShowing() {
        guard isArmed else { return }
        isArmed = false
        if cleared { defaults?.removeObject(forKey: Self.defaultsKey) }
    }
}
