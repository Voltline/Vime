import Foundation

/// Korean 2-beolsik (두벌식) input session conforming to `KeyboardInputSession`.
///
/// Keeps the active word underlined as marked text for word completion, stem + particle
/// expansion, and jamo-level typo correction. Commits on Space, punctuation, Return,
/// or candidate selection, and unmaps Korean lexicon/learning resources on language switch.
@MainActor
final class KoreanInputSession: KeyboardInputSession {
    static let completionLimit = 12
    static let suggestionLimit = 10

    private let lexicon: KoreanLexicon
    private let learning: KoreanPersonalLearningStore
    private let exclusions: LearningExclusionList
    private let exclusionsApply: () -> Bool
    private let blocklist: LearningExclusionList

    private let sessionID = UUID()
    private(set) var hostEpoch = 0
    private var english = false
    private var composer = HangulComposer()
    private var generation = 0
    private var suggestionsEnabled = true
    private var exclusionsActive: Bool
    private var previousWord: String?
    /// Tracks the immediately preceding recorded commit so immediate deletion
    /// (line delete, word delete, or backspacing the committed word) reverts learning.
    private var lastRecordedCommit: (word: String, previousWord: String?, remainingChars: Int)?
    /// Preserves `lastRecordedCommit` across `invalidateLearningFeedback()` until
    /// `didApplyEdits(_:)` observes whether the following edit is `.deleteToLineStart`.
    private var pendingDeletionUndo: (word: String, previousWord: String?, remainingChars: Int)?

    private struct CandidateItem: Equatable {
        let text: String
        let isCorrection: Bool
        let isLearned: Bool
    }

    private var items: [CandidateItem] = []
    private var presentations: [CandidatePresentation] = []
    private var suggestionItems: [CandidateItem] = []
    private var suggestionPresentations: [CandidatePresentation] = []
    private var inputStartedAt: TimeInterval?

    var onCandidatesChange: (() -> Void)?
    var onCommittedEdits: ((KeyboardCommitBatch) -> Void)?
    var leftContextProvider: (() -> String?)?
    var learningContextProvider: (() -> KeyboardLearningContext?)?

    init(
        lexicon: KoreanLexicon = .shared,
        learning: KoreanPersonalLearningStore = .shared,
        exclusions: LearningExclusionList = .shared,
        exclusionsApply: @escaping () -> Bool = { LearningExclusionPolicy.isActive() },
        blocklist: LearningExclusionList = PredictionBlocklist.korean
    ) {
        self.lexicon = lexicon
        self.learning = learning
        self.exclusions = exclusions
        self.exclusionsApply = exclusionsApply
        self.blocklist = blocklist
        self.exclusionsActive = exclusionsApply()
    }

    // MARK: - KeyboardInputSession State

    var inputTraits: KeyboardInputTraits {
        KeyboardInputTraits(
            language: english ? .english : .korean,
            modeLabel: "한",
            alternateLanguage: english ? .korean : .english,
            supportsPrimaryVariant: false,
            comma: ",",
            period: ".",
            compositionSpaceTitle: String(localized: "空格"),
            compositionReturnTitle: String(localized: "换行")
        )
    }

    var isComposing: Bool { !composer.isEmpty }
    var composition: String { composer.text }
    var raw: String { String(composer.jamos) }
    var activeSyllableState: HangulComposer.ActiveSyllable? { composer.activeState }

    var markedText: KeyboardPreedit? {
        guard isComposing else { return nil }
        return KeyboardPreedit(text: composer.text)
    }

    var candidatePresentations: [CandidatePresentation] { isComposing ? presentations : [] }
    var stripPresentations: [CandidatePresentation] { isComposing ? presentations : suggestionPresentations }
    var showsStrip: Bool { !stripPresentations.isEmpty }
    var candidatesAreCurrent: Bool { true }
    var selectedIndex: Int? { nil }
    var candidateResultReadyAt: TimeInterval? { nil }

    // MARK: - Commands

