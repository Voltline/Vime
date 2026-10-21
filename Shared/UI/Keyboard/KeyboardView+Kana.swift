import UIKit

// The flick kana pad: four rows of utility, three kana keys and utility.
// 確定 spans the last two rows of the right column.
extension KeyboardView {
    func buildKanaKeys() {
        func kana(_ index: Int) -> (KeyboardKey, CGFloat) {
            let outputs = KeyboardKanaLayout.keys[index]
            let item = key(outputs[0]) {}
            item.0.flickOutputs = outputs
            item.0.flickAction = { [weak self] in self?.typeKana(key: index, flick: $0) }
            item.0.action = { [weak self] in self?.typeKana(key: index, flick: .center) }
            item.0.showsPreview = previewsEnabled
            item.0.accessibilityIdentifier = "vime.kana." + KeyboardKanaLayout.identifiers[index]
            letterKeys.append(item.0)
            return item
        }
        let next = symbol("arrow.right", label: String(localized: "下一个字"), weight: 1) { [weak self] in
            guard let self else { return }
            // Ends a toggle so the same key can start a new character; with
            // nothing to end, moves the caret like the system pad.
            if self.kanaToggle != nil { self.kanaToggle = nil }
            else if !self.session.isComposing { self.apply([.moveCursor(horizontal: 1, vertical: 0)]) }
        }
        next.0.accessibilityIdentifier = "vime.kana.next"
        let reverse = symbol("arrow.uturn.backward", label: String(localized: "上一个假名"), weight: 1) { [weak self] in
            guard let self else { return }
            var replaced: Character?
            guard let edits = self.session.replaceLastKana({ replaced = KeyboardKanaLayout.previous($0); return replaced }) else { return }
            if let toggle = self.kanaToggle, let replaced {
                self.kanaToggle = (toggle.key, replaced, Date.timeIntervalSinceReferenceDate)
            }
            self.apply(edits)
        }
        reverse.0.accessibilityIdentifier = "vime.kana.reverse"
        let letters = key("ABC", utility: true, weight: 1) { [weak self] in
            guard let self else { return }
            self.apply(self.session.toggleEnglish())
            self.shifted = false
            self.capsLocked = false
            self.rebuildKeys()
        }
        letters.0.accessibilityIdentifier = "vime.key.language"
        letters.0.accessibilityLabel = session.inputTraits.languageSwitchAccessibilityLabel
        let numbers = key("123", utility: true, weight: 1) { [weak self] in
            guard let self else { return }
            self.page = .numbers
            self.rebuildKeys()
        }
        let space = key(String(localized: "空格"), utility: true, weight: 1) { [weak self] in
            guard let self else { return }
            self.kanaToggle = nil
            self.apply(self.session.space())
        }
        space.0.accessibilityLabel = String(localized: "空格，转换候选")
        space.0.accessibilityIdentifier = "vime.key.space"
        spaceKey = space.0
        let enter = key(String(localized: "换行"), utility: true, weight: 1) { [weak self] in
            guard let self else { return }
            self.kanaToggle = nil
            self.apply(self.session.enter())
        }
        enter.0.accessibilityIdentifier = "vime.key.return"
        returnKey = enter.0
        let modifier = key("゛゜小", weight: 1) { [weak self] in
            guard let self else { return }
            self.kanaToggle = nil
            if let edits = self.session.replaceLastKana(KeyboardKanaLayout.modified) { self.apply(edits) }
        }
        modifier.0.accessibilityLabel = String(localized: "浊音、半浊音和小写")
        modifier.0.accessibilityIdentifier = "vime.kana.modifier"
        let punctuation = key("、。?!", weight: 1) {}
        punctuation.0.flickOutputs = KeyboardKanaLayout.punctuation
        punctuation.0.showsFlickHints = false
        punctuation.0.flickAction = { [weak self] flick in
            guard let self else { return }
            self.kanaToggle = nil
            self.apply(self.session.insertLiteral(KeyboardKanaLayout.punctuation[flick.rawValue]))
        }
        punctuation.0.action = { [weak button = punctuation.0] in button?.flickAction?(.center) }
        punctuation.0.accessibilityLabel = String(localized: "标点")
        punctuation.0.accessibilityIdentifier = "vime.kana.punctuation"
        rows = [[next, kana(0), kana(1), kana(2), deleteKey(weight: 1)],
                [reverse, kana(3), kana(4), kana(5), space],
                [letters, kana(6), kana(7), kana(8), enter],
                [numbers, modifier, kana(9), punctuation]]
    }

    func typeKana(key index: Int, flick: KeyFlick) {
        KeyboardPerformance.record(.touchUpToType, since: keysContainer.releaseStartedAt)
        let now = Date.timeIntervalSinceReferenceDate
        if flick == .center, let toggle = kanaToggle, toggle.key == index,
           now - toggle.time < KeyboardKanaLayout.toggleInterval,
           let next = KeyboardKanaLayout.next(after: toggle.output, key: index),
           let edits = session.replaceLastKana({ $0 == toggle.output ? next : nil }) {
            kanaToggle = (index, next, now)
            apply(edits)
            return
        }
        let text = KeyboardKanaLayout.keys[index][flick.rawValue]
        guard !text.isEmpty else { return }
        apply(session.type(text))
        kanaToggle = flick == .center ? (index, Character(text), now) : nil
    }
}
