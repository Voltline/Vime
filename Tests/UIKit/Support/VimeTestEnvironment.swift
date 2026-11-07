import XCTest

/// The test bundle's principal class. Keyboards built from stored settings
/// read the App Group, which a simulator keeps between runs; the input
/// language is pinned to Japanese for the run and restored afterwards.
@objc(VimeTestEnvironment)
final class VimeTestEnvironment: NSObject, XCTestObservation {
    private var storedLanguage: String?

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        MainActor.assumeIsolated {
            let store = KeyboardPreferences().store
            storedLanguage = store.string(forKey: "vime.inputLanguage")
            KeyboardPreferences().inputLanguage = .japanese
        }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        MainActor.assumeIsolated {
            KeyboardPreferences().store.set(storedLanguage, forKey: "vime.inputLanguage")
        }
    }
}
