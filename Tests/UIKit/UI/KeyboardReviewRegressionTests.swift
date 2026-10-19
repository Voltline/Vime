import XCTest
import UIKit
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardReviewRegressionTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func preferences() throws -> KeyboardPreferences {
        let suite = "vime.review.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return KeyboardPreferences(defaults: defaults)
    }

    func testAppOffOnWithoutIntermediateKeyboardRefreshRetriesOnce() throws {
        let prefs = try preferences()
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 375, height: 300), session: session, preferences: prefs)
        let gate = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        let wasSuspended = JapaneseCandidateWorker.isLanguageModelSuspendedForMemoryPressure
        defer { if wasSuspended { gate.handleMemoryPressure() } else { gate.allowLanguageModel() } }
        keyboard.handleMemoryPressure()
        XCTAssertTrue(session.neuralModeSuspendedForMemoryPressure)
        // The extension observes only the final setting after returning from App.
        prefs.candidateRanking = .engine
        prefs.candidateRanking = .languageModel
        keyboard.reloadPreferences()
        XCTAssertFalse(session.neuralModeSuspendedForMemoryPressure)
        keyboard.handleMemoryPressure()
        keyboard.reloadPreferences()
        XCTAssertTrue(session.neuralModeSuspendedForMemoryPressure, "A consumed retry must not override a later warning")
        let replacement = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        _ = KeyboardView(frame: .zero, session: replacement, preferences: prefs)
        XCTAssertTrue(replacement.neuralModeSuspendedForMemoryPressure, "Replacing a view must not replay the same request")
        // A direct action also works when the selected mode has never changed.
        prefs.requestNeuralRetry()
        keyboard.reloadPreferences()
        XCTAssertFalse(session.neuralModeSuspendedForMemoryPressure)
    }

    func testRetryDoesNotReorderVisibleCandidatesOrConsumeSharedRequestInPreview() throws {
        let prefs = try preferences()
        prefs.phraseSuggestions = false
        let session = KeyboardSession()
        _ = session.type("hashi")
        _ = session.space()
        let list = session.candidatePresentations, selection = session.selectedIndex, raw = session.raw
        let gate = JapaneseCandidateWorker(memoryDirectoryURL: isolatedLearningDirectory())
        let wasSuspended = JapaneseCandidateWorker.isLanguageModelSuspendedForMemoryPressure
        defer { if wasSuspended { gate.handleMemoryPressure() } else { gate.allowLanguageModel() } }
        gate.handleMemoryPressure()
        prefs.requestNeuralRetry()
        _ = KeyboardView(frame: .zero, session: session, preferences: prefs)
        XCTAssertTrue(JapaneseCandidateWorker.isLanguageModelSuspendedForMemoryPressure)
        XCTAssertEqual(session.candidatePresentations, list)
        XCTAssertEqual(session.selectedIndex, selection)
        XCTAssertEqual(session.raw, raw)
        let live = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        _ = KeyboardView(frame: .zero, session: live, preferences: prefs)
        XCTAssertFalse(live.neuralModeSuspendedForMemoryPressure, "A preview must leave the action available to a live worker")
    }

    func testToolbarHas44PointTargetsAndBlankHeaderNeverTypes() throws {
        for (width, compact) in [(CGFloat(320), false), (375, false), (440, false), (680, true)] {
            let keyboard = KeyboardView(frame: .zero, session: KeyboardSession(), preferences: try preferences())
            keyboard.compact = compact
            keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.preferredHeight(for: width))
            keyboard.layoutIfNeeded()
            let surface = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardTouchSurface }.first)
            let toolbar = descendants(keyboard).compactMap { $0 as? UIButton }.filter {
                ["vime.brand.settings", "vime.candidates.expand"].contains($0.accessibilityIdentifier ?? "") && !$0.isHidden
            }
            for button in toolbar {
                let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: keyboard)
                for offset in [CGPoint(x: -21, y: 0), CGPoint(x: 21, y: 0), CGPoint(x: 0, y: 21)] {
                    let point = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
                    if keyboard.bounds.contains(point) {
                        XCTAssertTrue(keyboard.hitTest(point, with: nil) === button)
                        XCTAssertTrue(button.point(inside: button.convert(point, from: keyboard), with: nil),
                            "UIKit control tracking must accept the enlarged hit target too")
                    }
                }
            }
            let header = KeyboardMetrics(width: width, compact: compact, showsFooter: true).headerHeight
            for y in stride(from: CGFloat(0.5), to: header, by: 3) {
                for x in stride(from: CGFloat(0.5), to: width, by: 3) {
                    let point = CGPoint(x: x, y: y)
                    XCTAssertNil(surface.resolvedKey(at: point))
                    XCTAssertFalse(keyboard.hitTest(point, with: nil) === surface)
                }
            }
        }
    }

    func testCandidateAnnotationFitsPortraitAndCompactStrip() throws {
        for (width, compact) in [(CGFloat(320), false), (375, false), (680, true)] {
            var presentation = CandidatePresentation(text: "橋", source: .conversion, consumedInputCount: 4, correction: nil)
            presentation.detailAnnotation = "読みの候補"
            let metrics = KeyboardMetrics(width: width, compact: compact, showsFooter: true)
            let button = KeyboardCandidateButton(frame: CGRect(x: 0, y: 0, width: 140, height: metrics.headerHeight - 6))
            button.present(presentation, index: 0, highlighted: true)
            button.layoutIfNeeded()
            let annotation = try XCTUnwrap(descendants(button).first { $0.accessibilityIdentifier == "vime.candidate.annotation" } as? UILabel)
            let title = try XCTUnwrap(button.titleLabel)
            XCTAssertGreaterThanOrEqual(title.bounds.height, title.font.lineHeight)
            XCTAssertGreaterThanOrEqual(annotation.bounds.height, annotation.font.lineHeight)
            XCTAssertGreaterThanOrEqual(annotation.frame.minY, title.frame.maxY)
            XCTAssertLessThanOrEqual(annotation.frame.maxY, button.bounds.height - 2)
            XCTAssertEqual(title.font.pointSize, 18)
        }
    }

    func testQuickSettingsReflowsAtAccessibilitySizeAndRetryIsActionable() throws {
        let host = UIViewController(), window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        let prefs = try preferences()
        let panel = KeyboardSettingsPanel(preferences: prefs)
        host.view.addSubview(panel)
        panel.frame = CGRect(x: 0, y: 0, width: 320, height: 210)
        panel.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        panel.updateTraitsIfNeeded()
        panel.update(hasFullAccess: false, neuralPaused: true)
        panel.layoutIfNeeded()
        for label in descendants(panel).compactMap({ $0 as? UILabel }).filter({ !$0.isHidden && $0.adjustsFontForContentSizeCategory }) {
            XCTAssertGreaterThanOrEqual(label.bounds.height + 1, label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height)
        }
        let sound = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.setting.sound" })
        XCTAssertEqual((sound.superview as? UIStackView)?.axis, .vertical)
        XCTAssertGreaterThan(try XCTUnwrap(descendants(sound.superview!).compactMap { $0 as? UILabel }.first).font.pointSize, 30)
        let layoutChoice = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.setting.numbers.1" } as? UIButton)
        XCTAssertFalse(layoutChoice.superview!.isHidden)
        XCTAssertGreaterThanOrEqual(layoutChoice.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(layoutChoice.titleLabel!.bounds.width,
            ("全键盘" as NSString).size(withAttributes: [.font: layoutChoice.titleLabel!.font!]).width)
        layoutChoice.sendActions(for: .touchUpInside)
        XCTAssertFalse(prefs.nineKeyNumbers)
        let retry = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.settings.neural.retry" } as? UIButton)
        var invoked = false
        panel.onRetryNeural = { invoked = true }
        retry.sendActions(for: .touchUpInside)
        XCTAssertTrue(invoked)
        panel.frame.size.height = panel.contentSize.height
        panel.layoutIfNeeded()
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: panel.bounds).image {
            KeyboardPalette.background.setFill(); $0.fill(panel.bounds)
            panel.layer.render(in: $0.cgContext)
        })
        attachment.name = "quick-settings-accessibility"; attachment.lifetime = .keepAlways; add(attachment)
        panel.update(hasFullAccess: true, neuralPaused: false)
        XCTAssertTrue(try XCTUnwrap(retry.superview).isHidden)
    }

    func testQuickSettingsKeepsFeedbackVisibleAndShortcutsActionable() throws {
        for (width, compact) in [(CGFloat(320), false), (375, false), (568, true), (680, true)] {
            let prefs = try preferences()
            let keyboard = KeyboardView(frame: .zero, session: KeyboardSession(), preferences: prefs)
            keyboard.compact = compact
            keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.preferredHeight(for: width))
            keyboard.layoutIfNeeded()
            let brand = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.brand.settings" } as? UIButton)
            brand.sendActions(for: .touchUpInside)
            keyboard.layoutIfNeeded()
            let panel = try XCTUnwrap(descendants(keyboard).compactMap { $0 as? KeyboardSettingsPanel }.first)
            panel.layoutIfNeeded()
            let sound = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.setting.sound" } as? UISwitch)
            let slider = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.setting.haptics" } as? HapticIntensitySlider)
            let history = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.setting.clipboardHistory" } as? UIButton)
            let app = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "vime.setting.openAppSettings" } as? UIButton)
            for control in [sound, slider, history, app] {
                let rect = control.convert(control.bounds, to: panel)
                XCTAssertGreaterThanOrEqual(rect.minY, 0)
                XCTAssertLessThanOrEqual(rect.maxY, panel.bounds.height, "First-screen control at width \(width): \(rect)")
                XCTAssertGreaterThanOrEqual(rect.minX, 0)
                XCTAssertLessThanOrEqual(rect.maxX, panel.bounds.width)
                if control is UIButton { XCTAssertGreaterThanOrEqual(rect.height, 44) }
            }
            XCTAssertEqual(history.convert(history.bounds, to: panel).minY, app.convert(app.bounds, to: panel).minY, accuracy: 0.5)
            var openedHistory = false, openedApp = false
            panel.onHistory = { openedHistory = true }; panel.onOpenAppSettings = { openedApp = true }
            history.sendActions(for: .touchUpInside); app.sendActions(for: .touchUpInside)
            XCTAssertTrue(openedHistory); XCTAssertTrue(openedApp)
            sound.setOn(!prefs.sound, animated: false); sound.sendActions(for: .valueChanged)
            XCTAssertEqual(prefs.sound, sound.isOn)
            slider.value = 0.7; slider.sendActions(for: .valueChanged)
            XCTAssertEqual(prefs.hapticIntensity, 0.7, accuracy: 0.001)
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: keyboard.bounds).image { keyboard.layer.render(in: $0.cgContext) })
            attachment.name = "quick-settings-first-screen-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testLearningResetDiscardsRetainedConvertersAndDoesNotRepeatAfterCompletion() async throws {
        let prefs = try preferences(), commands = prefs.learningResetRequests
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = JapaneseCandidateWorker(memoryDirectoryURL: directory, resetRequests: commands)
        let retained = JapaneseCandidateWorker(memoryDirectoryURL: directory, resetRequests: commands)
        first.prepareForInput(); retained.prepareForInput()
        _ = await retained.resourceState()
        var composing = ComposingText(); RomajiConverter.insert("hashi", into: &composing)
        let ready = expectation(description: "Get a real learnable native choice")
        var choice: CandidateSnapshot?
        first.candidates(for: composing, katakana: false, revision: 1, leftContext: "", continuity: nil, ranking: .engine) { values, _, secondary in
            if !secondary { choice = values.first { $0.text == "橋" && $0.learningEligible }; ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 10)
        first.complete(try XCTUnwrap(choice))
        _ = await first.resourceState(); _ = await first.resourceState()
        func entries() throws -> [String: Any] {
            let data = try Data(contentsOf: directory.appendingPathComponent("VimeSelectionFrequency.json"))
            return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["entries"] as? [String: Any])
        }
        XCTAssertFalse(try entries().isEmpty)
        // A new command object represents the app's separate preferences reader.
        KeyboardLearningResetRequests(defaults: prefs.store).request()
        XCTAssertTrue(commands.isPending)
        first.prepareForInput()
        _ = await first.resourceState()
        XCTAssertFalse(commands.isPending)
        XCTAssertTrue(try entries().isEmpty)
        retained.releaseInactiveResources()
        _ = await retained.resourceState()
        XCTAssertTrue(try entries().isEmpty, "An old retained converter must not restore cleared memory on teardown")
        // Successful deletion must not erase later learning on another opening.
        let memory = CandidatePreferenceMemory(directory: directory)
        memory.record(reading: "ネコ", surface: "猫"); memory.flush()
        first.prepareForInput(); _ = await first.resourceState()
        XCTAssertFalse(try entries().isEmpty)
        first.releaseInactiveResources(); _ = await first.resourceState()
    }
}
