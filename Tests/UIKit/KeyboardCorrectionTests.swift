import XCTest
import UIKit
import KanaKanjiConverterModuleWithDefaultDictionary
import Darwin

@MainActor
final class KeyboardCorrectionTests: XCTestCase {
    private func query(_ raw: String) -> ComposingText {
        var value = ComposingText(); RomajiConverter.insert(raw, into: &value); return value
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    func testDictionaryCorpusAndBoundedSearch() throws {
        let engine = JapaneseCandidateEngine()
        XCTAssertTrue(CorrectionReadingIndex().isAvailable, "Pinned dictionary priority index must be bundled")
        let positives = [("shitsuka", "しずか"), ("shitsukanabasho", "しずかなばしょ"),
                         ("kikoro", "こころ"), ("kikorogaitai", "こころがいたい"),
                         ("nihngo", "にほんご"), ("nihongoo", "にほんご"), ("nihogno", "にほんご"),
                         ("takaai", "たかい"), ("sakrua", "さくら"), ("skura", "さくら"),
                         ("tomofachi", "ともだち"), ("kirehanandesuka", "これはなんですか")]
        let negatives = ["ki", "ko", "shizuka", "nihongo", "sakura", "kirei", "kiru", "koru",
                         "kinou", "konoha", "koromo", "kikaku", "kokoro", "kasoku", "renai", "rennai",
                         "tarou", "shiori", "yorozu", "tsumugi", "gakkou", "benkyou", "utsukushii",
                         "watashihanihongowobenkyoushiteimasu", "kokorogaitai", "korehanandesuka",
                         "shizukanabasho", "ashitagakkouniiku", "watashihanihongowohanashimasu",
                         "nihongowobenkyousuru", "kazokutoasobu", "kinounotomodachi", "kochiranohougaii"]
        var rows: [[String: Any]] = []
        var recalled = 0
        var recalledKinds = Set<CorrectionKind>()
        for (raw, expected) in positives {
            let composition = query(raw)
            let base = engine.candidates(for: composition, revision: 1, includeCorrections: false)
            let values = engine.addingCorrections(to: base, for: composition, katakana: false, revision: 1)
            let corrections = values.filter { $0.source == .correction }
            let hit = corrections.contains { $0.correction?.suggestedReading == expected }
            if hit { recalled += 1 }
            for value in corrections where value.correction?.suggestedReading == expected {
                recalledKinds.insert(value.correction!.kind)
            }
            print("CORRECTION_POS \(raw) \(hit) \(corrections.map { "\($0.text):\($0.correction?.suggestedReading ?? ""):\($0.candidate.value)" }) base=\(base.prefix(2).map { "\($0.text):\($0.candidate.value)" }) stats=\(engine.lastCorrectionMetrics)")
            rows.append(["raw": raw, "expectedReading": expected, "recalled": hit,
                         "suggestions": corrections.map { $0.correction!.suggestedReading },
                         "queries": engine.lastCorrectionMetrics.queries, "elapsedMs": engine.lastCorrectionMetrics.elapsedMs])
            if let literal = base.first(where: { $0.exactReading && $0.learningEligible }) {
                XCTAssertTrue(values.contains { $0.text == literal.text && $0.correction == nil },
                    "Unified ranking retains literal lexical evidence without reserving leading slots")
            }
            XCTAssertLessThanOrEqual(engine.lastCorrectionMetrics.queries, JapaneseCandidateEngine.maximumCorrectionQueries)
            XCTAssertLessThanOrEqual(engine.lastCorrectionMetrics.variants, KeyboardCorrectionVariants.maximumSearchVariants)
            for value in corrections {
                XCTAssertTrue(JapaneseCandidateEngine.hasDictionaryEvidence(value.candidate))
                XCTAssertEqual(value.candidate.data.map(\.ruby).joined(), RomajiConverter.katakana(value.correction!.suggestedReading))
                XCTAssertEqual(value.consumedInputCount, composition.input.count)
                XCTAssertTrue(value.remainingComposition.isEmpty)
            }
            if raw == "shitsuka" { XCTAssertTrue(hit); XCTAssertTrue(corrections.contains { $0.text == "静か" }) }
        }
        var falseSuggestions = 0
        for raw in negatives {
            let composition = query(raw)
            let base = engine.candidates(for: composition, revision: 1, includeCorrections: false)
            let values = engine.addingCorrections(to: base, for: composition, katakana: false, revision: 1)
            let corrections = values.filter { $0.source == .correction }
            if !corrections.isEmpty { falseSuggestions += 1 }
            print("CORRECTION_NEG \(raw) \(corrections.map { "\($0.text):\($0.correction?.suggestedReading ?? "")" })")
            rows.append(["raw": raw, "negative": true, "unwantedSuggestion": !corrections.isEmpty])
            if let literal = base.first(where: { $0.exactReading && $0.learningEligible }) {
                XCTAssertTrue(values.contains { $0.text == literal.text && $0.correction == nil },
                    "Unified ranking retains literal lexical evidence without reserving leading slots")
            }
            if raw == "ki" || raw == "ko" || raw == "shizuka" { XCTAssertTrue(corrections.isEmpty) }
        }
        var incomplete = query("nanim")
        let baseline = engine.candidates(for: incomplete, revision: 2, includeCorrections: false)
        XCTAssertEqual(engine.addingCorrections(to: baseline, for: incomplete, katakana: false, revision: 2).map(\.presentation),
                       baseline.map(\.presentation))
        incomplete = query(String(repeating: "nihongo", count: 7))
        XCTAssertTrue(KeyboardCorrectionVariants.generate(for: incomplete).isEmpty)
        let report: [String: Any] = ["positiveCount": positives.count, "recallCount": recalled,
            "negativeCount": negatives.count, "falseSuggestionCount": falseSuggestions,
            "falseSuggestionRate": Double(falseSuggestions) / Double(negatives.count),
            "automaticRewriteCount": 0, "cases": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "correction-corpus"; attachment.lifetime = .keepAlways; add(attachment)
        print("CORRECTION_CORPUS recalled=\(recalled)/\(positives.count) false=\(falseSuggestions)/\(negatives.count)")
        XCTAssertEqual(recalledKinds, Set(CorrectionKind.allCases))
        XCTAssertGreaterThanOrEqual(recalled, 11)
        XCTAssertEqual(falseSuggestions, 0)
    }

    // Independent cases: record generalization rather than tuning the search
    // to these words. Every query uses the actual bundled conversion dictionary.
    func testHeldOutDictionarySuggestions() throws {
        let positives = [("tavemono", "たべもの"), ("nomimno", "のみもの"), ("daisukii", "だいすき"),
            ("asihta", "あした"), ("dnesha", "でんしゃ"), ("soshitee", "そして"),
            ("sirekara", "それから"), ("yasahii", "やさしい"), ("haijmete", "はじめて"),
            ("shinknasenn", "しんかんせん")]
        let negatives = ["tabemono", "nomimono", "daisuki", "ashita", "densha", "soshite", "sorekara",
            "yasashii", "hajimete", "shinkansenn", "yukari", "hinata", "sakurai", "tsurugi", "amefurashi"]
        let engine = JapaneseCandidateEngine()
        var recalled = 0, unwanted = 0
        var rows: [[String: Any]] = []
        for (raw, expected) in positives {
            let composition = query(raw)
            let values = engine.candidates(for: composition, revision: 1)
            let corrections = values.filter { $0.source == .correction }
            let hit = corrections.contains { $0.correction?.suggestedReading == expected }
            if hit { recalled += 1 }
            rows.append(["raw": raw, "expectedReading": expected, "recalled": hit,
                "suggestions": corrections.map { $0.correction!.suggestedReading },
                "elapsedMs": engine.lastCorrectionMetrics.elapsedMs])
        }
        for raw in negatives {
            let values = engine.candidates(for: query(raw), revision: 2)
            let corrections = values.filter { $0.source == .correction }
            if !corrections.isEmpty { unwanted += 1 }
            rows.append(["raw": raw, "negative": true, "unwantedSuggestion": !corrections.isEmpty,
                "suggestions": corrections.map { $0.correction!.suggestedReading }])
        }
        let report: [String: Any] = ["positiveCount": positives.count, "recallCount": recalled,
            "negativeCount": negatives.count, "falseSuggestionCount": unwanted,
            "falseSuggestionRate": Double(unwanted) / Double(negatives.count), "cases": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "correction-held-out"; attachment.lifetime = .keepAlways; add(attachment)
        print("CORRECTION_HELD_OUT recalled=\(recalled)/\(positives.count) false=\(unwanted)/\(negatives.count)")
    }

    func testOriginalConsumptionLiteralReturnAndMarkedText() throws {
        let session = KeyboardSession()
        let view = UITextView(); view.text = "前後"; view.selectedRange = NSRange(location: 1, length: 0)
        let host = KeyboardHostConnection(setMarkedText: { view.setMarkedText($0, selectedRange: $1) },
            unmarkText: { view.unmarkText() }, insertText: { view.insertText($0) }, deleteBackward: { view.deleteBackward() })
        _ = session.type("shitsuka"); host.updateMarkedText(session.preedit)
        XCTAssertEqual(view.text, "前しつか後")
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "静か" && $0.source == .correction })
        let snapshot = session.candidateSnapshots[index]
        XCTAssertEqual(snapshot.originalInputCount, 8)
        XCTAssertEqual(snapshot.consumedInputCount, 8)
        XCTAssertEqual(snapshot.correction?.suggestedReading, "しずか")
        host.apply(session.choose(index)); host.updateMarkedText(session.preedit)
        XCTAssertEqual(view.text, "前静か後", "Only the body is inserted; annotation stays in UI")
        XCTAssertFalse(session.isComposing)
        var separated = ComposingText()
        var elements = query("shitsuka").input
        elements.insert(.init(piece: .compositionSeparator, inputStyle: .roman2kana), at: 3)
        separated.insertAtCursorPosition(elements)
        let separatedValues = JapaneseCandidateEngine().candidates(for: separated, revision: 10)
        let separatedCorrection = try XCTUnwrap(separatedValues.first { $0.source == .correction && $0.text == "静か" })
        XCTAssertEqual(separatedCorrection.consumedInputCount, elements.count, "Consume original separators too")
        XCTAssertTrue(separatedCorrection.remainingComposition.isEmpty)
        _ = session.type("shitsuka"); XCTAssertEqual(session.enter(), [.insert("しつか")])
        _ = session.type("nihongoo")
        if let corrected = session.candidateSnapshots.firstIndex(where: { $0.correction?.suggestedReading == "にほんご" }) {
            XCTAssertEqual(session.candidateSnapshots[corrected].consumedInputCount, 8)
            _ = session.choose(corrected); XCTAssertNil(session.preedit)
        }
        _ = session.type("nanimo"); _ = session.backspace(); XCTAssertEqual(session.preedit, "なに")
        session.reset(); _ = session.toggleKana(); _ = session.type("shitsuka")
        XCTAssertEqual(session.preedit, "シツカ")
        XCTAssertLessThanOrEqual(try XCTUnwrap(session.candidates.firstIndex(of: "シツカ")), 3)
    }

    func testTwoPhaseRevisionAndSelectionProtection() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        let normal = expectation(description: "Normal query published first")
        let corrected = expectation(description: "Idle correction published")
        var normalDelivered = false
        session.onCandidatesChange = {
            if !normalDelivered { normalDelivered = true; normal.fulfill() }
            if session.candidateSnapshots.contains(where: { $0.source == .correction && $0.text == "静か" }) { corrected.fulfill() }
        }
        _ = session.type("shitsuka")
        XCTAssertEqual(session.preedit, "しつか")
        await fulfillment(of: [normal, corrected], timeout: 10)
        let old = session.candidateSnapshots
        let oldRevision = session.revision
        session.onCandidatesChange = nil
        _ = session.space()
        let selected = session.selectedText
        session.acceptCandidateUpdate(Array(old.reversed()), revision: oldRevision, supplementary: true)
        XCTAssertEqual(session.selectedText, selected)
        XCTAssertEqual(session.candidatePresentations, old.map(\.presentation))
        _ = session.type("a")
        let newRaw = session.raw
        session.acceptCandidateUpdate(old, revision: oldRevision, supplementary: true)
        XCTAssertEqual(session.raw, newRaw)
        XCTAssertFalse(session.candidateSnapshots.contains { $0.revision == oldRevision } && session.candidatesAreCurrent)
        session.reset()
    }

