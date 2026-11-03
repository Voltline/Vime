import XCTest
import KanaKanjiConverterModuleWithDefaultDictionary

/// Opt-in candidate quality benchmark, run by Scripts/candidate_benchmark.sh
/// (TEST_RUNNER_VIME_CANDIDATE_BENCHMARK=1). Each reading is typed as romaji one
/// key at a time through the real engine, as the session requests candidates;
/// smart order then applies the on-device model without the 60 ms publication
/// window, so results do not depend on simulator speed. The committed everyday
/// set always runs; VIME_CANDIDATE_BENCHMARK_CORPUS adds local tracks
/// (comma-separated JSON paths, such as AJIMEE-Bench from
/// Scripts/build_candidate_benchmark_corpus.py). The everyday-learned track
/// repeats the everyday set after the user has picked common one-kana clauses
/// on their own (で, は, 手 …), the history that once split では into で + は.
/// The report goes to VIME_CANDIDATE_BENCHMARK_REPORT (a directory).
@MainActor
final class KeyboardCandidateBenchmarkTests: XCTestCase {
    struct Case: Codable {
        let id: String
        let category: String
        let context: String
        let reading: String
        let accept: [String]
    }
    struct Corpus: Codable {
        let source: String
        let cases: [Case]
    }

    /// One mode's view of one case: the ranks seen after the last key and the
    /// earliest key at which a reference was shown.
    struct Outcome: Codable {
        var rank: Int?               // 1-based rank of a reference consuming the whole input
        var top: [String]            // first candidates after the last key, partial ones marked
        var partialFirst: Bool       // the first candidate leaves part of the input unconverted
        var partialAboveReference: Bool
        var failure: String?         // why the first candidate is wrong, when it is
        var firstTop3Key: Int?       // keys typed when a reference first entered the top three
        var firstTop1Key: Int?
        var halfwayTop3: Bool?       // a reference in the top three at half the reading (≥ 4 kana)
    }
    struct Row: Codable {
        let id: String
        let track: String
        let category: String
        let context: String
        let reading: String
        let romaji: String
        let accept: [String]
        let engine: Outcome
        let languageModel: Outcome
    }

