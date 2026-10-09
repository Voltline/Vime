import XCTest
import UIKit

@MainActor
final class KeyboardInputBoundaryTests: XCTestCase {
    func testNativeByteSelectionAndHostCaretUpdates() throws {
        let text = "中😀wen"
        let preedit = try XCTUnwrap(KeyboardPreedit.fromUTF8(text, selectedRange: NSRange(location: 3, length: 4)))
        XCTAssertEqual(preedit.selectedRange, NSRange(location: 1, length: 2))
        XCTAssertNil(KeyboardPreedit.fromUTF8(text, selectedRange: NSRange(location: 1, length: 0)))
        XCTAssertNil(KeyboardPreedit(text: text, selectedRange: NSRange(location: 2, length: 0)))
        XCTAssertNil(KeyboardPreedit.fromUTF8(text, selectedRange: NSRange(location: NSNotFound, length: 1)))
        XCTAssertEqual(KeyboardPreedit(text: text).selectedRange, NSRange(location: 6, length: 0))
        var selections: [NSRange] = []
        var inserted: [String] = []
        let host = KeyboardHostConnection(setMarkedText: { _, range in selections.append(range) },
            unmarkText: {}, insertText: { inserted.append($0) }, deleteBackward: {})
        host.updatePreedit(preedit)
        host.updatePreedit(preedit)
        host.updatePreedit(KeyboardPreedit(text: text))
        XCTAssertEqual(selections, [NSRange(location: 1, length: 2), NSRange(location: 6, length: 0)],
                       "Same text with a new caret must reach the host; identical state is deduplicated")
        host.apply([.insert("中文")])
        XCTAssertNil(host.markedText)
        XCTAssertEqual(inserted, ["中文"])
    }

    func testCandidateTokensRejectReorderedListsAndOtherSessions() throws {
        let session = KeyboardSession()
        _ = session.type("nihongo")
        let oldToken = try XCTUnwrap(session.candidatePresentations.first?.selectionToken)
        let revision = session.revision
        session.acceptCandidateUpdate(Array(session.candidateSnapshots.reversed()), revision: revision, supplementary: true)
        XCTAssertEqual(session.revision, revision)
        XCTAssertTrue(session.chooseCandidate(oldToken).isEmpty, "Supplementary reranking must invalidate old UI identities")
        let currentToken = try XCTUnwrap(session.candidatePresentations.first?.selectionToken)
        let other = KeyboardSession()
        _ = other.type("nihongo")
        XCTAssertTrue(other.chooseCandidate(currentToken).isEmpty)
        let text = try XCTUnwrap(session.candidates.first)
        XCTAssertEqual(session.chooseCandidate(currentToken), [.insert(text)])
        session.reset(); _ = session.type("nihongo")
        XCTAssertTrue(session.chooseCandidate(currentToken).isEmpty)
    }

