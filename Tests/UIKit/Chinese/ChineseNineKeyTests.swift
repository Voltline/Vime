import XCTest

final class NineKeyPinyinTests: XCTestCase {
    func testDigits() {
        XCTAssertEqual(NineKeyPinyin.digits(for: "nihao"), "64426")
        XCTAssertEqual(NineKeyPinyin.digits(for: "zhongguo"), "94664486")
        XCTAssertEqual(NineKeyPinyin.digits(for: "lü"), "58")
    }

    func testSegments() {
        XCTAssertEqual(NineKeyPinyin.segments("xiong'486"), [.letters("xiong"), .digits("486")])
        XCTAssertEqual(NineKeyPinyin.segments("64'426"), [.digits("64"), .digits("426")])
        XCTAssertEqual(NineKeyPinyin.segments("xiong'"), [.letters("xiong")])
    }

    func testReadingFollowsTheHint() {
        XCTAssertEqual(NineKeyPinyin.reading(of: "64426", hint: "ni hao"), ["ni", "hao"])
        // A syllable still being typed shows as far as it goes.
        XCTAssertEqual(NineKeyPinyin.reading(of: "6442", hint: "ni hao"), ["ni", "ha"])
        // An abbreviation shows the initials.
        XCTAssertEqual(NineKeyPinyin.reading(of: "94", hint: "zhong guo"), ["z", "g"])
        XCTAssertEqual(NineKeyPinyin.reading(of: "xiong'486", hint: "xiong hun"), ["xiong", "hun"])
        // Digits the hint does not spell stay as typed.
        XCTAssertEqual(NineKeyPinyin.reading(of: "64426", hint: "ni"), ["ni", "426"])
        XCTAssertEqual(NineKeyPinyin.reading(of: "64", hint: nil), ["64"])
        XCTAssertEqual(NineKeyPinyin.letters(of: "64426", hint: "ni hao"), "nihao")
    }

    func testOptions() {
        let options = NineKeyPinyin.options(for: "64426")
        XCTAssertEqual(Array(options.prefix(2)), ["ni", "mi"])
        XCTAssertTrue(options.contains("o"))
        XCTAssertTrue(options.contains("m") && options.contains("n"), "initials for an abbreviation")
        XCTAssertFalse(options.contains("ng"), "a syllable has a vowel")
        XCTAssertEqual(NineKeyPinyin.options(for: "64426", preferring: "mi").first, "mi")
        XCTAssertEqual(NineKeyPinyin.options(for: "744").prefix(1), ["shi"])
        XCTAssertEqual(NineKeyPinyin.options(for: ""), [])
    }

    func testPickingAndUnpicking() {
        XCTAssertEqual(NineKeyPinyin.input("94664486", picking: "xiong"), "xiong'486")
        XCTAssertEqual(NineKeyPinyin.input("xiong'486", picking: "gu"), "xiong'gu'6")
        XCTAssertEqual(NineKeyPinyin.input("64", picking: "ni"), "ni'")
        XCTAssertNil(NineKeyPinyin.input("64", picking: "hao"))
        XCTAssertEqual(NineKeyPinyin.unpickingLast("ni'"), "64")
        XCTAssertEqual(NineKeyPinyin.unpickingLast("xiong'gu'"), "xiong'48")
        XCTAssertNil(NineKeyPinyin.unpickingLast("xiong'486"))
        XCTAssertNil(NineKeyPinyin.unpickingLast("64'"))
    }
}

@MainActor
final class ChineseNineKeySessionTests: XCTestCase {
    private static let user = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChineseNineKeySessionTests-\(UUID().uuidString)")
    private var batches: [KeyboardCommitBatch] = []

    private func session() throws -> ChineseInputSession {
        let data = try XCTUnwrap(RimeEngine.bundledData, "RimeData.bundle is not bundled")
        let session = ChineseInputSession(engine: RimeEngine(data: data, userDirectory: Self.user))
        session.onCommittedEdits = { [weak self] in self?.batches.append($0) }
        session.setChineseLanguageModel(false)
        session.setChineseLayout(.nineKey)
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

    func testDigitsComposeAndShowPinyin() throws {
        let session = try session()
        _ = session.type("6")
        _ = session.type("4426")
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "64426")
        XCTAssertEqual(session.candidatePresentations.first?.text, "你好")
        XCTAssertEqual(session.markedText?.text, "ni" + ChineseInputSession.syllableGap + "hao")
        XCTAssertNil(session.candidatePresentations.first?.detailAnnotation, "no pinyin over the candidates")
        XCTAssertEqual(session.leadingSyllables.first, "ni")
        XCTAssertEqual(session.currentLeadingSyllable, "ni")
    }

    func testReturnCommitsThePinyin() throws {
        let session = try session()
        _ = session.type("64426")
        waitUntilCurrent(session)
        XCTAssertEqual(session.enter(), [.insert("nihao")])
        XCTAssertFalse(session.isComposing)
    }

    func testPickedSyllableNarrowsAndBackspaceTakesItBack() throws {
        let session = try session()
        _ = session.type("94664486")
        waitUntilCurrent(session)
        XCTAssertTrue(session.leadingSyllables.contains("xiong"))
        XCTAssertEqual(session.chooseLeadingSyllable("xiong"), [])
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "xiong'486")
        XCTAssertTrue(session.markedText?.text.hasPrefix("xiong") == true)
        XCTAssertFalse(session.candidatePresentations.prefix(5).contains { $0.text == "中国" })
        XCTAssertFalse(session.candidatePresentations.contains { ["中", "种", "印尼"].contains($0.text) },
                       "nothing past the first rows still reads the digits another way")
        XCTAssertTrue(session.leadingSyllables.contains("gu"), "the rail moves on to the next digits")
        for _ in 0..<3 { _ = session.backspace() }
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw.filter { $0 != "'" }, "xiong")
        _ = session.backspace()
        waitUntilCurrent(session)
        XCTAssertEqual(session.raw, "94664", "the pick goes back to its digits")
    }

    func testFullPinyinAgain() throws {
        let session = try session()
        session.setChineseLayout(.fullPinyin)
        _ = session.type("nihao")
        waitUntilCurrent(session)
        XCTAssertEqual(session.candidatePresentations.first?.text, "你好")
        XCTAssertEqual(session.markedText?.text, "ni" + ChineseInputSession.syllableGap + "hao")
        XCTAssertEqual(session.insertLiteral("6").last, .insert("6"), "digits are not pinyin")
    }
}
