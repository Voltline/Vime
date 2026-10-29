import UIKit

// Candidate strip, expanded panel, conversion range and quick candidates.
extension KeyboardView {
    func layoutCandidateStrip() {
        let height = candidateScroll.bounds.height
        var x: CGFloat = 0
        for button in stripButtons {
            button.frame = CGRect(x: x, y: 0, width: button.presentationWidth, height: height)
            button.layoutIfNeeded()
            x = button.frame.maxX + 2
        }
        let size = CGSize(width: max(0, x - 2), height: height)
        candidateRow.frame = CGRect(origin: .zero, size: size)
        candidateScroll.contentSize = size
    }

    func candidateButton(_ presentation: CandidatePresentation, index: Int) -> KeyboardCandidateButton {
        let button = KeyboardCandidateButton(frame: .zero)
        presentCandidate(button, presentation: presentation, index: index)
        button.addTarget(self, action: #selector(selectCandidate(_:)), for: .touchUpInside)
        return button
    }

    func presentCandidate(_ button: KeyboardCandidateButton, presentation: CandidatePresentation, index: Int) {
        let configurationStartedAt = KeyboardPerformance.start()
        defer { KeyboardPerformance.record(.candidateButtonConfiguration, since: configurationStartedAt) }
        button.present(presentation, index: index, highlighted: session.isComposing && index == (session.selectedIndex ?? 0))
    }

    @objc func selectCandidate(_ sender: UIButton) {
        guard let token = (sender as? KeyboardCandidateButton)?.takeSelectionToken() else { return }
        playFeedback()
        apply(session.chooseCandidate(token))
    }

    func rebuildCandidatePanel() {
        let values = session.candidatePage(offset: 0, limit: panelLimit)
        while panelCandidates.count > values.count {
            let button = panelCandidates.removeLast()
            button.removeFromSuperview(); sparePanelButtons.append(button)
        }
        while panelCandidates.count < values.count {
            let index = panelCandidates.count
            let button = sparePanelButtons.popLast() ?? candidateButton(values[index], index: index)
            button.backgroundColor = .clear
            button.layer.cornerRadius = 6
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            panelScroll.addSubview(button)
            panelCandidates.append(button)
        }
        for (index, button) in panelCandidates.enumerated() {
            presentCandidate(button, presentation: values[index], index: index)
            button.isUserInteractionEnabled = session.candidatesAreCurrent && button.selectionToken != nil
        }
    }

    func quickCandidateItems() -> [KeyboardQuickCandidate] {
        if emojiSearchActive && panel == .keyboard { return emojiSearchItems() }
        if panel == .keyboard, !session.isComposing, !session.inputTraits.isEnglish,
           let selection = selectedTextProvider?(), KeyboardReconversion.reading(for: selection) != nil {
            return [.init(title: String(localized: "重新转换「\(selection)」"), action: .reconvert(selection))]
        }
        guard page == .numbers else { return [] }
        // A word being converted keeps its full candidate strip. Pure numeric
        // input gets shortcuts immediately, including when digits are marked.
        let mark = session.markedText?.text ?? ""
        guard mark.isEmpty || mark.allSatisfy({ "0123456789０１２３４５６７８９.．+-−－＋*/×÷＊／()（）%％".contains($0) }) else { return [] }
        var items: [KeyboardQuickCandidate] = []
        if onReplaceText != nil, let anchor = learningContextProvider?(), !anchor.hasSelection,
           let before = anchor.before, let calculation = KeyboardCalculation.trailing(in: before + mark),
           calculation.expression.hasSuffix(mark), calculation.expression.count >= mark.count {
            let suffix = String(calculation.expression.dropLast(mark.count))
            for text in [calculation.result, calculation.equation] {
                let replacement = KeyboardTextReplacement(anchor: anchor, markedText: session.markedText?.text,
                    committedSuffix: suffix, text: text)
                items.append(.init(title: text, action: .replacement(replacement)))
            }
        }
        items += KeyboardCalculation.symbols.map { .init(title: $0, action: .symbol($0)) }
        return items
    }

    func selectQuickCandidate(_ item: KeyboardQuickCandidate) {
        guard quickCandidateItems().contains(item) else { refresh(); return }
        playFeedback()
        switch item.action {
        case .symbol(let text):
            insertSymbol(text)
        case .emoji(let text):
            // Inserting over the marked reading replaces it, as a candidate does.
            preferences.recordEmoji(text)
            emojiSearchActive = false
            session.invalidateLearningFeedback()
            session.reset(preservingContext: true)
            apply([.insert(text)])
        case .prompt:
            break
        case .reconvert(let selection):
            // Marked text replaces the host's selection.
            guard selectedTextProvider?() == selection, let reading = KeyboardReconversion.reading(for: selection) else { refresh(); return }
            apply(session.type(reading))
        case .replacement(let replacement):
            guard learningContextProvider?() == replacement.anchor,
                  session.markedText?.text == replacement.markedText,
                  onReplaceText?(replacement) == true else { refresh(); return }
            session.invalidateLearningFeedback()
            session.reset()
            if panel == .candidates { panel = .keyboard }
            refresh()
        }
    }

    @objc func shortenConversion() {
        panelLimit = 40
        session.adjustConversionRange(by: -1)
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
    }
    @objc func lengthenConversion() {
        panelLimit = 40
        session.adjustConversionRange(by: 1)
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
    }
    @objc func wholeConversion() {
        panelLimit = 40
        session.resetConversionRange()
        refresh()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === panelScroll, panel == .candidates, panelLimit < session.candidateCount,
              session.candidatesAreCurrent, scrollView.contentSize.height > scrollView.bounds.height,
              scrollView.contentOffset.y + scrollView.bounds.height >= scrollView.contentSize.height - 90 else { return }
        panelLimit += 40
        rebuildCandidatePanel()
        setNeedsLayout()
    }
    @objc func toggleExpanded() {
        panelLimit = 40
        panel = panel == .candidates ? .keyboard : .candidates
        panelScroll.setContentOffset(.zero, animated: false)
        refresh()
    }
}
