import XCTest

/// The bundle's principal class, created before any test runs. Tests run inside
/// the app on a simulator whose shared preferences the developer may have
/// changed; live conversion changes what typing shows, so the run starts with it
/// off and puts the developer's setting back when it finishes.
final class TestRunDefaults: NSObject, XCTestObservation {
    private var liveConversion = false

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        liveConversion = KeyboardPreferences().liveConversion
        KeyboardPreferences().liveConversion = false
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        KeyboardPreferences().liveConversion = liveConversion
    }
}
