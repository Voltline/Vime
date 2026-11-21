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
    nonisolated enum Gesture: Equatable, Sendable { case horizontalCursor, spaceCursor, deleteLine }
    var onGestureChange: ((Gesture?) -> Void)?
    var onCursorMove: ((Int, Int) -> Void)?
    var onDeleteLine: (() -> Void)?
    var onDeletePressChange: ((Bool) -> Void)?
    var onDeleteArmedChange: ((Bool) -> Void)?
    struct Region {
        let key: KeyboardKey
        let body: CGRect
        let cell: CGRect
    }

    struct LetterTapOutcome {
        let letter: Character
        let rawLetter: Character
        let point: CGPoint
        let body: CGRect
        let calibrationSwitched: Bool
        let jointBayesianSwitched: Bool
        let languageCorrected: Bool
    }

    private struct Press {
        var key: KeyboardKey
        /// The key under the finger when hit correction chose another.
        var touched: KeyboardKey?
        /// The uncalibrated geometric key before per-key calibration or language correction.
        var rawLetter: Character?
        var calibrationSwitched = false
        var jointBayesianSwitched = false
        var languageCorrected = false
        var keyBody: CGRect = .zero
        let origin: CGPoint
        var swipe = KeySwipeSelection()
        var alternateLocked = false
        var flick = KeyFlick.center
        let sequence: Int
    }

    var regions: [Region] = [] {
        didSet { interactionBounds = regions.reduce(CGRect.null) { $0.union($1.cell) } }
    }
    var scale: CGFloat = 1
    /// How plausible each letter is after the input so far plus the letters
    /// of keys still held down (passed in press order); nil: no correction.
    var letterPrior: ((String) -> KeyHitCorrection.Prior?)?
    /// Per-key calibrated anisotropic 2D Gaussian model; nil keeps exact geometric centers.
    var letterModel: ((Character) -> KeyHitCalibration.EffectiveModel)?
    /// Reported when a non-cancelled, non-alternate letter tap completes.
    var onLetterTapComplete: ((LetterTapOutcome) -> Void)?
    private var interactionBounds = CGRect.null
    private var presses: [AnyHashable: Press] = [:]
    private var nextSequence = 0
    private var gesture: Gesture?
    private var gestureOwner: AnyHashable?
    private var cursorPoint = CGPoint.zero
    private var spaceTimer: Timer?
    private var deleteArmed = false
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
        resolvedRegion(at: point, includeLanguagePrior: false)?.key
    }

    private func resolvedRegion(
        at point: CGPoint,
        includeLanguagePrior: Bool
    ) -> (key: KeyboardKey, rawKey: KeyboardKey, body: CGRect, calibrated: Bool, jointBayesian: Bool)? {
        let eligible = regions.filter { $0.key.isEnabled && !$0.key.isHidden && $0.key.isUserInteractionEnabled }
        // Visible key bodies are always anchored to their own key. Disjoint
        // cells split only the blank gaps at the adjacent edge midpoints.
        guard let raw = eligible.first(where: { $0.body.contains(point) })
            ?? eligible.first(where: { $0.cell.contains(point) }) else { return nil }
        guard raw.key.correctionLetter != nil, let letterModel else {
            return (raw.key, raw.key, raw.body, false, false)
        }

        var anyCalibrated = false
        var candidates: [(region: Region, letter: Character, model: KeyHitCalibration.EffectiveModel, spatial: Double)] = []
        candidates.reserveCapacity(9)
        for candidate in eligible {
            guard let letter = candidate.key.correctionLetter,
                  candidate.body.width > 0, candidate.body.height > 0,
                  abs(point.x - candidate.body.midX) <= candidate.body.width * 1.15,
                  abs(point.y - candidate.body.midY) <= candidate.body.height * 1.15 else { continue }
            let model = letterModel(letter)
            if model.weight > 0 { anyCalibrated = true }
            let spatial = KeyHitCalibration.spatialLogLikelihood(point: point, body: candidate.body, model: model)
            candidates.append((candidate, letter, model, spatial))
        }
        guard !candidates.isEmpty else { return (raw.key, raw.key, raw.body, false, false) }

        // 1. Pure personal anisotropic 2D Gaussian winner (only active if any nearby key is calibrated).
        let spatialWinner: (region: Region, letter: Character, model: KeyHitCalibration.EffectiveModel, spatial: Double)
        if anyCalibrated, let best = candidates.max(by: { $0.spatial < $1.spatial }) {
            spatialWinner = best
        } else if let rawCand = candidates.first(where: { $0.region.key === raw.key }) {
            spatialWinner = rawCand
        } else {
            return (raw.key, raw.key, raw.body, false, false)
        }
        let spatialSwitched = spatialWinner.region.key !== raw.key

        // 2. Joint Bayesian step: combine personal 2D Gaussian with language prior ONLY outside
        //    the winner's core safe zone so center taps are never hijacked.
        if includeLanguagePrior,
           !KeyHitCalibration.isInCoreSafeZone(point: point, body: spatialWinner.region.body, model: spatialWinner.model),
           let letterPrior {
            let held = presses.values.sorted { $0.sequence < $1.sequence }.compactMap(\.key.correctionLetter)
            if let prior = letterPrior(String(held)) {
                let winnerPrior = prior(spatialWinner.letter)
                let winnerJoint = spatialWinner.spatial
                    + KeyHitCalibration.languagePriorWeight * log(max(winnerPrior, 0.01))
                var bestJoint = spatialWinner
                var bestJointScore = winnerJoint
                for cand in candidates where cand.region.key !== spatialWinner.region.key {
                    let candPrior = prior(cand.letter)
                    guard candPrior > winnerPrior else { continue }
                    let score = cand.spatial + KeyHitCalibration.languagePriorWeight * log(max(candPrior, 0.01))
                    if score > bestJointScore {
                        bestJointScore = score
                        bestJoint = cand
                    }
                }
                if bestJoint.region.key !== spatialWinner.region.key,
                   bestJointScore >= winnerJoint + KeyHitCalibration.jointSwitchMargin {
                    return (bestJoint.region.key, raw.key, bestJoint.region.body, spatialSwitched, true)
                }
            }
        }

        return (spatialWinner.region.key, raw.key, spatialWinner.region.body, spatialSwitched, false)
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
        guard gesture == nil, presses[id] == nil,
              let resolved = resolvedRegion(at: point, includeLanguagePrior: true) else {
            KeyboardTouchDiagnostics.record("surface.touchDown", point: point, view: self, detail: "duplicate/unresolved")
            return false
        }
        let touched = resolved.key
        let key = resolved.jointBayesian ? touched : correctedKey(touched, at: point)
        let langCorrected = key !== touched
        let finalBody = regions.first(where: { $0.key === key })?.body ?? resolved.body
        KeyboardTouchDiagnostics.record("surface.touchDown", point: point, view: self, result: key,
            detail: key === resolved.rawKey ? "" : "corrected from \(resolved.rawKey.correctionLetter.map(String.init) ?? "?")")
        presses[id] = Press(
            key: key,
            touched: key === resolved.rawKey ? nil : resolved.rawKey,
            rawLetter: resolved.rawKey.correctionLetter,
            calibrationSwitched: resolved.calibrated,
            jointBayesianSwitched: resolved.jointBayesian,
            languageCorrected: langCorrected,
            keyBody: finalBody,
            origin: point,
            sequence: nextSequence
        )
        nextSequence += 1
        key.beginResolvedPress(deferRepeatingAction: key.repeats)
        if key.repeats { onDeleteArmedChange?(false) }
        spaceTimer?.invalidate(); spaceTimer = nil
        if key.accessibilityIdentifier == "vime.key.space", presses.count == 1 {
            let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
                guard let self, self.presses.count == 1, self.gesture == nil,
                      let press = self.presses[id], !press.alternateLocked else { return }
                self.startGesture(.spaceCursor, owner: id, at: press.origin)
            }
            spaceTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        return true
    }

    /// A letter tap near a neighbour that continues the input better.
    private func correctedKey(_ key: KeyboardKey, at point: CGPoint) -> KeyboardKey {
        guard let letter = key.correctionLetter, let letterPrior,
              let body = regions.first(where: { $0.key === key })?.body else { return key }
        let adjustedBody: (Character, CGRect) -> CGRect = { ch, rect in
            guard let model = self.letterModel?(ch), model.weight > 0 else { return rect }
            return rect.offsetBy(dx: CGFloat(model.dx) * rect.width, dy: CGFloat(model.dy) * rect.height)
        }
        let neighbours = regions.filter {
            $0.key !== key && $0.key.correctionLetter != nil && $0.key.isEnabled && !$0.key.isHidden
        }
        let choice = KeyHitCorrection.replacement(at: point, touched: .init(letter: letter, body: adjustedBody(letter, body)),
            neighbours: neighbours.map { .init(letter: $0.key.correctionLetter!, body: adjustedBody($0.key.correctionLetter!, $0.body)) }) {
            let held = self.presses.values.sorted { $0.sequence < $1.sequence }.compactMap(\.key.correctionLetter)
            return letterPrior(String(held))
        }
        return neighbours.first { $0.key.correctionLetter == choice }?.key ?? key
    }

    func movePress(id: AnyHashable, to point: CGPoint) {
        updatePress(id: id, to: point, allowsActivation: true)
    }

    private func updatePress(id: AnyHashable, to point: CGPoint, allowsActivation: Bool) {
        guard var press = presses[id] else { return }
        if gestureOwner == id {
            if gesture == .deleteLine {
                let armed = point.y <= press.origin.y - 18 * scale && abs(point.x - press.origin.x) < 80 * scale
                if armed != deleteArmed { deleteArmed = armed; onDeleteArmedChange?(armed) }
                return
            }
            let x = Int((point.x - cursorPoint.x) / (8 * scale))
            let y = gesture == .spaceCursor ? Int((point.y - cursorPoint.y) / (24 * scale)) : 0
            if x != 0 || y != 0 {
                cursorPoint.x += CGFloat(x) * 8 * scale
                cursorPoint.y += CGFloat(y) * 24 * scale
                onCursorMove?(x, y)
            }
            return
        }
        let delta = CGPoint(x: point.x - press.origin.x, y: point.y - press.origin.y)
        // Flick keys own every direction: no cursor gesture, no alternate.
        if press.key.flickOutputs != nil {
            press.flick = KeyFlick.resolve(x: Double(delta.x), y: Double(delta.y), scale: Double(scale))
            presses[id] = press
            press.key.presentFlick(press.flick)
            return
        }
        if allowsActivation, presses.count == 1 {
            if press.key.repeats, delta.y <= -30 * scale, abs(delta.x) < 30 * scale {
                startGesture(.deleteLine, owner: id, at: point); return
            }
            if !press.key.repeats, !press.alternateLocked, abs(delta.x) >= 60 * scale,
               abs(delta.x) > abs(delta.y) * 1.6 {
                startGesture(.horizontalCursor, owner: id, at: point)
                onCursorMove?(delta.x > 0 ? 1 : -1, 0)
                return
            }
            if hypot(delta.x, delta.y) > 12 * scale { spaceTimer?.invalidate(); spaceTimer = nil }
        }
        if press.key.alternateAction != nil {
            press.swipe.move(x: Double(delta.x), y: Double(delta.y), scale: Double(scale),
                allowActivation: allowsActivation && point.y <= (press.touched ?? press.key).frame.minY - 2 * scale)
        }
        press.alternateLocked = press.alternateLocked || press.swipe.alternate
        // A swipe-up symbol is aimed at the key under the finger: undo the
        // hit correction so the preview and symbol come from that key.
        if press.swipe.alternate, let touched = press.touched {
            press.key.stopTracking()
            press.key.isHighlighted = false
            press.key = touched
            press.touched = nil
            touched.beginResolvedPress()
        }
        // Touch-down owns the key until release. Drift may activate an explicit
        // gesture, but must never select or preview a neighboring character.
        presses[id] = press
        press.key.presentResolvedPress(alternate: press.swipe.alternate)
    }

    func endPress(id: AnyHashable, at point: CGPoint, cancelled: Bool = false) {
        let releaseTime = KeyboardPerformance.start()
        // The final sample may retain/cancel a swipe, but cannot start one. Don't reinterpret
        // the lift-off/rolling motion as a deliberate move to another key.
        if !cancelled { updatePress(id: id, to: point, allowsActivation: false) }
        spaceTimer?.invalidate(); spaceTimer = nil
        if gestureOwner == id {
            if let press = presses.removeValue(forKey: id) { finish(press, cancelled: true) }
            let delete = gesture == .deleteLine && deleteArmed && !cancelled
            gesture = nil; gestureOwner = nil; onGestureChange?(nil)
            deleteArmed = false; onDeletePressChange?(false)
            if delete { onDeleteLine?() }
            return
        }
        guard let press = presses.removeValue(forKey: id) else { return }
        if press.key.repeats { onDeletePressChange?(presses.values.contains { $0.key.repeats }) }
        // Remove ownership before invoking an action: switching layouts may
        // cancel the remaining touches and remove these same key objects.
        let draggedAway = !press.alternateLocked && press.flick == .center
            && !interactionBounds.insetBy(dx: -12 * scale, dy: -12 * scale).contains(point)
        KeyboardTouchDiagnostics.record("surface.touchUp", point: point, view: self, result: press.key,
            detail: "cancelled=\(cancelled) draggedAway=\(draggedAway) alternate=\(press.swipe.alternate)")
        releaseStartedAt = releaseTime
        finish(press, cancelled: cancelled || draggedAway)
        releaseStartedAt = nil
    }

    private func finish(_ press: Press, cancelled: Bool) {
        if !cancelled, !press.swipe.alternate, press.flick == .center,
           let letter = press.key.correctionLetter, let rawLetter = press.rawLetter {
            onLetterTapComplete?(LetterTapOutcome(
                letter: letter,
                rawLetter: rawLetter,
                point: press.origin,
                body: press.keyBody,
                calibrationSwitched: press.calibrationSwitched,
                jointBayesianSwitched: press.jointBayesianSwitched,
                languageCorrected: press.languageCorrected
            ))
        }
        let stillPressed = presses.values.contains { $0.key === press.key }
        press.key.finishResolvedPress(cancelled: cancelled, alternate: press.swipe.alternate,
            stillPressed: stillPressed, deferredRepeat: press.key.repeats, flick: press.flick)
        // Actions can rebuild the layout/cancel every other touch. Re-read the
        // owners after the action before restoring a held finger's preview.
        if let remaining = presses.values.filter({ $0.key === press.key }).max(by: { $0.sequence < $1.sequence }) {
            if press.key.flickOutputs != nil { press.key.presentFlick(remaining.flick) }
            else { press.key.presentResolvedPress(alternate: remaining.swipe.alternate) }
        }
    }

    func cancelAllPresses() {
        KeyboardTouchDiagnostics.record("surface.cancelAll", view: self, detail: "active=\(presses.count)")
        let active = Array(presses.values)
        presses.removeAll()
        spaceTimer?.invalidate(); spaceTimer = nil
        deleteArmed = false; onDeletePressChange?(false)
        if gesture != nil { gesture = nil; gestureOwner = nil; onGestureChange?(nil) }
        for press in active { finish(press, cancelled: true) }
    }

    private func startGesture(_ value: Gesture, owner: AnyHashable, at point: CGPoint) {
        guard let press = presses[owner] else { return }
        spaceTimer?.invalidate(); spaceTimer = nil
        press.key.stopTracking()
        press.key.isHighlighted = false
        gesture = value; gestureOwner = owner; cursorPoint = point
        if value == .deleteLine {
            deleteArmed = true; onDeleteArmedChange?(true); onDeletePressChange?(true)
        }
        onGestureChange?(value)
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
