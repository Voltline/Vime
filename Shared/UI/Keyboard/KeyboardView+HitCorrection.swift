import UIKit

// Hit correction: which letters can continue the input, per language.
extension KeyboardView {
    func hitCorrectionPrior(held: String) -> KeyHitCorrection.Prior? {
        guard panel == .keyboard, page == .letters, !kanaLayoutActive, !capsLocked,
              !(shifted && shiftTypesCapitals) else { return nil }
        switch session.inputTraits.language {
        case .japanese: return KeyHitCorrection.romajiPrior(after: session.raw + held)
        case .chinese: return KeyHitCorrection.pinyinPrior(after: session.raw + held)
        case .english:
            let word = Self.trailingWord(in: session.leftContextProvider?() ?? "") + held
            return englishPrior(after: word)
        }
    }

    /// Letters that keep the word a prefix of some English word. Only when the
    /// word so far is one, so names and slang are left alone.
    func englishPrior(after word: String) -> KeyHitCorrection.Prior? {
        guard !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isLetter }), beginsEnglishWord(word) else { return nil }
        return { [weak self] letter in
            guard let self else { return 1 }
            return self.beginsEnglishWord(word + String(letter)) ? 1 : 0
        }
    }

    private func beginsEnglishWord(_ text: String) -> Bool {
        if let cached = englishPrefixCache[text] { return cached }
        let checker = sharedTextChecker()
        let range = NSRange(location: 0, length: text.utf16.count)
        let result = text.count < 2
            || checker.rangeOfMisspelledWord(in: text, range: range, startingAt: 0, wrap: false, language: "en_US").location == NSNotFound
            || !(checker.completions(forPartialWordRange: range, in: text, language: "en_US") ?? []).isEmpty
        if englishPrefixCache.count > 512 { englishPrefixCache.removeAll() }
        englishPrefixCache[text] = result
        return result
    }

    // MARK: - Per-Key Independent EMA Hit Calibration

    struct HitCalibrationTracker {
        struct PendingTap {
            let letter: Character
            let point: CGPoint
            let body: CGRect
            let bucket: KeyHitCalibration.LayoutBucket
            let timestamp: TimeInterval
        }
        var pendingTaps: [PendingTap] = []
        var lastDeleted: PendingTap?
        var deletedAt: TimeInterval = 0
        static let neighborFixWindow: TimeInterval = 1.2
    }

    var hitCalibrationBucket: KeyHitCalibration.LayoutBucket {
        if pad { return .pad }
        switch activeOneHandedSide {
        case .left: return .oneHandedLeft
        case .right: return .oneHandedRight
        case .off: return compact ? .landscape : .portrait
        }
    }

    func hitCalibrationOffset(for letter: Character, body: CGRect) -> CGPoint {
        guard panel == .keyboard, page == .letters, !kanaLayoutActive else { return .zero }
        return hitCalibration.effectivePointOffset(for: letter, body: body, in: hitCalibrationBucket)
    }

    func recordCalibratedLetterTap(_ outcome: KeyboardTouchSurface.LetterTapOutcome) {
        guard panel == .keyboard, page == .letters, !kanaLayoutActive else { return }
        let now = Date().timeIntervalSince1970
        let bucket = hitCalibrationBucket

        // Check if this tap immediately corrects a just-deleted neighboring letter.
        if let deleted = hitCalibrationTracker.lastDeleted,
           now - hitCalibrationTracker.deletedAt <= HitCalibrationTracker.neighborFixWindow,
           deleted.bucket == bucket,
           deleted.letter != outcome.letter,
           outcome.body.width > 0, outcome.body.height > 0,
           abs(deleted.body.midX - outcome.body.midX) <= outcome.body.width * 1.6,
           abs(deleted.body.midY - outcome.body.midY) <= outcome.body.height * 1.4 {
            hitCalibration.learnNeighborCorrection(
                intendedLetter: outcome.letter,
                mistypedLetter: deleted.letter,
                mistypedPoint: deleted.point,
                intendedBody: outcome.body,
                bucket: bucket,
                timestamp: now
            )
            hitCalibrationTracker.lastDeleted = nil
        } else {
            hitCalibrationTracker.lastDeleted = nil
        }

        hitCalibration.recordTapObservation(
            letter: outcome.letter,
            rawLetter: outcome.rawLetter,
            point: outcome.point,
            body: outcome.body,
            bucket: bucket,
            calibrationSwitched: outcome.calibrationSwitched,
            languageCorrected: outcome.languageCorrected,
            timestamp: now
        )

        hitCalibrationTracker.pendingTaps.append(.init(
            letter: outcome.letter,
            point: outcome.point,
            body: outcome.body,
            bucket: bucket,
            timestamp: now
        ))
        if hitCalibrationTracker.pendingTaps.count > 64 {
            hitCalibrationTracker.pendingTaps.removeFirst(hitCalibrationTracker.pendingTaps.count - 64)
        }
    }

    func recordCalibrationBackspace(bulk: Bool = false) {
        if bulk {
            hitCalibrationTracker.pendingTaps.removeAll()
            hitCalibrationTracker.lastDeleted = nil
            return
        }
        if let popped = hitCalibrationTracker.pendingTaps.popLast() {
            hitCalibrationTracker.lastDeleted = popped
            hitCalibrationTracker.deletedAt = Date().timeIntervalSince1970
        } else {
            hitCalibrationTracker.lastDeleted = nil
        }
    }

    func recordCalibrationEdits(_ edits: [KeyboardEdit]) {
        guard !hitCalibrationTracker.pendingTaps.isEmpty else { return }
        let committedWordOrPhrase = edits.contains { edit in
            switch edit {
            case .insert(let text):
                // Single ASCII letters in English mode stay pending until space/punctuation/commit.
                if text.count == 1, let ch = text.first, ch.isASCII, ch.isLetter { return false }
                return !text.isEmpty
            case .insertPair:
                return true
            default:
                return false
            }
        }
        guard committedWordOrPhrase else { return }
        let taps = hitCalibrationTracker.pendingTaps
        hitCalibrationTracker.pendingTaps.removeAll(keepingCapacity: true)
        hitCalibrationTracker.lastDeleted = nil
        for tap in taps {
            hitCalibration.learnCommittedTap(
                letter: tap.letter,
                point: tap.point,
                body: tap.body,
                bucket: tap.bucket,
                timestamp: tap.timestamp
            )
        }
    }
}
