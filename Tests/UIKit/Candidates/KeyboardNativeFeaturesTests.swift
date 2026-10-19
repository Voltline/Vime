import XCTest
import UIKit
import KanaKanjiConverterModuleWithDefaultDictionary

@MainActor
final class KeyboardNativeFeaturesTests: XCTestCase {
    private func query(_ input: String) -> ComposingText {
        var value = ComposingText(); RomajiConverter.insert(input, into: &value); return value
    }
    func testSpecialConversionsAndEmojiPreserveConsumption() throws {
        let engine = JapaneseCandidateEngine()
        for (input, expected) in [("1230", "12:30"), ("1000000", "1,000,000"), ("reiwa6nenn", "2024年"), ("u+3042", "あ"), ("test@", "test@gmail.com")] {
            engine.reset()
            let values = engine.candidates(for: query(input), revision: 1, includeCorrections: false)
            print("NATIVE_SPECIAL \(input) \(values.prefix(12).map(\.text))")
            let value = try XCTUnwrap(values.first { $0.text == expected && $0.source == .specialConversion })
            XCTAssertTrue(value.fullConsumption)
            XCTAssertFalse(value.learningEligible)
            XCTAssertEqual(value.presentation.annotation, "格式转换")
        }
        let values = engine.candidates(for: query("neko"), revision: 2, includeCorrections: false)
        let emoji = try XCTUnwrap(values.first { $0.source == .emoji })
        XCTAssertTrue(emoji.fullConsumption)
        XCTAssertFalse(emoji.learningEligible)
        XCTAssertTrue(values.contains { $0.text == "猫" && $0.lexical })
        let session = KeyboardSession(); _ = session.type("1230")
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "12:30" })
        XCTAssertEqual(session.choose(index), [.insert("12:30")])
        XCTAssertFalse(session.isComposing)
    }

    func testDictionaryImportReloadAndNativeWordAndShortcut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let writer = JapaneseUserDictionaryStore(directory: directory, defaults: defaults)
        let reader = JapaneseUserDictionaryStore(directory: directory, defaults: defaults)
        let engine = JapaneseCandidateEngine(userDictionary: reader)
        XCTAssertTrue(try reader.entries().isEmpty)
        let word = JapaneseUserDictionaryEntry(reading: "b", surface: "Vime開発班")
        XCTAssertThrowsError(try writer.save([word]), "Unresolved Roman input is not a reading")
        try writer.save([.init(reading: "bimu", surface: "Vime開発班"), .init(reading: "aisatsu", surface: "いつもお世話になっております。", kind: .shortcut)])
        XCTAssertEqual(try reader.entries().count, 2)
        for (reading, surface) in [("bimu", "Vime開発班"), ("aisatsu", "いつもお世話になっております。")] {
            let values = engine.candidates(for: query(reading), revision: 1, includeCorrections: false)
            let value = try XCTUnwrap(values.first { $0.text == surface && $0.fullConsumption })
            XCTAssertEqual(value.source, .userDictionary)
            XCTAssertTrue(value.candidate.data.contains { $0.metadata.contains(.isFromUserDictionary) })
        }
        let export = try writer.exportData(); try writer.importData(export)
        XCTAssertEqual(try writer.entries().count, 2)
        let restored = JapaneseUserDictionaryStore(directory: directory, defaults: defaults)
        XCTAssertEqual(try restored.entries().count, 2)
        try writer.save([])
        let cleared = reader.nativeEntries()
        XCTAssertTrue(cleared.words.isEmpty)
        XCTAssertTrue(cleared.shortcuts.isEmpty, "A new revision must invalidate both cached entry kinds")
        XCTAssertFalse(engine.candidates(for: query("bimu"), revision: 2, includeCorrections: false).contains { $0.text == "Vime開発班" })
        XCTAssertThrowsError(try writer.importData(Data("{\"version\":2,\"entries\":[]}".utf8)))
        XCTAssertTrue(try writer.entries().isEmpty)
    }

    func testNearlyFullDictionaryExportCanBeImportedWithoutLosingEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = JapaneseUserDictionaryStore(directory: directory, defaults: defaults)
        let all = (0..<JapaneseUserDictionaryStore.maximumEntries).map {
            JapaneseUserDictionaryEntry(reading: String(repeating: "ア", count: 64),
                surface: String(repeating: "☀️", count: 120) + String($0))
        }
        let encoder = JSONEncoder()
        func archive(_ count: Int) -> JapaneseUserDictionaryStore.Archive { .init(entries: Array(all.prefix(count))) }
        var lower = 1, upper = all.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if try encoder.encode(archive(middle)).count <= JapaneseUserDictionaryStore.maximumBytes { lower = middle }
            else { upper = middle - 1 }
        }
        let entries = archive(lower).entries
        try store.save(entries)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        XCTAssertGreaterThan(try encoder.encode(archive(lower)).count, JapaneseUserDictionaryStore.maximumBytes,
            "Exercise a valid dictionary whose formatted export crosses the import limit")
        let data = try store.exportData()
        XCTAssertLessThanOrEqual(data.count, JapaneseUserDictionaryStore.maximumBytes)
        XCTAssertEqual(try JapaneseUserDictionaryStore.decode(data), try store.entries())
        try store.importData(data)
        XCTAssertEqual(try store.entries(), entries, "Reimport must preserve every entry and deduplicate")
    }

    func testNativeSuggestionsWorkWithoutNeuralModelAndTerminalStops() throws {
        let session = KeyboardSession(); session.phraseSuggestions = true; session.candidateRanking = .engine
        _ = session.type("desu")
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "です" && $0.fullConsumption })
        XCTAssertEqual(session.choose(index), [.insert("です")])
        print("NATIVE_NEXT desu \(session.suggestions)")
        XCTAssertFalse(session.suggestions.isEmpty)
        XCTAssertTrue(session.stripPresentations.contains { $0.source == .enginePrediction })
        let terminal = try XCTUnwrap(session.suggestions.firstIndex(of: "。"))
        XCTAssertEqual(session.chooseSuggestion(terminal), [.insert("。")])
        XCTAssertTrue(session.suggestions.isEmpty)
    }

    func testNativeReplacementChecksHostAndReceiptsBeforeLearning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = KeyboardSession(memoryDirectoryURL: directory)
        session.phraseSuggestions = true; session.candidateRanking = .engine
        var before = ""; var document = "fieldA"
        session.leftContextProvider = { before }
        session.learningContextProvider = { KeyboardLearningContext(document: document, before: before, after: "") }
        _ = session.type("toukyou")
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "東京" && $0.fullConsumption })
        let edits = session.choose(index); before = "東京"; session.didApplyEdits(edits)
        print("NATIVE_NEXT Tokyo \(session.suggestions)")
        let replacement = try XCTUnwrap(session.stripPresentations.firstIndex { $0.annotation?.hasPrefix("替换") == true })
        let target = session.suggestions[replacement]
        document = "fieldB"
        XCTAssertTrue(session.chooseSuggestion(replacement).isEmpty, "Same text in a different field is unsafe")
        document = "fieldA"; session.reset(); before = ""; _ = session.type("toukyou")
        let next = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "東京" && $0.fullConsumption })
        let committed = session.choose(next); before = "東京"; session.didApplyEdits(committed)
        let chosen = try XCTUnwrap(session.suggestions.firstIndex(of: target))
        let replacementEdits = session.chooseSuggestion(chosen)
        XCTAssertEqual(replacementEdits, [.deleteBackward, .deleteBackward, .insert(target)])
        before = target; session.didApplyEdits(replacementEdits); session.finishLearningFeedback()
        let archive = try XCTUnwrap(String(data: Data(contentsOf: directory.appendingPathComponent("VimeSelectionFrequency.json")), encoding: .utf8))
        XCTAssertTrue(archive.contains(target))
        XCTAssertTrue(session.suggestions.isEmpty || session.stripPresentations.allSatisfy { $0.selectionToken != nil })
    }

    func testEmojiPostPredictionRetainsNativeMetadataAndOperationsRemainDistinct() throws {
        let engine = JapaneseCandidateEngine()
        let cat = try XCTUnwrap(engine.candidates(for: query("neko"), revision: 1, includeCorrections: false).first { $0.text == "猫" && $0.lexical })
        engine.complete(cat)
        let native = engine.postCompositionSuggestions(leftContext: "猫")
        XCTAssertTrue(native.contains { $0.source == .emoji && $0.nativePrediction != nil })
        let first = try XCTUnwrap(native.first)
        let neural = NextWordSuggestion(text: first.text, source: .contextPrediction, score: 99, userScore: 0)
        let merged = PostCompositionSuggestionReranker.merge(native: native, neural: [neural])
        XCTAssertTrue(merged.contains { $0.text == first.text && $0.nativePrediction != nil })
        print("NATIVE_NEXT cat \(merged.map(\.text))")
    }

    func testNativeAsyncPublicationAndTypingCancelsSuggestions() async throws {
        let session = KeyboardSession(asynchronousCandidates: true, memoryDirectoryURL: isolatedLearningDirectory())
        session.phraseSuggestions = true; session.candidateRanking = .engine
        _ = session.type("desu")
        for _ in 0..<200 where !session.candidatesAreCurrent { try await Task.sleep(for: .milliseconds(10)) }
        let index = try XCTUnwrap(session.candidateSnapshots.firstIndex { $0.text == "です" && $0.fullConsumption })
        _ = session.choose(index)
        for _ in 0..<200 where session.suggestions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.suggestions.isEmpty)
        let token = try XCTUnwrap(session.stripPresentations.first?.selectionToken)
        _ = session.type("neko")
        XCTAssertTrue(session.suggestions.isEmpty)
        XCTAssertTrue(session.chooseCandidate(token).isEmpty)
        XCTAssertEqual(session.composition, "ねこ")
    }

    func testNeuralRerankScoresNativeSuffixWithoutRepeatingBase() throws {
        let engine = JapaneseCandidateEngine()
        let tokyo = try XCTUnwrap(engine.candidates(for: query("toukyou"), revision: 1, includeCorrections: false).first { $0.text == "東京" && $0.fullConsumption })
        engine.complete(tokyo)
        let native = engine.postCompositionSuggestions(leftContext: "東京")
        let replacement = try XCTUnwrap(native.first { $0.nativePrediction?.isReplacement == true })
        XCTAssertNotEqual(replacement.text, replacement.nativePrediction?.text)
        let model = try VimeLanguageModel()
        let selected = Array(native.filter { $0.nativePrediction?.isReplacement == true }.prefix(3))
        let expected = try model.scores(context: "東京", candidates: selected.map { $0.nativePrediction!.text })
        let ranked = model.rerankPostComposition(selected, prompt: "東京")
        XCTAssertEqual(Set(ranked.map(\.text)), Set(selected.map(\.text)))
        XCTAssertTrue(ranked.allSatisfy { $0.modelScore?.isFinite == true && $0.nativePrediction != nil })
        for value in ranked {
            let index = try XCTUnwrap(selected.firstIndex { $0.text == value.text })
            XCTAssertEqual(try XCTUnwrap(value.modelScore), expected[index], accuracy: 0.0001)
        }
        print("NATIVE_NEURAL \(ranked.map { ($0.text, $0.modelScore ?? 0) })")
    }

    func testNumberFieldStaysLiteralWhileNormalTextOffersConversion() throws {
        let session = KeyboardSession()
        let keyboard = KeyboardView(frame: CGRect(x: 0, y: 0, width: 440, height: 350), session: session)
        defer { keyboard.stopInteractions() }
        var edits: [KeyboardEdit] = []; keyboard.onEdit = { edits += $0 }
        func keys(_ view: UIView) -> [KeyboardKey] { (view as? KeyboardKey).map { [$0] } ?? view.subviews.flatMap(keys) }
        keyboard.keyboardType = .numberPad
        try XCTUnwrap(keys(keyboard).first { $0.title(for: .normal) == "1" }).action?()
        XCTAssertEqual(edits, [.insert("1")])
        XCTAssertFalse(session.isComposing)
        keyboard.keyboardType = .default
        try XCTUnwrap(keys(keyboard).first { $0.title(for: .normal) == "123" }).action?()
        try XCTUnwrap(keys(keyboard).first { $0.title(for: .normal) == "1" }).action?()
        XCTAssertEqual(session.raw, "1")
        XCTAssertTrue(session.isComposing)
        XCTAssertEqual(edits, [.insert("1")], "Normal text keeps the digit editable until confirmation")
    }

    func testNeuralRerankScoresSharedContinuationWithoutMergingHostOperations() throws {
        let engine = JapaneseCandidateEngine()
        let tokyo = try XCTUnwrap(engine.candidates(for: query("toukyou"), revision: 1, includeCorrections: false)
            .first { $0.text == "東京" && $0.fullConsumption })
        engine.complete(tokyo)
        let replacement = try XCTUnwrap(engine.postCompositionSuggestions(leftContext: "東京")
            .first { $0.nativePrediction?.isReplacement == true })
        let continuation = try XCTUnwrap(replacement.nativePrediction?.text)
        let addition = NextWordSuggestion(text: continuation, source: .contextPrediction, score: 0, userScore: 0)
        let model = try VimeLanguageModel()
        let cache = VimeLanguageModel.SuggestionScoreCache()
        let expected = try XCTUnwrap(model.scores(context: "東京", candidates: [continuation], cache: cache).first)
        KeyboardPerformance.configure(enabled: true, reset: true)
        defer { KeyboardPerformance.configure(enabled: false) }
        let ranked = model.rerankPostComposition([replacement, addition], prompt: "東京", cache: cache)
        XCTAssertNil(KeyboardPerformance.report()["lmScoringTokenization"],
            "Reuse the context and shared continuation already validated during initial scoring")
        XCTAssertEqual(KeyboardPerformance.report()["lmScoringTokenReuse"]?["totalCount"], 2)
        XCTAssertEqual(cache.reuses, 1, "Shared continuation reuses one score for both host operations")
        XCTAssertEqual(cache.scoringPasses, 1, "Only the initial scoring requires inference")
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.filter { $0.nativePrediction != nil }.count, 1)
        XCTAssertEqual(ranked.filter { $0.nativePrediction == nil }.count, 1)
        for value in ranked {
            XCTAssertEqual(try XCTUnwrap(value.modelScore), expected, accuracy: 0.0001)
        }
        let sameTextAddition = NextWordSuggestion(text: replacement.text, source: .contextPrediction, score: 0, userScore: 0)
        XCTAssertFalse(replacement.hasSameOperation(as: sameTextAddition))
        XCTAssertTrue(PostCompositionSuggestionReranker.hasNewSuggestions([sameTextAddition], comparedTo: [replacement]),
            "An addition must still be ranked even when a replacement displays the same text")
    }

    func testFinalSuggestionRankingRequiresANewPublishedOperation() {
        let one = NextWordSuggestion(text: "です", source: .contextPrediction, score: 3, userScore: 0)
        let two = NextWordSuggestion(text: "ます", source: .contextPrediction, score: 2, userScore: 0)
        var rescored = one
        rescored.modelScore = -1; rescored.score = 10
        XCTAssertFalse(PostCompositionSuggestionReranker.hasNewSuggestions([two, rescored], comparedTo: [one, two]))
        XCTAssertFalse(PostCompositionSuggestionReranker.hasNewSuggestions([one], comparedTo: [one, two]))
        XCTAssertFalse(PostCompositionSuggestionReranker.hasNewSuggestions([], comparedTo: []))
        XCTAssertTrue(PostCompositionSuggestionReranker.hasNewSuggestions([one], comparedTo: []))
        XCTAssertTrue(PostCompositionSuggestionReranker.hasNewSuggestions([one, two], comparedTo: [one]))
        let composed = NextWordSuggestion(text: "が", source: .contextPrediction, score: 0, userScore: 0)
        let decomposed = NextWordSuggestion(text: "か\u{3099}", source: .contextPrediction, score: 0, userScore: 0)
        XCTAssertTrue(PostCompositionSuggestionReranker.hasNewSuggestions([decomposed], comparedTo: [composed]),
            "Match the session's exact UTF-8 operation identity")
    }
}
