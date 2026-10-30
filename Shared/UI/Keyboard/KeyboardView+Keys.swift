import UIKit

// Key rows: building each page, layout and touch regions, and key actions.
extension KeyboardView {
    func shouldConvertNumber(_ text: String) -> Bool {
        session.inputTraits.convertsNumbers && keyboardType == .default
            && !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
    func composesNumberPageInput(_ text: String) -> Bool {
        if shouldConvertNumber(text) { return true }
        let mark = session.markedText?.text ?? ""
        let numeric = !mark.isEmpty && mark.allSatisfy { "0123456789０１２３４５６７８９.．".contains($0) }
        return session.isComposing && !numeric && session.inputTraits.compositionInputSymbols.contains(text)
    }

    func layoutKeyGrid(metrics: KeyboardMetrics) {
        let scale = metrics.scale
        for (rowIndex, row) in rows.enumerated() {
            for (column, pair) in row.enumerated() {
                if kanaLayoutActive {
                    pair.0.frame = metrics.kanaFrame(row: rowIndex, column: column, rows: pair.0 === returnKey ? 2 : 1)
                } else if usesNumberPad {
                    pair.0.frame = metrics.numberPadFrame(row: rowIndex, column: column + (rowIndex < 3 ? 1 : 0))
                } else {
                    pair.0.frame = metrics.frame(row: rowIndex, column: column, letters: page == .letters,
                                                prolonged: rowIndex == 1 && row.count == 10)
                }
                pair.0.layer.cornerRadius = 6.2 * scale
                // Compact phone keys are shorter despite the wider viewport.
                // Typography follows their height rather than landscape width.
                let textScale = compact ? scale : min(scale, metrics.keyHeight / 46.5)
                var fontSize: CGFloat = compact ? (rowIndex == 3 ? 13 : 18)
                    : (rowIndex == 3 ? 15 : 21) * textScale
                if usesNumberPad {
                    let isDigit = Int(pair.0.title(for: .normal) ?? "") != nil
                    fontSize = compact ? (isDigit ? 18 : rowIndex == 3 ? 13 : 15)
                        : (isDigit ? 20 : rowIndex == 3 ? 14 : 16) * textScale
                    pair.0.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: compact ? 16 : 18 * textScale),
                        forImageIn: .normal)
                }
                if kanaLayoutActive {
                    let kana = pair.0.flickOutputs != nil && pair.0.title(for: .normal)?.count == 1
                    fontSize = compact ? (kana ? 20 : 14) : (kana ? 23 : 16) * textScale
                    pair.0.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: compact ? 16 : 18 * textScale),
                        forImageIn: .normal)
                }
                pair.0.hintLabel.font = .systemFont(ofSize: compact ? 8 : 9 * textScale)
                pair.0.titleLabel?.font = .systemFont(ofSize: fontSize)
                pair.0.applySkinMetrics(size: fontSize, scale: textScale)
            }
        }
        if usesNumberPad {
            let top = metrics.numberPadFrame(row: 0, column: 0)
            let bottom = metrics.numberPadFrame(row: 2, column: 0)
            numberSymbolRail?.frame = top.union(bottom)
            numberSymbolRail?.scale = scale
            numberSymbolRail?.layoutIfNeeded()
        }
        updateTouchBounds(metrics: metrics)
        if let key = rows.flatMap({ $0 }).first(where: { $0.0.repeats })?.0 {
            // The track covers the key and reaches one key height above it,
            // into the toolbar when the key sits on the top row.
            let top = max(4 * scale, key.frame.minY - metrics.keyHeight - 8 * scale)
            let left = max(0, key.frame.maxX - 240 * scale)
            deletePrompt.keySize = key.frame.size
            deletePrompt.frame = CGRect(x: left, y: top, width: key.frame.maxX - left, height: key.frame.maxY - top)
        }
    }

    func updateTouchBounds(metrics: KeyboardMetrics) {
        var regions: [KeyboardTouchSurface.Region] = []
        for (rowIndex, row) in rows.enumerated() {
            guard let first = row.first?.0 else { continue }
            let top = rowIndex == 0
                ? metrics.headerHeight
                : (rows[rowIndex - 1][0].0.frame.maxY + first.frame.minY) / 2
            let bottom = rowIndex == rows.count - 1
                ? bounds.height
                : (first.frame.maxY + rows[rowIndex + 1][0].0.frame.minY) / 2
            for (column, pair) in row.enumerated() {
                let key = pair.0
                // Boundaries lie in the gaps, never inside a painted key. This
                // respects wide utility keys as well as staggered letter rows.
                let leading = usesNumberPad && rowIndex < 3
                    ? (metrics.numberPadFrame(row: rowIndex, column: 0).maxX + first.frame.minX) / 2 : 0
                let left = column == 0 ? leading : (row[column - 1].0.frame.maxX + key.frame.minX) / 2
                var right = column == row.count - 1 ? bounds.width : (key.frame.maxX + row[column + 1].0.frame.minX) / 2
                var bottom = bottom
                // The flick pad's 確定 spans two rows: it owns the rest of the
                // column, and the row beside its lower half stops at the gap.
                if kanaLayoutActive, let tall = returnKey {
                    if key === tall { bottom = bounds.height }
                    else if column == row.count - 1, tall.frame.minX > key.frame.maxX, tall.frame.maxY > key.frame.minY {
                        right = (key.frame.maxX + tall.frame.minX) / 2
                    }
                }
                key.touchBounds = CGRect(x: left - key.frame.minX, y: top - key.frame.minY,
                                         width: right - left, height: bottom - top)
                regions.append(.init(key: key, body: key.frame,
                                     cell: CGRect(x: left, y: top, width: right - left, height: bottom - top)))
            }
        }
        keysContainer.regions = regions
        keysContainer.scale = metrics.scale
    }

    static func numberPadTitle(_ value: String) -> String {
        switch value {
        case "空格": String(localized: "空格")
        case "符号": String(localized: "符号")
        case "换行": String(localized: "换行")
        default: value
        }
    }

    func key(_ title: String, utility: Bool = false, weight: CGFloat = 1, action: @escaping () -> Void) -> (KeyboardKey, CGFloat) {
        let button = KeyboardKey(title: title)
        button.previewContainer = previewOverlay
        button.action = action
        button.feedback = { [weak self] in self?.playFeedback() }
        if utility {
            button.isUtility = true
            button.fillColor = KeyboardPalette.utility
            button.titleLabel?.font = .systemFont(ofSize: 16)
        }
        keysContainer.addSubview(button)
        return (button, weight)
    }

    func symbol(_ name: String, label: String, weight: CGFloat, action: @escaping () -> Void) -> (KeyboardKey, CGFloat) {
        let button = KeyboardKey(symbol: name)
        button.previewContainer = previewOverlay
        button.accessibilityLabel = label
        button.isUtility = true
        button.fillColor = KeyboardPalette.utility
        button.action = action
        button.feedback = { [weak self] in self?.playFeedback() }
        keysContainer.addSubview(button)
        return (button, weight)
    }

    func rebuildKeys() {
        rebuildingKeys = true
        defer { rebuildingKeys = false; invalidateKeyGrid() }
        keysContainer.cancelAllPresses()
        keysContainer.regions = []
        for row in rows { for (button, _) in row { button.stopTracking(); button.removeFromSuperview() } }
        rows = []
        letterKeys = []
        shiftKey = nil
        spaceKey = nil
        languageKey = nil
        returnKey = nil
        numberBackKey = nil
        kanaLayoutActive = usesKanaLayout
        kanaToggle = nil
        if kanaLayoutActive {
            buildKanaKeys()
            applyKeySkins(); updateKeyLabels(); refresh(); setNeedsLayout(); return
        }
        if page == .letters {
            for letters in ["qwertyuiop", "asdfghjkl", "zxcvbnm"] {
                var row: [(KeyboardKey, CGFloat)] = []
                if letters == "zxcvbnm" {
                    let shift = symbol("shift", label: String(localized: "切换大小写"), weight: 1.35) { [weak self] in self?.shift() }
                    shift.0.accessibilityIdentifier = "vime.key.shift"
                    shiftKey = shift.0
                    row.append(shift)
                }
                for character in letters {
                    let value = String(character)
                    let item = key(value.uppercased()) { [weak self] in
                        guard let self else { return }
                        KeyboardPerformance.record(.touchUpToType, since: self.keysContainer.releaseStartedAt)
                        self.apply(self.session.type(self.shifted && self.session.inputTraits.isEnglish ? value.uppercased() : value))
                        if self.shifted && !self.capsLocked { self.shifted = false; self.updateKeyLabels() }
                    }
                    item.0.showsPreview = previewsEnabled
                    item.0.accessibilityIdentifier = "vime.key." + value
                    item.0.hint = Self.letterHints[value]
                    item.0.alternateTitle = Self.letterHints[value]
                    item.0.alternateAction = { [weak self] in
                        guard let self, let hint = Self.letterHints[value] else { return }
                        self.insertSymbol(hint)
                    }
                    letterKeys.append(item.0)
                    row.append(item)
                }
                if letters == "zxcvbnm" { row.append(deleteKey(weight: 1.35)) }
                if letters == "asdfghjkl", preferences.prolongedKey, let prolongedInput = session.inputTraits.prolongedInput {
                    let prolonged = key(prolongedInput) { [weak self] in
                        guard let self else { return }
                        self.apply(self.session.type(prolongedInput))
                    }
                    prolonged.0.accessibilityLabel = String(localized: "长音符号")
                    prolonged.0.accessibilityIdentifier = "vime.key.prolonged"
                    row.append(prolonged)
                }
                rows.append(row)
            }
        } else if page == .numbers && preferences.nineKeyNumbers {
            if numberSymbolRail == nil {
                let rail = KeyboardNumberSymbolRail()
                rail.onSelect = { [weak self] symbol in
                    guard let self, self.usesNumberPad, self.panel == .keyboard else { return }
                    self.playFeedback()
                    if self.composesNumberPageInput(symbol) { self.apply(self.session.type(symbol)) }
                    else { self.insertSymbol(symbol) }
                }
                rail.onEdit = { [weak self] in
                    guard let self, self.panel == .keyboard, self.usesNumberPad else { return }
                    self.stopInteractions()
                    self.onOpenNumberSymbolSettings?()
                }
                numberSymbolRail = rail
                addSubview(rail)
            }
            numberSymbolRail?.present(preferences.numberSymbols)
            let values = [["1", "2", "3", "删除"],
                          ["4", "5", "6", "空格"],
                          ["7", "8", "9", "表情"],
                          ["ABC", "符号", "0", ".", "换行"]]
            for (r, values) in values.enumerated() {
                rows.append(values.map { value in
                    if value == "删除" { return deleteKey(weight: 1) }
                    if value == "表情" {
                        let item = symbol("face.smiling", label: String(localized: "表情"), weight: 1) { [weak self] in self?.toggleEmoji() }
                        item.0.accessibilityIdentifier = "vime.number.emoji"
                        return item
                    }
                    // Values are stable key IDs (also accessibility IDs); titles are localized.
                    let item = key(Self.numberPadTitle(value), utility: ["ABC", "符号", "空格", "换行"].contains(value)) { [weak self] in
                        guard let self else { return }
                        switch value {
                        case "ABC": self.page = .letters; self.rebuildKeys()
                        case "空格": self.apply(self.session.insertLiteral(" "))
                        case "符号": self.openSymbolPanel(mode: .symbols)
                        case "换行": self.apply(self.session.enter())
                        default:
                            let composes = self.composesNumberPageInput(value)
                            if composes { self.apply(self.session.type(value)) } else { self.insertSymbol(value) }
                        }
                    }
                    item.0.accessibilityIdentifier = "vime.number." + value
                    if value == "ABC" {
                        numberBackKey = item.0
                        if prefersKanaLayout { item.0.setTitle("かな", for: .normal) }
                    }
                    if r == 3 && value == "换行" {
                        returnKey = item.0; item.0.accessibilityIdentifier = "vime.key.return"
                    }
                    if value == "空格" {
                        spaceKey = item.0; item.0.accessibilityIdentifier = "vime.key.space"
                    }
                    return item
                })
            }
            applyKeySkins(); refresh(); setNeedsLayout(); return
        } else {
            let values = page == .numbers
                ? [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""], ["。", "、", "？", "！", "'", "ー", "・"]]
                : [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "$", "€", "£", "・"], ["「", "」", "『", "』", "…", "〜", "々"]]
            for (index, values) in values.enumerated() {
                var row = values.map { value in
                    let item = key(value) { [weak self] in
                        guard let self else { return }
                        if self.composesNumberPageInput(value) {
                            self.apply(self.session.type(value))
                        } else {
                            self.insertSymbol(value)
                        }
                    }
                    item.0.titleLabel?.font = .systemFont(ofSize: 21)
                    return item
                }
                if index == 2 {
                    row.insert(key(page == .numbers ? "#+=" : "123", utility: true, weight: 1.4) { [weak self] in
                        guard let self else { return }
                        self.page = self.page == .numbers ? .symbols : .numbers
                        self.rebuildKeys()
                    }, at: 0)
                    row.append(deleteKey(weight: 1.4))
                }
                rows.append(row)
            }
        }
        var bottom = [key(page == .letters ? "123" : prefersKanaLayout ? "かな" : "ABC", utility: true, weight: 1.25) { [weak self] in
            guard let self else { return }
            self.page = self.page == .letters ? .numbers : .letters
            self.rebuildKeys()
        }]
        let emoji = symbol("face.smiling", label: String(localized: "表情"), weight: 1) { [weak self] in self?.toggleEmoji() }
        emoji.0.accessibilityIdentifier = "vime.key.emoji"
        bottom.append(emoji)
        let comma = key(page == .letters ? "," : String(localized: "符号"), utility: page != .letters, weight: 1) { [weak self] in
            guard let self else { return }
            if self.page != .letters { self.openSymbolPanel(mode: .symbols); return }
            self.apply(self.session.insertLiteral(self.session.inputTraits.comma))
        }
        comma.0.accessibilityIdentifier = page == .letters ? "vime.key.comma" : "vime.key.symbols"
        comma.0.hint = page == .letters ? "°" : nil
        comma.0.alternateTitle = page == .letters ? session.inputTraits.period : nil
        comma.0.alternateAction = { [weak self] in
            guard let self else { return }
            self.apply(self.session.insertLiteral(self.session.inputTraits.period))
        }
        bottom.append(comma)
        let space = key("", weight: 1) { [weak self] in
            guard let self else { return }
            self.apply(self.session.space())
        }
        space.0.accessibilityLabel = String(localized: "空格，转换候选")
        space.0.accessibilityIdentifier = "vime.key.space"
        spaceKey = space.0
        bottom.append(space)
        let language = key("", weight: 1) { [weak self] in
            guard let self else { return }
            self.apply(self.session.toggleEnglish())
            self.shifted = false
            self.capsLocked = false
            self.rebuildKeys()
        }
        language.0.setImage(KeyboardGlyphs.language(active: session.inputTraits.language, other: session.inputTraits.alternateLanguage), for: .normal)
        languageKey = language.0
        language.0.accessibilityLabel = session.inputTraits.languageSwitchAccessibilityLabel
        language.0.accessibilityIdentifier = "vime.key.language"
        bottom.append(language)
        let enter = key(String(localized: "换行"), weight: 1.55) { [weak self] in
            guard let self else { return }
            self.apply(self.session.enter())
        }
        enter.0.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        enter.0.fillColor = KeyboardPalette.utility
        enter.0.setTitleColor(.label, for: .normal)
        enter.0.accessibilityIdentifier = "vime.key.return"
        returnKey = enter.0
        bottom.append(enter)
        rows.append(bottom)
        applyKeySkins()
        updateKeyLabels()
        refresh()
        setNeedsLayout()
    }

    func deleteKey(weight: CGFloat) -> (KeyboardKey, CGFloat) {
        let item = symbol("delete.left", label: "删除", weight: weight) { [weak self] in
            guard let self else { return }
            guard self.hasDeletableContent else { return }
            self.kanaToggle = nil
            self.apply(self.session.backspace())
        }
        item.0.accessibilityIdentifier = "vime.key.delete"
        item.0.repeats = true
        item.0.canRepeat = { [weak self] in self?.hasDeletableContent ?? false }
        return item
    }

    var hasDeletableContent: Bool {
        session.isComposing || (deletionAvailabilityProvider?() ?? true)
    }

    static let bracketPairs: [String: String] = [
        "(": ")", "（": "）", "[": "]", "［": "］", "{": "}", "｛": "｝",
        "「": "」", "『": "』", "【": "】", "〔": "〕", "〈": "〉", "《": "》",
        "〖": "〗", "〘": "〙", "〚": "〛", "⌈": "⌉", "⌊": "⌋", "⟨": "⟩"
    ]

    func insertSymbol(_ text: String) {
        guard preferences.autoPairBrackets, let closing = Self.bracketPairs[text] else {
            apply(session.insertLiteral(text)); return
        }
        let edits = session.confirmAll()
        session.invalidateLearningFeedback()
        session.reset()
        apply(edits + [.insertPair(opening: text, closing: closing)])
    }

    var returnTitle: String {
        switch returnKeyType {
        case .send: String(localized: "发送")
        case .search: String(localized: "搜索")
        case .go: String(localized: "前往")
        case .done: String(localized: "完成")
        case .next: String(localized: "下一项")
        case .join: String(localized: "加入")
        default: String(localized: "换行")
        }
    }

    func updateKeyLabels() {
        for button in letterKeys {
            if let value = button.title(for: .normal) {
                button.setTitle(value.uppercased(), for: .normal)
            }
        }
        let active = shifted
        shiftKey?.setImage(UIImage(systemName: capsLocked && session.inputTraits.isEnglish ? "capslock.fill" : active ? "shift.fill" : "shift"), for: .normal)
        shiftKey?.tintColor = KeyboardPalette.text
    }

    /// Shift acts on release, so a double tap is measured release to release
    /// and includes the second press. A tap after locking unlocks.
    static let capsLockInterval: TimeInterval = 0.45

    func shift(at now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        if capsLocked { capsLocked = false; shifted = false; lastShiftTap = 0 }
        else if now - lastShiftTap < Self.capsLockInterval { capsLocked = true; shifted = true; lastShiftTap = 0 }
        else { shifted.toggle(); lastShiftTap = now }
        updateKeyLabels()
    }

    static let letterHints: [String: String] = Dictionary(uniqueKeysWithValues: zip(
        Array("qwertyuiopasdfghjklzxcvbnm").map(String.init),
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "/", ":", ";", "(", ")", "~", "“", "”", "@", "·", "#", "`", "?", "!", "…"]
    ))
}
