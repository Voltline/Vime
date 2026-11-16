import XCTest
import UIKit

/// A fixed candidate list, so the expanded panel can be checked and captured
/// with long Chinese and Japanese sentences without a conversion engine.
@MainActor
private final class FixedCandidateSession: KeyboardInputSession {
    let id = UUID()
    let inputTraits: KeyboardInputTraits
    let candidatePresentations: [CandidatePresentation]
    init(language: KeyboardInputLanguage, candidates: [String]) {
        inputTraits = KeyboardInputTraits(language: language, modeLabel: language.glyph)
        let id = id
        candidatePresentations = candidates.enumerated().map { index, text in
            var value = CandidatePresentation(text: text, source: .conversion, consumedInputCount: 1, correction: nil)
            value.selectionToken = CandidateSelectionToken(sessionID: id, generation: 1, index: index, kind: .composition)
            return value
        }
    }
    let hostEpoch = 0
    var isComposing: Bool { true }
    var composition: String { "reading" }
    var markedText: KeyboardPreedit? { KeyboardPreedit(text: composition) }
    var stripPresentations: [CandidatePresentation] { candidatePresentations }
    var showsStrip: Bool { true }
    var candidatesAreCurrent: Bool { true }
    var selectedIndex: Int? { 0 }
    var candidateResultReadyAt: TimeInterval? { nil }
    var onCandidatesChange: (() -> Void)?
    var onCommittedEdits: ((KeyboardCommitBatch) -> Void)?
    var leftContextProvider: (() -> String?)?
    var learningContextProvider: (() -> KeyboardLearningContext?)?
    func type(_ text: String) -> [KeyboardEdit] { [] }
    func backspace() -> [KeyboardEdit] { [] }
    func space() -> [KeyboardEdit] { [] }
    func enter() -> [KeyboardEdit] { [] }
    func confirm() -> [KeyboardEdit] { [] }
    func confirmAll() -> [KeyboardEdit] { [] }
    func dismissSuggestions() {}
    func insertLiteral(_ text: String) -> [KeyboardEdit] { [] }
    func chooseCandidate(_ token: CandidateSelectionToken) -> [KeyboardEdit] { [] }
    func activateEnglish() -> [KeyboardEdit] { [] }
    func toggleEnglish() -> [KeyboardEdit] { [] }
    func togglePrimaryVariant() -> [KeyboardEdit] { [] }
    func updateIntelligence(ranking: CandidateRankingMode, suggestionsEnabled: Bool) {}
    func reset(preservingContext: Bool) {}
    func didApplyEdits(_ edits: [KeyboardEdit]) {}
    func invalidateLearningFeedback() {}
    func takeInputTiming() -> TimeInterval? { nil }
}

@MainActor
final class KeyboardCandidatePanelTests: XCTestCase {
    static let chinese = [
        "我们明天下午三点在学校门口见面然后一起去图书馆复习功课",
        "我们明天下午三点在学校门口见面",
        "我们", "明天", "我们明天", "我", "们", "我们明天下午",
        "如果你周末有空的话我们可以一起去城郊的湖边露营顺便带上相机拍一些日落和星空的照片回来做纪念",
        "我们明", "我门", "沃们", "下午", "三点", "学校门口"]
    static let japanese = [
        "今日はとても良い天気なので近くの公園まで散歩に行きませんか",
        "今日はとても良い天気なので",
        "今日", "京", "きょう", "キョウ", "今日は", "強",
        "明日の会議の資料は昨日の夜に共有フォルダへアップロードしておいたので時間がある時に確認してください",
        "教", "興", "経", "今日はとても", "天気"]

    private var window: UIWindow?
    private var suites: [String] = []

