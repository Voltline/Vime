import StoreKit

/// Copies the App Store storefront country into the App Group so the keyboard,
/// which cannot use StoreKit, knows which store the app came from.
enum StorefrontRecorder {
    static func record(defaults: UserDefaults? = KeyboardPreferences.sharedStore()) async {
        guard let code = await Storefront.current?.countryCode, !code.isEmpty else { return }
        defaults?.set(code, forKey: LearningExclusionPolicy.storefrontKey)
    }
}