    func type(_ text: String) -> [KeyboardEdit] {
        clearSuggestions()
        lastRecordedCommit = nil
        if english {
            let edits = commitComposition(recordLearning: false)
            return edits + [.insert(text)]
        }
        guard !text.isEmpty else { return [] }
        inputStartedAt = KeyboardPerformance.start()
        if composer.input(string: text) {
            refreshCandidates()
            onCandidatesChange?()
            return []
        }
        // Non-jamo input (punctuation, digits, temporary ASCII): commit active word first.
        let committed = commitComposition(recordLearning: true)
        return committed + [.insert(text)]
    }

    func backspace() -> [KeyboardEdit] {
        clearSuggestions()
        if composer.backspace() {
            refreshCandidates()
            onCandidatesChange?()
            return []
        }
        noteDeletedBackward(count: 1)
        previousWord = nil
        return [.deleteBackward]
    }

    func noteDeletedBackward(count: Int) {
        guard count > 0, !english, !isComposing, var commit = lastRecordedCommit else { return }
        commit.remainingChars -= count
        if commit.remainingChars <= 0 {
            revertLastRecordedCommit()
        } else {
            lastRecordedCommit = commit
        }
    }

    func space() -> [KeyboardEdit] {
        clearSuggestions()
        if isComposing {
            let word = composer.flush()
            clearCandidates()
            recordWord(word, insertedLength: word.count + 1)
            updateNextWordSuggestions(after: word)
            onCandidatesChange?()
            return [.insert(word + " ")]
        }
        lastRecordedCommit = nil
        return [.insert(" ")]
    }

    func enter() -> [KeyboardEdit] {
        clearSuggestions()
        if isComposing {
            let word = composer.flush()
            clearCandidates()
            // After a newline the caret moves to the next line, so deleteToLineStart
            // on the new line must not revert the word committed on the previous line.
            recordWord(word, insertedLength: word.count, trackForUndo: false)
            previousWord = nil
            onCandidatesChange?()
            return [.insert(word), .returnKey]
        }
        lastRecordedCommit = nil
        pendingDeletionUndo = nil
        previousWord = nil
        return [.returnKey]
    }

    func confirm() -> [KeyboardEdit] { confirmAll() }

    func confirmAll() -> [KeyboardEdit] {
        commitComposition(recordLearning: true)
    }

    func dismissSuggestions() {
        clearSuggestions()
        onCandidatesChange?()
    }