    func testIndependentBackendPresentationAndPanelReuse() throws {
        let session = BoundarySession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        keyboard.layoutIfNeeded()
        var preedit: KeyboardPreedit?
        keyboard.onPreeditChange = { preedit = $0 }
        session.onCandidatesChange?()
        XCTAssertEqual(preedit?.selectedRange, NSRange(location: 1, length: 3))
        XCTAssertEqual(try button("vime.key.language", in: keyboard).accessibilityValue, "中文")
        XCTAssertEqual(try button("vime.key.language", in: keyboard).accessibilityLabel, "中文英文切换")
        XCTAssertFalse(descendants(keyboard).contains { $0.accessibilityIdentifier == "vime.key.prolonged" })
        XCTAssertEqual(try button("vime.key.return", in: keyboard).title(for: .normal), "确认")
        try button("vime.candidates.expand", in: keyboard).sendActions(for: .touchUpInside)
        keyboard.layoutIfNeeded()
        let label = "候选词：中文，zhōng wén"
        let panelButton = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? UIButton }.first {
            $0.accessibilityLabel == label && $0.superview is UIScrollView
        })
        session.onCandidatesChange?()
        XCTAssertTrue(descendants(keyboard).contains { $0 === panelButton }, "Candidate refresh must reuse panel buttons")
        var edits: [KeyboardEdit] = []
        keyboard.onEdit = { edits += $0 }
        panelButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(session.chosenToken?.index, 42, "Native selection identity is not the displayed button's zero-based position")
        XCTAssertEqual(edits, [.insert("中文")])
        XCTAssertNil(preedit)
    }

    func testAsyncCommitsStayOrderedAndRejectOldHostEpoch() {
        let session = BoundarySession()
        let keyboard = KeyboardView(frame: .zero, session: session)
        var edits: [KeyboardEdit] = []
        keyboard.onEdit = { edits += $0 }
        session.onCommittedEdits?(KeyboardCommitBatch(hostEpoch: session.hostEpoch, edits: [.insert("一")]))
        session.onCandidatesChange?()
        session.onCommittedEdits?(KeyboardCommitBatch(hostEpoch: session.hostEpoch, edits: [.insert("二")]))
        let previousEpoch = session.hostEpoch
        keyboard.resetComposition()
        session.onCommittedEdits?(KeyboardCommitBatch(hostEpoch: previousEpoch, edits: [.insert("旧宿主")]))
        session.onCommittedEdits?(KeyboardCommitBatch(hostEpoch: session.hostEpoch, edits: [.insert("三")]))
        XCTAssertEqual(edits, [.insert("一"), .insert("二"), .insert("三")])
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try XCTUnwrap(descendants(view).first { $0.accessibilityIdentifier == id } as? UIButton)
    }
}

/// Tests only: proves that UI has no dependency on azooKey state or kana modes.
@MainActor
private final class BoundarySession: KeyboardInputSession {
    var inputTraits = KeyboardInputTraits(language: .chinese, modeLabel: "拼", comma: "，", period: "。")
    var hostEpoch = 0
    var markedText = KeyboardPreedit(text: "中wen", selectedRange: NSRange(location: 1, length: 3))
    var isComposing: Bool { markedText != nil }
    var composition: String { markedText?.text ?? "" }
    let token = CandidateSelectionToken(sessionID: UUID(), generation: 0, index: 42, kind: .composition)
    var candidatePresentations: [CandidatePresentation] {
        isComposing ? [CandidatePresentation(text: "中文", source: .conversion, consumedInputCount: 8,
            correction: nil, selectionToken: token, detailAnnotation: "zhōng wén")] : []
    }
    var stripPresentations: [CandidatePresentation] { candidatePresentations }
    var showsStrip: Bool { isComposing }
    var candidatesAreCurrent = true
    var selectedIndex: Int? = nil
    var candidateResultReadyAt: TimeInterval? = nil
    var onCandidatesChange: (() -> Void)?
    var onCommittedEdits: ((KeyboardCommitBatch) -> Void)?
    var leftContextProvider: (() -> String?)?
    var learningContextProvider: (() -> KeyboardLearningContext?)?
    var chosenToken: CandidateSelectionToken?
    func chooseCandidate(_ token: CandidateSelectionToken) -> [KeyboardEdit] {
        guard isComposing, token == self.token else { return [] }
        chosenToken = token; markedText = nil
        return [.insert("中文")]
    }
    func type(_ text: String) -> [KeyboardEdit] { [] }
    func backspace() -> [KeyboardEdit] { [] }
    func space() -> [KeyboardEdit] { [] }
    func enter() -> [KeyboardEdit] { [] }
    func confirm() -> [KeyboardEdit] { [] }
    func confirmAll() -> [KeyboardEdit] { [] }
    func insertLiteral(_ text: String) -> [KeyboardEdit] { [.insert(text)] }
    func activateEnglish() -> [KeyboardEdit] { [] }
    func toggleEnglish() -> [KeyboardEdit] { [] }
    func togglePrimaryVariant() -> [KeyboardEdit] { [] }
    func updateIntelligence(ranking: CandidateRankingMode, suggestionsEnabled: Bool) {}
    func reset(preservingContext: Bool) { if !preservingContext { hostEpoch += 1 }; markedText = nil }
    func didApplyEdits(_ edits: [KeyboardEdit]) {}
    func invalidateLearningFeedback() {}
    func takeInputTiming() -> TimeInterval? { nil }
}