    func testMetadataRefreshStripPanelAccessibilityAndSameWordConsumption() throws {
        let session = KeyboardSession()
        _ = session.type("shizuka")
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        keyboard.layoutIfNeeded()
        let original = try XCTUnwrap(session.candidateSnapshots.first { $0.text == "静か" })
        let info = CorrectionSuggestion(originalReading: "しつか", suggestedReading: "しずか", correctedRomanInput: "shizuka",
            kind: .phonetic, rangeOffset: 1, rangeLength: 1, rangeUnit: .kanaReading, errorCost: 0.75)
        let replacement = CandidateSnapshot(candidate: original.candidate, revision: session.revision, source: .correction,
            remainingComposition: original.remainingComposition, originalInputCount: original.originalInputCount,
            consumedInputCount: original.consumedInputCount, correction: info)
        var values = session.candidateSnapshots
        let index = try XCTUnwrap(values.firstIndex { $0.text == "静か" })
        values[index] = replacement
        session.acceptCandidateUpdate(values, revision: session.revision, supplementary: true)
        keyboard.layoutIfNeeded()
        XCTAssertTrue(descendants(keyboard).contains { ($0 as? UILabel)?.text == "しずか · 建议" })
        XCTAssertTrue(descendants(keyboard).contains { $0.accessibilityLabel == replacement.presentation.accessibilityLabel })
        let expand = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.candidates.expand" } as? UIButton)
        expand.sendActions(for: .touchUpInside); keyboard.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(descendants(keyboard).filter { $0.accessibilityLabel == replacement.presentation.accessibilityLabel }.count, 2)
        let preview = UIGraphicsImageRenderer(bounds: keyboard.bounds).image { context in
            keyboard.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: preview)
        attachment.name = "correction-panel-preview"; attachment.lifetime = .keepAlways; add(attachment)
        values[index] = original
        session.acceptCandidateUpdate(values, revision: session.revision, supplementary: true)
        XCTAssertFalse(descendants(keyboard).contains { ($0 as? UILabel)?.text == "しずか · 建议" })
        let differentConsumption = CandidateSnapshot(candidate: original.candidate, revision: session.revision, source: .conversion,
            remainingComposition: query("a"), originalInputCount: original.originalInputCount,
            consumedInputCount: original.consumedInputCount - 1)
        XCTAssertNotEqual(original.presentation, differentConsumption.presentation)
    }