    func insertLiteral(_ text: String) -> [KeyboardEdit] {
        let edits = commitComposition(recordLearning: true)
        clearSuggestions()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Keep previousWord on space so next-word suggestions remain valid if needed.
        } else {
            previousWord = nil
        }
        onCandidatesChange?()
        return edits + [.insert(text)]
    }

    func chooseCandidate(_ token: CandidateSelectionToken) -> [KeyboardEdit] {
        guard token.sessionID == sessionID, token.generation == generation else { return [] }
        switch token.kind {
        case .composition:
            guard isComposing, items.indices.contains(token.index) else { return [] }
            let chosen = items[token.index].text
            composer.clear()
            clearCandidates()
            recordWord(chosen, insertedLength: chosen.count + 1)
            updateNextWordSuggestions(after: chosen)
            onCandidatesChange?()
            return [.insert(chosen + " ")]

        case .suggestion:
            guard !isComposing, suggestionItems.indices.contains(token.index) else { return [] }
            let chosen = suggestionItems[token.index].text
            clearSuggestions()
            recordWord(chosen, insertedLength: chosen.count + 1)
            updateNextWordSuggestions(after: chosen)
            onCandidatesChange?()
            return [.insert(chosen + " ")]
        }
    }

    func activateEnglish() -> [KeyboardEdit] {
        guard !english else { return [] }
        let edits = confirmAll()
        clearSuggestions()
        english = true
        hostEpoch += 1
        onCandidatesChange?()
        return edits
    }

    func toggleEnglish() -> [KeyboardEdit] {
        let edits = confirmAll()
        clearSuggestions()
        english.toggle()
        hostEpoch += 1
        onCandidatesChange?()
        return edits
    }

    func togglePrimaryVariant() -> [KeyboardEdit] { [] }

    func updateIntelligence(ranking: CandidateRankingMode, suggestionsEnabled: Bool) {
        self.suggestionsEnabled = suggestionsEnabled
        if !suggestionsEnabled {
            clearSuggestions()
            onCandidatesChange?()
        }
    }

    func forgettableCandidate(_ token: CandidateSelectionToken) -> String? {
        guard token.sessionID == sessionID, token.generation == generation else { return nil }
        switch token.kind {
        case .composition:
            guard items.indices.contains(token.index), items[token.index].isLearned else { return nil }
            return items[token.index].text
        case .suggestion:
            guard suggestionItems.indices.contains(token.index), suggestionItems[token.index].isLearned else { return nil }
            return suggestionItems[token.index].text
        }
    }

    func forgetCandidate(_ token: CandidateSelectionToken) {
        guard let word = forgettableCandidate(token) else { return }
        learning.forget(word: word)
        if isComposing {
            refreshCandidates()
        } else if let previousWord {
            updateNextWordSuggestions(after: previousWord)
        }
        onCandidatesChange?()
    }

    func reset(preservingContext: Bool) {
        if !preservingContext {
            hostEpoch += 1
            previousWord = nil
            lastRecordedCommit = nil
        }
        composer.clear()
        clearCandidates()
        clearSuggestions()
        exclusionsActive = exclusionsApply()
        onCandidatesChange?()
    }

    func handleMemoryPressure() {
        releaseInactiveResources()
    }

    func releaseInactiveResources() {
        lexicon.release()
        learning.release()
    }

    func releaseLanguageModels() {
        lexicon.release()
        learning.release()
    }

    func didApplyEdits(_ edits: [KeyboardEdit]) {
        if edits.contains(.deleteToLineStart) {
            revertLastRecordedCommit()
            if let pending = pendingDeletionUndo {
                pendingDeletionUndo = nil
                learning.unrecord(word: pending.word, previousWord: pending.previousWord)
                previousWord = pending.previousWord
            }
        } else {
            pendingDeletionUndo = nil
        }
    }

    func invalidateLearningFeedback() {
        if let commit = lastRecordedCommit {
            pendingDeletionUndo = commit
            lastRecordedCommit = nil
        }
    }

    func takeInputTiming() -> TimeInterval? {
        defer { inputStartedAt = nil }
        return inputStartedAt
    }

    // MARK: - Internal helpers

    private func commitComposition(recordLearning: Bool) -> [KeyboardEdit] {
        guard isComposing else { return [] }
        let word = composer.flush()
        clearCandidates()
        if recordLearning { recordWord(word, insertedLength: word.count) }
        onCandidatesChange?()
        return [.insert(word)]
    }

    private func recordWord(_ word: String, insertedLength: Int, trackForUndo: Bool = true) {
        let prev = previousWord
        let recorded = learning.record(
            word: word,
            previousWord: prev,
            exclusionsActive: exclusionsActive,
            exclusionList: exclusions,
            blocklist: blocklist
        )
        if recorded && trackForUndo {
            lastRecordedCommit = (word: word, previousWord: prev, remainingChars: max(1, insertedLength))
        } else {
            lastRecordedCommit = nil
        }
        previousWord = word
    }

    private func revertLastRecordedCommit() {
        guard let commit = lastRecordedCommit else { return }
        lastRecordedCommit = nil
        learning.unrecord(word: commit.word, previousWord: commit.previousWord)
        previousWord = commit.previousWord
    }

    private func clearCandidates() {
        generation += 1
        items = []
        presentations = []
    }

    private func clearSuggestions() {
        generation += 1
        suggestionItems = []
        suggestionPresentations = []
    }

    private func refreshCandidates() {
        generation += 1
        let composed = composer.text
        guard !composed.isEmpty else {
            items = []
            presentations = []
            return
        }

        let jamos = composer.jamos
        let jamoPrefix = String(jamos)
        var built: [CandidateItem] = []
        var seen: Set<String> = []

        func append(_ text: String, isCorrection: Bool = false, isLearned: Bool = false) {
            guard !text.isEmpty, !blocklist.matches(text), seen.insert(text).inserted else { return }
            built.append(CandidateItem(text: text, isCorrection: isCorrection, isLearned: isLearned))
        }

        // 1. User's personal learned words matching the jamo prefix:
        //    - In-lexicon words (count >= 1) and OOV words used at least twice (count >= 2) rank first.
        //    - Single-use OOV words (possible typos) stay behind lexicon completions.
        let learnedMatches = learning.matchingCompletions(jamoPrefix: jamoPrefix, limit: 6, blocklist: blocklist)
        var tentativeOOV: [KoreanPersonalLearningStore.WordRecord] = []
        for rec in learnedMatches {
            let inLexicon = lexicon.exactMatch(surface: rec.surface) != nil
            if inLexicon || rec.count >= 2 {
                append(rec.surface, isLearned: true)
            } else {
                tentativeOOV.append(rec)
            }
        }

        // 2. If the current composed text itself is a valid lexicon word, always offer it
        //    right after promoted learned words and before other completions.
        if let exact = lexicon.exactMatch(jamo: jamoPrefix), exact.surface == composed {
            append(exact.surface, isLearned: learning.isLearned(exact.surface))
        }

        // 3. Jamo-level error corrections (only when input is not already a valid word/prefix).
        let corrections = KoreanErrorCorrector.corrections(
            for: composed,
            jamos: jamos,
            lexicon: lexicon,
            blocklist: blocklist,
            limit: 3
        )
        for corr in corrections {
            append(corr.surface, isCorrection: true, isLearned: learning.isLearned(corr.surface))
        }

        // 4. Lexicon prefix completions (global top-N across the full matching prefix range).
        let lexMatches = lexicon.completions(forJamoPrefix: jamoPrefix, limit: Self.completionLimit)
        for entry in lexMatches {
            if entry.surface != composed {
                append(entry.surface, isLearned: learning.isLearned(entry.surface))
            }
            if built.count >= Self.completionLimit { break }
        }

        // 5. Stem + particle (조사) completions (e.g., 학교 -> 학교에, 학교에서).
        if built.count < Self.completionLimit {
            let particleForms = lexicon.particleCompletions(
                forComposed: composed,
                jamoPrefix: jamoPrefix,
                limit: Self.completionLimit - built.count
            )
            for form in particleForms {
                append(form, isLearned: learning.isLearned(form))
            }
        }

        // 6. Single-use OOV learned words trail behind lexicon completions.
        if built.count < Self.completionLimit {
            for rec in tentativeOOV {
                append(rec.surface, isLearned: true)
                if built.count >= Self.completionLimit { break }
            }
        }

        items = Array(built.prefix(Self.completionLimit))
        presentations = items.enumerated().map { index, item in
            CandidatePresentation(
                text: item.text,
                source: item.isCorrection ? .typoCorrection : (item.isLearned ? .userHistory : .prediction),
                consumedInputCount: composed.count,
                correction: nil,
                selectionToken: CandidateSelectionToken(
                    sessionID: sessionID,
                    generation: generation,
                    index: index,
                    kind: .composition
                )
            )
        }
    }

    private func updateNextWordSuggestions(after word: String) {
        guard suggestionsEnabled, !english, !word.isEmpty else {
            suggestionItems = []
            suggestionPresentations = []
            return
        }
        generation += 1
        var built: [CandidateItem] = []
        var seen: Set<String> = [word]

        func append(_ text: String, isLearned: Bool) {
            guard !text.isEmpty, !blocklist.matches(text), seen.insert(text).inserted else { return }
            built.append(CandidateItem(text: text, isCorrection: false, isLearned: isLearned))
        }

        for rec in learning.nextWords(after: word, limit: 4, blocklist: blocklist) {
            append(rec.next, isLearned: true)
        }
        for next in lexicon.nextWords(after: word, limit: Self.suggestionLimit) {
            append(next.surface, isLearned: learning.isLearned(next.surface))
            if built.count >= Self.suggestionLimit { break }
        }

        suggestionItems = Array(built.prefix(Self.suggestionLimit))
        suggestionPresentations = suggestionItems.enumerated().map { index, item in
            CandidatePresentation(
                text: item.text,
                source: item.isLearned ? .userHistory : .contextPrediction,
                consumedInputCount: 0,
                correction: nil,
                selectionToken: CandidateSelectionToken(
                    sessionID: sessionID,
                    generation: generation,
                    index: index,
                    kind: .suggestion
                )
            )
        }
    }
}
