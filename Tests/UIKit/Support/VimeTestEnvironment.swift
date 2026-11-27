import XCTest

/// The test bundle's principal class. Keyboards built from stored settings
/// read the App Group, which a simulator keeps between runs; the input
/// language is pinned to Japanese, with Chinese input on in simplified
/// characters and live conversion off (it changes what typing shows), for
/// the run and all are restored afterwards. Key hit calibration stays in
/// memory, so taps one run teaches never move the keys of the next. The
/// leftover-mark flag uses a private suite.
@objc(VimeTestEnvironment)
final class VimeTestEnvironment: NSObject, XCTestObservation {
    private static let pinnedKeys = ["vime.inputLanguage", "vime.chineseInputEnabled", "vime.liveConversion", "vime.traditionalChinese"]
    private static let orphanedMarkSuite = "VimeTestEnvironment.orphanedMark"
    private var stored: [String: Any] = [:]

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        MainActor.assumeIsolated {
            KeyHitCalibration.shared = KeyHitCalibration(directory: nil)
            // A leftover-mark flag from one test must not clear the next test's input.
            UserDefaults().removePersistentDomain(forName: Self.orphanedMarkSuite)
            KeyboardOrphanedMark.sharedDefaults = UserDefaults(suiteName: Self.orphanedMarkSuite)
            let preferences = KeyboardPreferences()
            for key in Self.pinnedKeys { stored[key] = preferences.store.object(forKey: key) }
            preferences.inputLanguage = .japanese
            preferences.chineseInputEnabled = true
            preferences.liveConversion = false
            preferences.traditionalChinese = false
        }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        KeyboardOrphanedMark.sharedDefaults?.removeObject(forKey: KeyboardOrphanedMark.defaultsKey)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        MainActor.assumeIsolated {
            let store = KeyboardPreferences().store
            for key in Self.pinnedKeys { store.set(stored[key], forKey: key) }
        }
    }
}