    func testProfileIdleCorrectionPublicationAndMemory() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        keyboard.hasFullAccess = false
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(keyboard); window.isHidden = false
        let text = UITextView(frame: CGRect(x: 0, y: 0, width: 440, height: 150))
        window.rootViewController?.view.addSubview(text)
        let host = KeyboardHostConnection(setMarkedText: { text.setMarkedText($0, selectedRange: $1) },
            unmarkText: { text.unmarkText() }, insertText: { text.insertText($0) }, deleteBackward: { text.deleteBackward() })
        keyboard.onEdit = { host.apply($0) }; keyboard.onMarkedTextChange = { host.updateMarkedText($0) }
        keyboard.layoutIfNeeded()
        let update = session.onCandidatesChange
        var normalWarmMB = 0.0, correctionWarmMB = 0.0, peakMB = 0.0
        var correctionLatencies: [Double] = []
        defer { session.onCandidatesChange = nil; KeyboardPerformance.configure(enabled: false); window.isHidden = true }
        for pass in 0..<11 {
            if pass == 1 { KeyboardPerformance.configure(enabled: true, reset: true) }
            for (raw, expected) in [("shitsuka", "静か"), ("nihongoo", "日本語"), ("kikoro", "心")] {
                keyboard.resetComposition()
                let done = expectation(description: "Idle correction for \(raw)")
                let started = ProcessInfo.processInfo.systemUptime
                var delivered = false
                session.onCandidatesChange = {
                    update?()
                    if !session.candidateSnapshots.contains(where: { $0.source == .correction && $0.text == expected }) {
                        if pass == 0 && raw == "shitsuka" { normalWarmMB = self.footprintMB() }
                        return
                    }
                    guard !delivered else { return }; delivered = true
                    let footprint = self.footprintMB(); peakMB = max(peakMB, footprint)
                    if pass == 0 { correctionWarmMB = footprint }
                    if pass > 0 { correctionLatencies.append((ProcessInfo.processInfo.systemUptime - started) * 1000) }
                    done.fulfill()
                }
                for c in raw {
                    let button = try XCTUnwrap(descendants(keyboard).first { $0.accessibilityIdentifier == "vime.key.\(c)" } as? UIButton)
                    button.sendActions(for: .touchUpInside)
                    XCTAssertEqual(host.markedText, session.preedit)
                }
                await fulfillment(of: [done], timeout: 10)
                guard delivered else { return }
                XCTAssertEqual(session.raw, raw)
                XCTAssertEqual(session.preedit, query(raw).convertTarget)
            }
        }
        let timings = KeyboardPerformance.report()
        XCTAssertEqual(correctionLatencies.count, 30)
        XCTAssertEqual(timings["typeToMarked"]?["count"], 220)
        let sorted = correctionLatencies.sorted()
        let report: [String: Any] = ["timings": timings, "samples": 30,
            "idleCorrectionToUIP95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "normalWarmFootprintMB": normalWarmMB, "correctionWarmFootprintMB": correctionWarmMB,
            "peakFootprintMB": peakMB, "endFootprintMB": footprintMB(),
            "readingIndexBytes": 4_910_128,
            "measurement": "Attached real UIWindow and UITextView, one warm pass plus ten measured passes of shitsuka/nihongoo/kikoro. Type every Roman key, wait for the supplementary correction, no forced selection."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "idle-correction-profile"; attachment.lifetime = .keepAlways; add(attachment)
        print("IDLE_CORRECTION_PROFILE " + String(decoding: data, as: UTF8.self))
    }
}
