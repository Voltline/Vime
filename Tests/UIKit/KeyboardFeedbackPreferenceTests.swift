import XCTest

@MainActor
final class KeyboardFeedbackPreferenceTests: XCTestCase {
    func testAllLegacyLevelsMigrateOnceAndFractionalValuesSurviveReload() throws {
        for (legacy, expected) in [(0, 0.0), (1, 0.2), (2, 0.4), (3, 0.6), (4, 0.8), (5, 1.0)] {
            let name = "vime.haptic.migration.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(legacy, forKey: "vime.hapticLevel")
            let prefs = KeyboardPreferences(defaults: defaults)
            XCTAssertEqual(prefs.hapticIntensity, expected, accuracy: 1e-8)
            prefs.hapticIntensity = 0.42731
            defaults.set(0, forKey: "vime.hapticLevel")
            let reloaded = KeyboardPreferences(defaults: defaults)
            XCTAssertEqual(reloaded.hapticIntensity, 0.42731, accuracy: 1e-8)
            XCTAssertEqual(reloaded.snapshot.hapticIntensity, 0.42731, accuracy: 1e-8)
        }
    }
    func testSharedContinuousSettingWinsOverLegacyLocalValue() throws {
        let localName = "vime.haptic.local.\(UUID().uuidString)", sharedName = "vime.haptic.shared.\(UUID().uuidString)"
        let local = try XCTUnwrap(UserDefaults(suiteName: localName)), shared = try XCTUnwrap(UserDefaults(suiteName: sharedName))
        defer { local.removePersistentDomain(forName: localName); shared.removePersistentDomain(forName: sharedName) }
        local.set(5, forKey: "vime.hapticLevel")
        shared.set(0.3125, forKey: "vime.hapticIntensity")
        let prefs = KeyboardPreferences(defaults: local, sharedDefaults: shared)
        XCTAssertEqual(prefs.hapticIntensity, 0.3125)
        prefs.hapticIntensity = .nan; XCTAssertEqual(prefs.hapticIntensity, 0.6)
        prefs.hapticIntensity = -1; XCTAssertEqual(prefs.hapticIntensity, 0)
        prefs.hapticIntensity = 2; XCTAssertEqual(prefs.hapticIntensity, 1)
    }
    func testPreferenceReloadKeepsQuickSliderAliveUntilRelease() throws {
        let name = "vime.haptic.tracking.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = KeyboardPreferences(defaults: defaults)
        preferences.sound = false
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 390, height: 320),
                                    session: KeyboardSession(), preferences: preferences)
        keyboard.hasFullAccess = false
        func descendant<T: UIView>(_ root: UIView, id: String, type: T.Type) -> T? {
            if root.accessibilityIdentifier == id { return root as? T }
            return root.subviews.lazy.compactMap { descendant($0, id: id, type: type) }.first
        }
        try XCTUnwrap(descendant(keyboard, id: "vime.brand.settings", type: UIButton.self)).sendActions(for: .touchUpInside)
        let slider = try XCTUnwrap(descendant(keyboard, id: "vime.setting.haptics", type: HapticIntensitySlider.self))
        slider.setIntensity(0.627); slider.sendActions(for: .valueChanged)
        keyboard.reloadPreferences()
        XCTAssertTrue(descendant(keyboard, id: "vime.setting.haptics", type: HapticIntensitySlider.self) === slider,
                      "Replacing the slider during preference reload loses its release event")
        slider.sendActions(for: .touchUpInside)
        XCTAssertEqual(preferences.hapticIntensity, 0.6, accuracy: 1e-6)
        keyboard.reloadPreferences()
        XCTAssertEqual(descendant(keyboard, id: "vime.setting.haptics", type: HapticIntensitySlider.self)?.value,
                       Float(0.6))
    }
    func testSnapOnlyNearThreeAnchorsAndOnlyAtRelease() {
        XCTAssertEqual(HapticIntensity.levels.map(\.title), ["关闭", "中", "强"])
        for (raw, expected) in [(0.025, 0.0), (0.565, 0.6), (0.632, 0.6), (0.975, 1.0), (0.42731, 0.42731), (0.65, 0.65)] {
            XCTAssertEqual(HapticIntensity.snapped(raw), expected, accuracy: 1e-8)
        }
        let slider = HapticIntensitySlider()
        var events: [(Double, Bool)] = []
        slider.onValue = { events.append(($0, $1)) }
        slider.setIntensity(0.627)
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(Double(slider.value), 0.627, accuracy: 1e-6)
        XCTAssertEqual(events.last?.1, false)
        slider.sendActions(for: .touchUpOutside)
        XCTAssertEqual(Double(slider.value), 0.6, accuracy: 1e-6)
        XCTAssertEqual(events.last?.1, true)
        slider.accessibilityIncrement(); XCTAssertEqual(slider.value, 1)
        slider.accessibilityDecrement(); XCTAssertEqual(Double(slider.value), 0.6, accuracy: 1e-6)
        slider.accessibilityDecrement(); XCTAssertEqual(slider.value, 0)
        slider.accessibilityDecrement(); XCTAssertEqual(slider.value, 0)
    }
}
