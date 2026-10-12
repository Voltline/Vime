import Foundation

/// One policy shared by the App and the keyboard's quick settings.
nonisolated enum HapticIntensity {
    struct Level: Equatable, Sendable {
        let value: Double
        let title: String
    }
    static let levels = [Level(value: 0, title: "关闭"), Level(value: 0.6, title: "中"), Level(value: 1, title: "强")]
    // Four percentage points catches deliberate stops without rounding all input.
    static let snapRadius = 0.04
    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.6
    }
    static func snapped(_ value: Double) -> Double {
        let value = normalized(value)
        let nearest = levels.min { abs($0.value - value) < abs($1.value - value) }!
        return abs(nearest.value - value) <= snapRadius + 1e-7 ? nearest.value : value
    }
    static func description(_ value: Double) -> String {
        let value = normalized(value)
        if value == 0 { return "关闭" }
        if let level = levels.first(where: { abs($0.value - value) < 1e-7 }) {
            return "\(level.title) · \(Int((value * 100).rounded()))%"
        }
        return "\(Int((value * 100).rounded()))%"
    }
}
