import Foundation

/// Decides whether `LearningExclusionList` applies: only for the mainland
/// China App Store. The app records the storefront in the App Group; until it
/// has one, the system region setting decides.
nonisolated enum LearningExclusionPolicy {
    static let storefrontKey = "vime.storefront.country"

    /// `storefront` is ISO 3166-1 alpha-3 (StoreKit), `region` alpha-2 (Locale).
    static func isActive(storefront: String?, region: String?) -> Bool {
        if let storefront, !storefront.isEmpty { return storefront.uppercased() == "CHN" }
        return region?.uppercased() == "CN"
    }

    static func isActive(defaults: UserDefaults? = KeyboardPreferences.sharedStore(), locale: Locale = .current) -> Bool {
        isActive(storefront: defaults?.string(forKey: storefrontKey), region: locale.region?.identifier)
    }

    /// False when `text` may be typed but must not be learned, remembered or suggested.
    static func allowsLearning(_ text: String, active: Bool, list: LearningExclusionList = .shared) -> Bool {
        !(active && list.matches(text))
    }
}
