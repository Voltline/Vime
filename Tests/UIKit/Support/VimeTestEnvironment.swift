import XCTest

/// The test bundle's principal class. Keyboards built from stored settings
/// read the App Group, which a simulator keeps between runs; the input
/// language is pinned to Japanese, with Chinese input on and live conversion
/// off (it changes what typing shows), for the run and all three are
/// restored afterwards.
@objc(VimeTestEnvironment)
final class VimeTestEnvironment: NSObject, XCTestObservation {
    private static let pinnedKeys = ["vime.inputLanguage", "vime.chineseInputEnabled", "vime.liveConversion"]
    private var stored: [String: Any] = [:]

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        MainActor.assumeIsolated {
            let preferences = KeyboardPreferences()
            for key in Self.pinnedKeys { stored[key] = preferences.store.object(forKey: key) }
            preferences.inputLanguage = .japanese
            preferences.chineseInputEnabled = true
            preferences.liveConversion = false
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        MainActor.assumeIsolated {
            let store = KeyboardPreferences().store
            for key in Self.pinnedKeys { store.set(stored[key], forKey: key) }
        }
    }
}