    func testCandidateQualityBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["VIME_CANDIDATE_BENCHMARK"] == "1",
            "Run Scripts/candidate_benchmark.sh to measure candidate quality")
        XCTAssertTrue(try JapaneseUserDictionaryStore().entries().isEmpty, "The benchmark requires an empty user dictionary")
        var tracks: [(name: String, corpus: Corpus, learned: Bool)] = []
        let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "CandidateBenchmarkEveryday", withExtension: "json"))
        let everyday = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: bundled))
        tracks.append(("everyday", everyday, false))
        tracks.append(("everyday-learned", everyday, true))
        for path in (environment["VIME_CANDIDATE_BENCHMARK_CORPUS"] ?? "").split(separator: ",").map(String.init) where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            tracks.append((url.deletingPathExtension().lastPathComponent, try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url)), false))
        }
        let limit = Int(environment["VIME_CANDIDATE_BENCHMARK_LIMIT"] ?? "") ?? .max
        let directory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fresh = JapaneseCandidateEngine(memoryDirectoryURL: directory, learningEnabled: false)
        fresh.prepareForInput()
        let learnedDirectory = isolatedLearningDirectory()
        defer { try? FileManager.default.removeItem(at: learnedDirectory) }
        let memory = CandidatePreferenceMemory(directory: learnedDirectory)
        for (reading, surface) in Self.learnedClauses {
            for _ in 0..<4 {
                memory.record(reading: reading, surface: surface)
                memory.record(reading: reading, surface: surface, scope: "choice")
            }
        }
        memory.flush()
        let learned = JapaneseCandidateEngine(memoryDirectoryURL: learnedDirectory, learningEnabled: true)
        let model = try VimeLanguageModel()
        var rows: [Row] = [], skipped: [String] = []
        let started = Date()
        for (track, corpus, history) in tracks {
            let engine = history ? learned : fresh
            for item in corpus.cases.prefix(limit) {
                guard let romaji = Self.romaji(item.reading), Self.typed(romaji).convertTarget == item.reading else {
                    skipped.append(item.id); continue
                }
                let accept = Set(item.accept.map { $0.precomposedStringWithCanonicalMapping })
                func run(_ smart: Bool) -> Outcome {
                    engine.reset()
                    engine.reconcileContext(item.context)
                    let context = VimeLanguageModel.sentenceContext(item.context)
                    var composing = ComposingText(), previous: CandidateContinuity?, input = ""
                    var outcome = Outcome(top: [], partialFirst: false, partialAboveReference: false)
                    let keys = Array(romaji)
                    for (offset, key) in keys.enumerated() {
                        RomajiConverter.insert(String(key), into: &composing); input.append(key)
                        // The session seeds continuity from the list it last showed.
                        engine.seedContinuity(previous)
                        var values = engine.candidates(for: composing, revision: offset + 1, includeCorrections: false)
                        if smart {
                            values = model.rerank(values, context: context, katakana: false,
                                maximumCandidates: JapaneseCandidateWorker.initialRankingCandidateLimit, cancelled: { false })
                        }
                        previous = values.first.map { CandidateContinuity(surface: $0.text, reading: $0.reading, input: input) }
                        let shown = values.prefix(3).map { accept.contains($0.text.precomposedStringWithCanonicalMapping) }
                        if outcome.firstTop3Key == nil, shown.contains(true) { outcome.firstTop3Key = offset + 1 }
                        if outcome.firstTop1Key == nil, shown.first == true { outcome.firstTop1Key = offset + 1 }
                        let pending = composing.convertTarget.unicodeScalars.contains { $0.isASCII }
                        if outcome.halfwayTop3 == nil, item.reading.count >= 4, !pending,
                           composing.convertTarget.count * 2 >= item.reading.count, offset < keys.count - 1 {
                            outcome.halfwayTop3 = shown.contains(true)
                        }
                        guard offset == keys.count - 1 else { continue }
                        let referenceIndex = values.firstIndex {
                            $0.fullConsumption && accept.contains($0.text.precomposedStringWithCanonicalMapping)
                        }
                        outcome.rank = referenceIndex.map { $0 + 1 }
                        outcome.top = values.prefix(5).map { $0.fullConsumption ? $0.text : $0.text + "…" }
                        outcome.partialFirst = values.first.map { !$0.fullConsumption } ?? false
                        outcome.partialAboveReference = referenceIndex.map { values.prefix($0).contains { !$0.fullConsumption } } ?? false
                        if referenceIndex != 0, let first = values.first {
                            outcome.failure = Self.failure(of: first, reading: item.reading, accept: accept, found: referenceIndex != nil)
                        }
                    }
                    return outcome
                }
                rows.append(Row(id: item.id, track: track, category: item.category, context: item.context,
                    reading: item.reading, romaji: romaji, accept: item.accept, engine: run(false), languageModel: run(true)))
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        let report = Self.summary(rows, tracks: tracks.map(\.name))
        let markdown = Self.markdown(report, rows: rows, skipped: skipped, model: model.modelVersion, elapsed: elapsed)
        print(markdown)
        for line in report.lines { print("VIME_CANDIDATE_BENCHMARK " + line) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(["rows": rows])
        if let path = environment["VIME_CANDIDATE_BENCHMARK_REPORT"], !path.isEmpty {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try json.write(to: folder.appendingPathComponent("candidate-benchmark.json"))
            try Data(markdown.utf8).write(to: folder.appendingPathComponent("candidate-benchmark.md"))
            print("VIME_CANDIDATE_BENCHMARK_REPORT " + folder.path)
        }
        let attachment = XCTAttachment(data: Data(markdown.utf8), uniformTypeIdentifier: "net.daringfireball.markdown")
        attachment.name = "candidate-benchmark"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(skipped.isEmpty, "Readings romaji cannot reproduce: \(skipped.prefix(10))")
    }

    /// Clauses a user commonly converts on their own, as katakana readings.
    static let learnedClauses = [("デ", "で"), ("ハ", "は"), ("ニ", "に"), ("ガ", "が"), ("ヲ", "を"), ("ト", "と"),
        ("モ", "も"), ("ノ", "の"), ("カ", "か"), ("ヘ", "へ"), ("ヤ", "や"), ("ネ", "ね"), ("ヨ", "よ"), ("テ", "手"),
        ("メ", "目"), ("キ", "気"), ("ヒ", "日"), ("イマ", "今"), ("ワタシ", "私"), ("ホン", "本"), ("マエ", "前"), ("ナカ", "中")]

    // MARK: Classification

    /// Why the first candidate is not a reference.
    static func failure(of first: CandidateSnapshot, reading: String, accept: Set<String>, found: Bool) -> String {
        if !first.fullConsumption { return "partial_clause" }
        if first.isPrediction && first.reading.count > reading.count { return "prediction" }
        if first.source == .correction || first.correction != nil { return "correction" }
        let kana = RomajiConverter.katakana(reading)
        let firstIsKana = RomajiConverter.katakana(first.text) == kana
        let referenceHasKana = accept.contains { RomajiConverter.katakana($0) == kana }
        if firstIsKana && !referenceHasKana { return "kana_over_kanji" }
        if !firstIsKana && referenceHasKana { return "kanji_over_kana" }
        return found ? "homophone_or_segmentation" : "missing"
    }

    // MARK: Romaji

    private static let romajiTable: [String: String] = {
        var table: [String: String] = [:]
        let rows = """
        あ a い i う u え e お o か ka き ki く ku け ke こ ko さ sa し shi す su せ se そ so \
        た ta ち chi つ tsu て te と to な na に ni ぬ nu ね ne の no は ha ひ hi ふ fu へ he ほ ho \
        ま ma み mi む mu め me も mo や ya ゆ yu よ yo ら ra り ri る ru れ re ろ ro わ wa を wo \
        が ga ぎ gi ぐ gu げ ge ご go ざ za じ ji ず zu ぜ ze ぞ zo だ da ぢ di づ du で de ど do \
        ば ba び bi ぶ bu べ be ぼ bo ぱ pa ぴ pi ぷ pu ぺ pe ぽ po ゔ vu \
        ぁ xa ぃ xi ぅ xu ぇ xe ぉ xo ゃ xya ゅ xyu ょ xyo っ xtu \
        きゃ kya きゅ kyu きょ kyo しゃ sha しゅ shu しょ sho ちゃ cha ちゅ chu ちょ cho \
        にゃ nya にゅ nyu にょ nyo ひゃ hya ひゅ hyu ひょ hyo みゃ mya みゅ myu みょ myo \
        りゃ rya りゅ ryu りょ ryo ぎゃ gya ぎゅ gyu ぎょ gyo じゃ ja じゅ ju じょ jo \
        ぢゃ dya ぢゅ dyu ぢょ dyo びゃ bya びゅ byu びょ byo ぴゃ pya ぴゅ pyu ぴょ pyo \
        しぇ she ちぇ che じぇ je てぃ thi でぃ dhi でゅ dhu ふぁ fa ふぃ fi ふぇ fe ふぉ fo \
        うぃ wi うぇ we うぉ who ゔぁ va ゔぃ vi ゔぇ ve ゔぉ vo つぁ tsa とぅ twu どぅ dwu いぇ ye
        """.split(separator: " ")
        for pair in stride(from: 0, to: rows.count - 1, by: 2) { table[String(rows[pair])] = String(rows[pair + 1]) }
        return table
    }()

    /// Hepburn keys as typed: n before a consonant, nn before a vowel, y, n or
    /// the end; a doubled consonant for っ (cch: azooKey has no tch).
    static func romaji(_ reading: String) -> String? {
        let characters = Array(reading)
        var units: [String] = []
        var index = 0
        while index < characters.count {
            if index + 1 < characters.count, let pair = romajiTable[String(characters[index...index + 1])] {
                units.append(pair); index += 2; continue
            }
            let c = String(characters[index])
            // The keyboard has its own keys for ー, 、 and 。.
            if c == "ん" || c == "っ" || "ー、。".contains(c) { units.append(c) }
            else if let value = romajiTable[c] { units.append(value) } else { return nil }
            index += 1
        }
        var result = ""
        for (offset, unit) in units.enumerated() {
            let next = offset + 1 < units.count ? units[offset + 1] : nil
            switch unit {
            case "ん":
                if let next, let first = next.first, first.isASCII, first.isLetter, !"aiueoynx".contains(first) { result += "n" }
                else { result += "nn" }
            case "っ":
                if let next, let first = next.first, first.isASCII, first.isLetter, !"aiueoxn".contains(first) { result.append(first) }
                else { result += "xtu" }
            default: result += unit
            }
        }
        return result
    }

    static func typed(_ romaji: String) -> ComposingText {
        var composing = ComposingText()
        for key in romaji { RomajiConverter.insert(String(key), into: &composing) }
        return composing
    }

    func testRomajiTypingReproducesReadings() {
        for reading in ["では", "こんにちは", "きって", "がっこう", "こーひー", "しんぶん", "ほんや", "きんえん",
                        "ちょっと", "まっちゃ", "ぱーてぃー", "うぉーたー", "てんいん", "ぜんぶ", "おんな", "はい、そうです。", "ほん、", "らーめん", "かんー", "まっちゃ、"] {
            let romaji = Self.romaji(reading)
            XCTAssertNotNil(romaji, reading)
            XCTAssertEqual(romaji.map(Self.typed)?.convertTarget, reading, romaji ?? reading)
        }
    }

    // MARK: Summary

    struct Metrics {
        var cases = 0, top1 = 0, top3 = 0, found = 0, partialFirst = 0, partialAbove = 0
        var halfway = 0, halfwayHits = 0, savedKeys = 0.0, keys = 0
        var failures: [String: Int] = [:]
        mutating func add(_ o: Outcome, keys typed: Int) {
            cases += 1
            if o.rank == 1 { top1 += 1 }
            if let rank = o.rank, rank <= 3 { top3 += 1 }
            if o.rank != nil { found += 1 }
            if o.partialFirst { partialFirst += 1 }
            if o.partialAboveReference { partialAbove += 1 }
            if let hit = o.halfwayTop3 { halfway += 1; if hit { halfwayHits += 1 } }
            // Keys a user could skip by picking the reference once it shows in the top three.
            savedKeys += Double(typed - (o.firstTop3Key ?? typed)); keys += typed
            if let failure = o.failure { failures[failure, default: 0] += 1 }
        }
        func percent(_ n: Int, _ d: Int) -> String { d == 0 ? "–" : String(format: "%.1f%%", Double(n) * 100 / Double(d)) }
        var cells: [String] {
            [String(cases), percent(top1, cases), percent(top3, cases), percent(found, cases), percent(partialFirst, cases),
             percent(partialAbove, cases), percent(halfwayHits, halfway),
             keys == 0 ? "–" : String(format: "%.1f%%", savedKeys * 100 / Double(keys))]
        }
    }
    struct Report {
        var tracks: [(name: String, engine: Metrics, model: Metrics, categories: [(String, Metrics, Metrics)])] = []
        var lines: [String] = []
    }

    static func summary(_ rows: [Row], tracks: [String]) -> Report {
        var report = Report()
        for track in tracks {
            let selected = rows.filter { $0.track == track }
            var engine = Metrics(), model = Metrics()
            var categories: [String: (Metrics, Metrics)] = [:]
            var order: [String] = []
            for row in selected {
                engine.add(row.engine, keys: row.romaji.count); model.add(row.languageModel, keys: row.romaji.count)
                if categories[row.category] == nil { order.append(row.category); categories[row.category] = (Metrics(), Metrics()) }
                categories[row.category]!.0.add(row.engine, keys: row.romaji.count)
                categories[row.category]!.1.add(row.languageModel, keys: row.romaji.count)
            }
            report.tracks.append((track, engine, model, order.map { ($0, categories[$0]!.0, categories[$0]!.1) }))
            for (mode, metrics) in [("engine", engine), ("languageModel", model)] {
                report.lines.append("track=\(track) mode=\(mode) cases=\(metrics.cases) top1=\(metrics.top1) top3=\(metrics.top3) "
                    + "partialFirst=\(metrics.partialFirst) partialAbove=\(metrics.partialAbove) "
                    + "halfway=\(metrics.halfwayHits)/\(metrics.halfway) savedKeys=\(Int(metrics.savedKeys))/\(metrics.keys)")
            }
        }
        return report
    }

    static func markdown(_ report: Report, rows: [Row], skipped: [String], model: String, elapsed: TimeInterval) -> String {
        let header = "| 范围 | 模式 | 条数 | top-1 | top-3 | 在列表中 | 首位为部分文节 | 部分文节压过正解 | 半程 top-3 | 可省按键 |\n"
            + "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
        var text = "# 候选质量基准\n\n模型 \(model)，用时 \(Int(elapsed)) 秒，跳过 \(skipped.count) 条。\n\n" + header
        for track in report.tracks {
            text += "| \(track.name) | 词典 | " + track.engine.cells.joined(separator: " | ") + " |\n"
            text += "| \(track.name) | 智能 | " + track.model.cells.joined(separator: " | ") + " |\n"
        }
        for track in report.tracks where track.categories.count > 1 {
            text += "\n## \(track.name) 分类\n\n" + header
            for (category, engine, model) in track.categories {
                text += "| \(category) | 词典 | " + engine.cells.joined(separator: " | ") + " |\n"
                text += "| \(category) | 智能 | " + model.cells.joined(separator: " | ") + " |\n"
            }
        }
        text += "\n## 首位错误原因\n\n| 范围 | 模式 | " + failureKinds.joined(separator: " | ") + " |\n"
            + "| --- | --- |" + String(repeating: " --- |", count: failureKinds.count) + "\n"
        for track in report.tracks {
            for (mode, metrics) in [("词典", track.engine), ("智能", track.model)] {
                text += "| \(track.name) | \(mode) | " + failureKinds.map { String(metrics.failures[$0] ?? 0) }.joined(separator: " | ") + " |\n"
            }
        }
        text += "\n## 首位错误（智能排序）\n\n| 用例 | 读音 | 正解 | 正解名次 | 前五（… 为部分文节） | 原因 |\n| --- | --- | --- | --- | --- | --- |\n"
        for row in rows where row.languageModel.rank != 1 {
            text += "| \(row.id) | \(row.reading) | \(row.accept.joined(separator: "/")) | \(row.languageModel.rank.map(String.init) ?? "–") | "
                + row.languageModel.top.joined(separator: " ") + " | \(row.languageModel.failure ?? "") |\n"
        }
        return text
    }
    static let failureKinds = ["partial_clause", "prediction", "kana_over_kanji", "kanji_over_kana",
                               "homophone_or_segmentation", "missing", "correction"]
}