    override func tearDown() {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private func expandedKeyboard(_ session: FixedCandidateSession, width: CGFloat, pad: Bool = false,
                                  style: UIUserInterfaceStyle = .light) throws -> KeyboardView {
        let suite = "VimeCandidatePanelTests." + UUID().uuidString
        suites.append(suite)
        let preferences = KeyboardPreferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.phraseSuggestions = false
        let keyboard = KeyboardView(frame: .zero, session: session, preferences: preferences)
        if pad { keyboard.pad = true; keyboard.showsFooter = true; keyboard.needsGlobe = true }
        keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.preferredHeight(for: width))
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: max(width, 400), height: 900)))
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = style
        let input = UIInputView(frame: keyboard.frame, inputViewStyle: .keyboard)
        input.addSubview(keyboard)
        window.rootViewController?.view.addSubview(input)
        window.isHidden = false
        self.window = window
        keyboard.overrideUserInterfaceStyle = style
        session.onCandidatesChange?()
        keyboard.layoutIfNeeded()
        let expand = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates.expand" } as? UIButton)
        expand.sendActions(for: .touchUpInside)
        keyboard.layoutIfNeeded()
        return keyboard
    }

    private func cells(_ keyboard: KeyboardView) throws -> (panel: UIScrollView, cells: [KeyboardCandidateButton]) {
        let panel = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates.panel" } as? UIScrollView)
        XCTAssertFalse(panel.isHidden)
        return (panel, panel.subviews.compactMap { $0 as? KeyboardCandidateButton }.filter { !$0.isHidden })
    }

    private func capture(_ keyboard: KeyboardView, name: String) throws {
        keyboard.layoutIfNeeded()
        descendants(keyboard).forEach { $0.layoutIfNeeded() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: keyboard.bounds, format: format).image { context in
            (keyboard.traitCollection.userInterfaceStyle == .dark ? UIColor.black : UIColor.white).setFill()
            context.fill(keyboard.bounds)
            keyboard.superview?.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VimeCandidatePanel", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
    }

    /// iPhone portrait/landscape, docked iPad and the floating iPad keyboard.
    private let widths: [(name: String, width: CGFloat, pad: Bool)] = [
        ("phone", 390, false), ("phone-landscape", 844, false), ("pad", 1032, true), ("pad-floating", 320, true)]

    func testLongSentencesStayReadableAndShortWordsStayPacked() throws {
        for (language, candidates) in [(KeyboardInputLanguage.chinese, Self.chinese), (.japanese, Self.japanese)] {
            for size in widths {
                let session = FixedCandidateSession(language: language, candidates: candidates)
                let keyboard = try expandedKeyboard(session, width: size.width, pad: size.pad)
                let (panel, cells) = try cells(keyboard)
                let context = "\(language) \(size.name)"
                XCTAssertEqual(cells.map { $0.title(for: .normal) }, candidates, context)
                let left = cells.map(\.frame.minX).min()!, right = cells.map(\.frame.maxX).max()!
                let rowWidth = right - left
                for (index, cell) in cells.enumerated() {
                    let text = candidates[index]
                    XCTAssertTrue(cell.accessibilityLabel?.contains(text) == true,
                        "VoiceOver reads the whole candidate: \(context)")
                    let needed = cell.presentationWidth
                    XCTAssertGreaterThanOrEqual(cell.frame.width + 0.001, min(needed, rowWidth),
                        "\(text) is cut although the row has room: \(context)")
                    if needed > rowWidth {
                        XCTAssertEqual(cell.frame.width, rowWidth, accuracy: 0.001, context)
                        XCTAssertEqual(cell.titleLines, 2, "A sentence wider than the row wraps: \(context)")
                        XCTAssertEqual(cell.titleLabel?.numberOfLines, 2)
                        XCTAssertEqual(cell.titleLabel?.lineBreakMode, .byTruncatingMiddle,
                            "Beyond two lines the sentence keeps its start and end")
                        XCTAssertGreaterThanOrEqual(cell.titleLabel?.frame.height ?? 0,
                            2 * floor(cell.titleLabel?.font.lineHeight ?? 0), context)
                    } else {
                        XCTAssertEqual(cell.titleLines, 1, context)
                    }
                    for other in cells[..<index] {
                        XCTAssertFalse(cell.frame.intersects(other.frame), "Candidates overlap: \(context)")
                    }
                }
                // Several one- and two-character words share a row.
                let wordRow = cells[2].frame.minY
                XCTAssertGreaterThanOrEqual(cells.filter { $0.frame.minY == wordRow }.count, size.width < 400 ? 2 : 4,
                    "Short words stay packed: \(context)")
                XCTAssertEqual(panel.contentSize.height, cells.map(\.frame.maxY).max()! + 5, accuracy: 0.001)
                try capture(keyboard, name: "\(language)-\(size.name)")
                keyboard.stopInteractions()
                window?.isHidden = true
            }
        }
    }

    func testDarkModeKeepsTheLayout() throws {
        let light = try cells(try expandedKeyboard(FixedCandidateSession(language: .chinese, candidates: Self.chinese), width: 390))
            .cells.map(\.frame)
        window?.isHidden = true
        let keyboard = try expandedKeyboard(FixedCandidateSession(language: .chinese, candidates: Self.chinese),
            width: 390, style: .dark)
        XCTAssertEqual(try cells(keyboard).cells.map(\.frame), light)
        try capture(keyboard, name: "chinese-phone-dark")
        keyboard.stopInteractions()
    }
}
