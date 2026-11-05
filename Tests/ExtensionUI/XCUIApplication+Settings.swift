import XCTest

extension XCUIApplication {
    /// Taps a tile on the settings home. The tiles sit in a lazy grid, so on
    /// smaller phones the lower rows exist only after scrolling to them.
    func openSettingsTile(_ identifier: String) {
        let tile = buttons[identifier]
        for _ in 0..<8 where !(tile.exists && tile.isHittable) { swipeUp() }
        tile.tap()
    }
}
