import UIKit

/// Temporary, opt-in diagnostics for native extension event delivery. Release
/// builds contain no logging. Never records labels, characters or host text.
enum KeyboardTouchDiagnostics {
#if DEBUG
    private static let preference = "vime.debug.touchDiagnostics"
    private(set) static var enabled = UserDefaults.standard.bool(forKey: preference)
    static var sink: ((String) -> Void)?

    static func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: preference)
    }
#endif

    static func record(_ stage: String, point: CGPoint? = nil, view: UIView? = nil,
                       result: UIView? = nil, detail: String = "") {
#if DEBUG
        guard enabled else { return }
        let location = point.map { String(format: " x=%.3f y=%.3f", Double($0.x), Double($0.y)) } ?? ""
        let source = view.map { " view=\(type(of: $0)) bounds=\($0.bounds)" } ?? ""
        let target = result.map { " result=\(type(of: $0))" } ?? " result=nil"
        let message = "VIME_TOUCH \(stage)\(location)\(source)\(target) \(detail)"
        if let sink { sink(message) }
        else { NSLog("%@", message) }
#endif
    }
}
