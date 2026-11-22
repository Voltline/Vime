import XCTest

final class ShuangpinSchemeTests: XCTestCase {
    func testCodes() {
        let flypy = ShuangpinScheme.flypy
        XCTAssertEqual(flypy.code(for: "ni"), "ni")
        XCTAssertEqual(flypy.code(for: "hao"), "hc")
        XCTAssertEqual(flypy.code(for: "zhuang"), "vl")
        XCTAssertEqual(flypy.code(for: "shi"), "ui")
        XCTAssertEqual(flypy.code(for: "lve"), "lt")
        XCTAssertEqual(flypy.code(for: "a"), "aa")
        XCTAssertEqual(flypy.code(for: "ang"), "ah")
        XCTAssertEqual(flypy.code(for: "ou"), "ou")
        XCTAssertEqual(ShuangpinScheme.ziranma.code(for: "hao"), "hk")
        XCTAssertEqual(ShuangpinScheme.ziranma.code(for: "xiang"), "xd")
    }

    func testEverySyllableHasItsOwnCode() {
        for scheme in ShuangpinScheme.allCases {
            for syllable in PinyinSpellingCorrection.syllables where syllable.contains(where: { "aeiouv".contains($0) }) {
                let code = scheme.code(for: syllable)
                XCTAssertEqual(code?.count, 2, "\(scheme) \(syllable)")
                if let code, syllable != "lo" { XCTAssertEqual(scheme.syllable(for: code), syllable, "\(scheme) \(code)") }
            }
        }
    }

    func testReadings() {
        let flypy = ShuangpinScheme.flypy
        XCTAssertEqual(flypy.readings(ofPreedit: "ni hc"), ["ni", "hao"])
        XCTAssertEqual(flypy.readings(ofPreedit: "vs g"), ["zhong", "g"])
        XCTAssertEqual(flypy.readings(ofPreedit: "u"), ["sh"])
        XCTAssertEqual(flypy.pinyin(ofKeys: "nihc"), "nihao")
        XCTAssertEqual(flypy.pinyin(ofKeys: "nih"), "nih")
        XCTAssertNil(flypy.pinyin(ofKeys: "bz"), "no syllable")
    }

    func testKeyHints() {
        let hints = ShuangpinScheme.flypy.keyHints
        XCTAssertEqual(hints["v"], "zh ui")
        XCTAssertEqual(hints["k"], "ing uai")
        XCTAssertEqual(hints["t"], "ue")
        XCTAssertNil(hints["a"])
        XCTAssertEqual(ShuangpinScheme.ziranma.keyHints["d"], "iang uang")
        XCTAssertEqual(hints["s"], "ong iong")
    }
}

@MainActor
final class ChineseShuangpinSessionTests: XCTestCase {
    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChineseShuangpinSessionTests-\(UUID().uuidString)")

    private func session(_ scheme: ShuangpinScheme = .flypy) throws -> ChineseInputSession {
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user))
        session.setChineseLanguageModel(false)
        session.setChineseLayout(.shuangpin, shuangpin: scheme)
        return session
    }

    private func waitUntilCurrent(_ session: ChineseInputSession, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while !session.candidatesAreCurrent && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertTrue(session.candidatesAreCurrent, "Rime did not answer", file: file, line: line)
    }

    func testKeysComposeAndShowPinyin() throws {
        let session = try session()
        _ = session.type("nihc")
        waitUntilCurrent(session)
        XCTAssertEqual(session.candidatePresentations.first?.text, "你好")
        XCTAssertEqual(session.markedText?.text, "ni" + ChineseInputSession.syllableGap + "hao")
        XCTAssertEqual(session.leadingSyllables, [], "no syllable column")
        XCTAssertEqual(session.enter(), [.insert("nihao")], "Return commits the pinyin")
        XCTAssertFalse(session.isComposing)
    }

    func testALoneKeyShowsItsInitial() throws {
        let session = try session()
        _ = session.type("vsu")
        waitUntilCurrent(session)
        XCTAssertEqual(session.markedText?.text, "zhong" + ChineseInputSession.syllableGap + "sh")
    }

    func testVTypesZhNotNumbers() throws {
        let session = try session()
        _ = session.type("v")
        _ = session.type("1")
        waitUntilCurrent(session)
        XCTAssertFalse(session.acceptsCompositionSymbol("1"))
        _ = session.type("vsgo")
        waitUntilCurrent(session)
        XCTAssertTrue(session.candidatePresentations.prefix(3).contains { $0.text == "中国" })
    }

    func testZiranma() throws {
        let session = try session(.ziranma)
        _ = session.type("nihk")
        waitUntilCurrent(session)
        XCTAssertEqual(session.candidatePresentations.first?.text, "你好")
        XCTAssertEqual(session.markedText?.text, "ni" + ChineseInputSession.syllableGap + "hao")
    }

    func testFullPinyinAgain() throws {
        let session = try session()
        session.setChineseLayout(.fullPinyin)
        _ = session.type("nihao")
        waitUntilCurrent(session)
        XCTAssertEqual(session.candidatePresentations.first?.text, "你好")
    }
}
