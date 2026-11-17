import XCTest

final class ChineseUserDictionaryTests: XCTestCase {
    private func store() throws -> ChineseUserDictionaryStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChineseUserDictionaryTests-\(UUID().uuidString)")
        return ChineseUserDictionaryStore(directory: directory,
                                          defaults: try XCTUnwrap(UserDefaults(suiteName: "ChineseUserDictionaryTests-\(UUID().uuidString)")))
    }

    func testPinyinSplitsIntoSyllables() {
        XCTAssertEqual(ChineseUserDictionaryStore.syllables("wei mai"), ["wei", "mai"])
        XCTAssertEqual(ChineseUserDictionaryStore.syllables("WeiMai"), ["wei", "mai"])
        XCTAssertEqual(ChineseUserDictionaryStore.syllables("xi'an"), ["xi", "an"])
        XCTAssertEqual(ChineseUserDictionaryStore.syllables("xian"), ["xian"], "the fewest syllables win")
        XCTAssertEqual(ChineseUserDictionaryStore.syllables("lüse"), ["lv", "se"])
        XCTAssertEqual(ChineseUserDictionaryStore.syllables("nu:"), ["nv"])
        XCTAssertNil(ChineseUserDictionaryStore.syllables(""))
        XCTAssertNil(ChineseUserDictionaryStore.syllables("wei2 mai"))
        XCTAssertNil(ChineseUserDictionaryStore.syllables("vvv"))
        XCTAssertNil(ChineseUserDictionaryStore.syllables(String(repeating: "a ", count: 17)))
    }

    func testPhrasesMatchTheWholeSpellingOrItsInitials() throws {
        let store = try store()
        try store.save([.init(pinyin: "weimai", text: "维麦"), .init(pinyin: "ni", text: "你呢")])
        XCTAssertEqual(try store.entries().map(\.pinyin), ["wei mai", "ni"])
        XCTAssertEqual(store.phrases(spelledBy: "weimai").map(\.text), ["维麦"])
        XCTAssertEqual(store.phrases(spelledBy: "wm").map(\.text), ["维麦"])
        XCTAssertEqual(store.phrases(spelledBy: "ni").map(\.text), ["你呢"])
        XCTAssertEqual(store.phrases(spelledBy: "n"), [], "one syllable has no initials spelling")
        XCTAssertEqual(store.phrases(spelledBy: "wei"), [])
    }

    func testEntriesAreChecked() throws {
        let store = try store()
        XCTAssertThrowsError(try store.save([.init(pinyin: "abc1", text: "词")]))
        XCTAssertThrowsError(try store.save([.init(pinyin: "ci", text: "  ")]))
        XCTAssertThrowsError(try store.save([.init(pinyin: "ci", text: "a\u{7}b")]))
        // The same phrase twice is kept once.
        try store.save([.init(pinyin: "ci yu", text: "词语"), .init(pinyin: "ciyu", text: "词语")])
        XCTAssertEqual(try store.entries().count, 1)
    }

    func testTextImportMergesAndSkipsWhatItCannotUse() throws {
        let store = try store()
        try store.save([.init(pinyin: "ci yu", text: "词语")])
        let text = "# Rime\n维麦\twei mai\t3\n词语\tci yu\n坏行\n数字\tshu4 zi\n"
        let result = try store.importFile(Data(text.utf8))
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(try store.entries().map(\.text), ["词语", "维麦"])
        XCTAssertThrowsError(try store.importFile(Data("坏行\n".utf8)))
        XCTAssertEqual(String(data: try store.exportText(), encoding: .utf8), "词语\tci yu\n维麦\twei mai\n")
    }

    func testJSONExportReadsBack() throws {
        let store = try store(), other = try self.store()
        try store.save([.init(pinyin: "wei mai", text: "维麦")])
        XCTAssertEqual(try other.importFile(try store.exportData()).added, 1)
        XCTAssertEqual(try other.entries(), try store.entries())
        XCTAssertThrowsError(try other.importFile(Data("{\"version\": 2, \"entries\": []}".utf8)))
    }

    func testAnotherStoreSeesSavedChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChineseUserDictionaryTests-\(UUID().uuidString)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChineseUserDictionaryTests-\(UUID().uuidString)"))
        let app = ChineseUserDictionaryStore(directory: directory, defaults: defaults)
        let keyboard = ChineseUserDictionaryStore(directory: directory, defaults: defaults)
        XCTAssertEqual(keyboard.phrases(spelledBy: "wm"), [])
        try app.save([.init(pinyin: "wei mai", text: "维麦")])
        XCTAssertEqual(keyboard.phrases(spelledBy: "wm").map(\.text), ["维麦"])
    }
}
