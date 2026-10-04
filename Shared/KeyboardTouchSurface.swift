import UIKit

/// The extension host can discard touches on fully transparent rendered pixels
/// before UIKit's hitTest is called. Keep a small nonzero backing on surfaces
/// that handle gaps; changing UIView.alpha would also fade every key/subview.
enum KeyboardTouchBacking {
    static let color = UIColor(white: 0.5, alpha: 0.01)
}

/// A single geometric resolver owns the key plane. UIKit's view order is not
/// used to choose between neighboring keys, and release need not hit a button.
final class KeyboardTouchSurface: UIView {
    struct Region {
        let key: KeyboardKey
        let body: CGRect
        let cell: CGRect
    }

    private struct Press {
        var key: KeyboardKey
        var origin: CGPoint
        var swipe = KeySwipeSelection()
        var alternateLocked = false
        var sequence: Int
    }

    var regions: [Region] = [] {
        didSet { interactionBounds = regions.reduce(CGRect.null) { $0.union($1.cell) } }
    }
    var scale: CGFloat = 1
    private var interactionBounds = CGRect.null
    private var presses: [AnyHashable: Press] = [:]
    private var nextSequence = 0
    private(set) var releaseStartedAt: TimeInterval?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = KeyboardTouchBacking.color
        accessibilityIdentifier = "vime.touch.surface"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resolvedKey(at point: CGPoint) -> KeyboardKey? {
        let eligible = regions.filter { $0.key.isEnabled && !$0.key.isHidden && $0.key.isUserInteractionEnabled }
        // Visible key bodies are always anchored to their own key. Disjoint
        // cells split only the blank gaps at the adjacent edge midpoints.
        return eligible.first { $0.body.contains(point) }?.key
            ?? eligible.first { $0.cell.contains(point) }?.key
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, alpha >= 0.01, bounds.contains(point) else {
            KeyboardTouchDiagnostics.record("container.hitTest", point: point, view: self, detail: "outside/hidden/disabled")
            return nil
        }
        let key = resolvedKey(at: point)
        KeyboardTouchDiagnostics.record("container.hitTest", point: point, view: self, result: key)
        return key == nil ? nil : self
    }

    // These are the actual native touch handlers' state transitions, exposed
    // internally so geometry/lifecycle tests do not synthesize private UITouch.
    @discardableResult
    func beginPress(id: AnyHashable, at point: CGPoint) -> Bool {
        guard presses[id] == nil, let key = resolvedKey(at: point) else {
            KeyboardTouchDiagnostics.record("surface.touchDown", point: point, view: self, detail: "duplicate/unresolved")
            return false
        }
        KeyboardTouchDiagnostics.record("surface.touchDown", point: point, view: self, result: key)
        presses[id] = Press(key: key, origin: point, sequence: nextSequence)
        nextSequence += 1
        key.beginResolvedPress()
        return true
    }

    func movePress(id: AnyHashable, to point: CGPoint) {
        updatePress(id: id, to: point, allowsTransfer: true)
    }

    private func updatePress(id: AnyHashable, to point: CGPoint, allowsTransfer: Bool) {
        guard var press = presses[id] else { return }
        let delta = CGPoint(x: point.x - press.origin.x, y: point.y - press.origin.y)
        if press.key.alternateAction != nil {
            press.swipe.move(x: Double(delta.x), y: Double(delta.y))
        }
        press.alternateLocked = press.alternateLocked || press.swipe.alternate
        // A tiny move across a gap boundary keeps its original owner. A
        // deliberate correction must enter the neighboring painted key's core
        // and travel at least half a key (18 scaled points minimum). A release
        // alone cannot retarget a tap. Alternate swipes never transfer.
        let correctionDistance = max(18 * scale, min(press.key.bounds.width, press.key.bounds.height) / 2)
        if allowsTransfer, !press.alternateLocked,
           hypot(delta.x, delta.y) >= correctionDistance,
           let neighbor = resolvedKey(at: point), neighbor !== press.key,
           let region = regions.first(where: { $0.key === neighbor }),
           region.body.insetBy(dx: 5 * scale, dy: 5 * scale).contains(point),
           !press.key.repeats, !neighbor.repeats {
            let previous = press
            press.key = neighbor
            press.origin = point
            press.swipe.reset()
            presses[id] = press
            finish(previous, cancelled: true)
            neighbor.beginResolvedPress()
        }
        presses[id] = press
        press.key.presentResolvedPress(alternate: press.swipe.alternate)
    }

    func endPress(id: AnyHashable, at point: CGPoint, cancelled: Bool = false) {
        let releaseTime = KeyboardPerformance.start()
        // Include the final sample for swipe selection, but don't reinterpret
        // the lift-off/rolling motion as a deliberate move to another key.
        if !cancelled { updatePress(id: id, to: point, allowsTransfer: false) }
        guard let press = presses.removeValue(forKey: id) else { return }
        // Remove ownership before invoking an action: switching layouts may
        // cancel the remaining touches and remove these same key objects.
        let draggedAway = !press.alternateLocked
            && !interactionBounds.insetBy(dx: -12 * scale, dy: -12 * scale).contains(point)
        KeyboardTouchDiagnostics.record("surface.touchUp", point: point, view: self, result: press.key,
            detail: "cancelled=\(cancelled) draggedAway=\(draggedAway) alternate=\(press.swipe.alternate)")
        releaseStartedAt = releaseTime
        finish(press, cancelled: cancelled || draggedAway)
        releaseStartedAt = nil
    }

    private func finish(_ press: Press, cancelled: Bool) {
        let stillPressed = presses.values.contains { $0.key === press.key }
        press.key.finishResolvedPress(cancelled: cancelled, alternate: press.swipe.alternate, stillPressed: stillPressed)
        // Actions can rebuild the layout/cancel every other touch. Re-read the
        // owners after the action before restoring a held finger's preview.
        if let remaining = presses.values.filter({ $0.key === press.key }).max(by: { $0.sequence < $1.sequence }) {
            press.key.presentResolvedPress(alternate: remaining.swipe.alternate)
        }
    }

    func cancelAllPresses() {
        KeyboardTouchDiagnostics.record("surface.cancelAll", view: self, detail: "active=\(presses.count)")
        let active = Array(presses.values)
        presses.removeAll()
        for press in active { finish(press, cancelled: true) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { beginPress(id: ObjectIdentifier(touch), at: touch.location(in: self)) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { movePress(id: ObjectIdentifier(touch), to: touch.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { endPress(id: ObjectIdentifier(touch), at: touch.location(in: self)) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { endPress(id: ObjectIdentifier(touch), at: .zero, cancelled: true) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelAllPresses() }
    }
}
