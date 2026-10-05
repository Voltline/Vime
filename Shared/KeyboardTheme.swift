import UIKit

enum KeyboardTheme: String, CaseIterable {
    case system, sakura, ocean, midnight
    var title: String {
        switch self { case .system: "系统"; case .sakura: "樱花"; case .ocean: "海蓝"; case .midnight: "深夜" }
    }
    var accent: UIColor {
        switch self {
        case .system: UIColor(cgColor: VimeLogo.blue)
        case .sakura: UIColor(red: 0.72, green: 0.18, blue: 0.38, alpha: 1)
        case .ocean: UIColor(red: 0.06, green: 0.42, blue: 0.74, alpha: 1)
        case .midnight: UIColor(red: 0.55, green: 0.68, blue: 1, alpha: 1)
        }
    }
    var background: UIColor {
        switch self {
        case .system: .clear
        case .sakura: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.23, green: 0.13, blue: 0.18, alpha: 0.96) : UIColor(red: 0.98, green: 0.90, blue: 0.93, alpha: 0.96) }
        case .ocean: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.16, blue: 0.23, alpha: 0.96) : UIColor(red: 0.87, green: 0.94, blue: 0.99, alpha: 0.96) }
        case .midnight: UIColor(white: 0.10, alpha: 0.98)
        }
    }
    var key: UIColor {
        if self == .midnight { return UIColor(white: 0.22, alpha: 1) }
        return UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.28, alpha: 1) : .white }
    }
    var utility: UIColor {
        switch self {
        case .system: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.21, alpha: 1) : UIColor(red: 196/255, green: 200/255, blue: 206/255, alpha: 1) }
        case .sakura: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.33, green: 0.19, blue: 0.25, alpha: 1) : UIColor(red: 0.91, green: 0.74, blue: 0.80, alpha: 1) }
        case .ocean: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.26, blue: 0.36, alpha: 1) : UIColor(red: 0.67, green: 0.82, blue: 0.92, alpha: 1) }
        case .midnight: UIColor(white: 0.16, alpha: 1)
        }
    }
    var text: UIColor { self == .midnight ? .white : .label }
}
