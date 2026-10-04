import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardEngineDiagnosticsTests: XCTestCase {
    func testRecordPinnedEngineManualAndAutoMix() throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var records: [[String: Any]] = []
        let words = ["nihongo", "nani", "nanim", "nanimo", "arigat", "arigato", "ohayou", "konnichiha", "konnich", "konnichi", "gakk", "gakkou"]
        func snapshot(_ candidate: Candidate) -> [String: Any] {
            ["text": candidate.text, "score": String(describing: candidate.value), "composingCount": String(describing: candidate.composingCount),
             "data": candidate.data.map { ["word": $0.word, "ruby": $0.ruby] }, "inputable": candidate.inputable]
        }
        for (label, mixing) in [("manualMix", ConvertRequestOptions.PredictionMode.manualMix), ("autoMix", .autoMix)] {
            let converter = KanaKanjiConverter.withDefaultDictionary()
            let options = ConvertRequestOptions(N_best: 10, requireJapanesePrediction: mixing,
                requireEnglishPrediction: .disabled, keyboardLanguage: .ja_JP,
                learningType: .nothing, memoryDirectoryURL: directory, sharedContainerURL: directory,
                textReplacer: .empty, specialCandidateProviders: [], typoCorrectionMode: .disabled,
                metadata: .init(versionString: "VimeDiagnostics"))
            for word in words {
                converter.stopComposition()
                var composing = ComposingText()
                var result: ConversionResult?
                var durations: [Double] = []
                for c in word {
                    composing.insertAtCursorPosition(String(c), inputStyle: .roman2kana)
                    let start = ProcessInfo.processInfo.systemUptime
                    result = converter.requestCandidates(composing, options: options)
                    durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                }
                let conversion = try XCTUnwrap(result)
                let session = KeyboardSession()
                _ = session.type(word)
                let record: [String: Any] = ["mode": label, "raw": word, "convertTarget": composing.convertTarget,
                    "mainResults": conversion.mainResults.map(snapshot), "predictionResults": conversion.predictionResults.map(snapshot),
                    "milliseconds": durations, "vimePresentation": session.candidates]
                records.append(record)
                print("ENGINE_BASELINE \(label) \(word) preedit=\(composing.convertTarget) main=\(conversion.mainResults.prefix(5).map(\.text)) prediction=\(conversion.predictionResults.map(\.text)) vimePresentation=\(session.candidates.prefix(5)) ms=\(durations.last!)")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "engine-baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
        try data.write(to: directory.appendingPathComponent("engine-baseline.json"))
        XCTAssertEqual(records.count, words.count * 2)
    }
}
