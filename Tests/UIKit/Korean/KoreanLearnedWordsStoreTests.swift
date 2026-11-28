import XCTest

final class KoreanLearnedWordsStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KoreanLearnedStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAllWordsSortedByFrequencyAndExportFormat() {
        let store = KoreanPersonalLearningStore(directory: tempDir)
        XCTAssertTrue(store.record(word: "학교"))
        XCTAssertTrue(store.record(word: "친구"))
        XCTAssertTrue(store.record(word: "친구"))
        XCTAssertTrue(store.record(word: "친구"))
        XCTAssertTrue(store.record(word: "시간"))
        XCTAssertTrue(store.record(word: "시간"))
        store.flushSync()

        let words = store.allWords()
        XCTAssertEqual(words.map(\.surface), ["친구", "시간", "학교"])
        XCTAssertEqual(words.map(\.count), [3, 2, 1])

        let exported = String(data: store.exportText(), encoding: .utf8)
        XCTAssertEqual(exported, "친구\t3\n시간\t2\n학교\t1\n")
    }

    func testCrossProcessAppDeletionIsNotOverwrittenByKeyboard() {
        let keyboardStore = KoreanPersonalLearningStore(directory: tempDir)
        XCTAssertTrue(keyboardStore.record(word: "학교"))
        XCTAssertTrue(keyboardStore.record(word: "친구"))
        keyboardStore.flushSync()

        // Ensure a distinct file modification timestamp for the app's write.
        let fileURL = tempDir.appendingPathComponent("KoreanPersonalLearning.json")
        let olderDate = Date().addingTimeInterval(-10)
        try? FileManager.default.setAttributes([.modificationDate: olderDate], ofItemAtPath: fileURL.path)

        // Keyboard loads with older mtime.
        keyboardStore.release()
        XCTAssertEqual(keyboardStore.allWords().count, 2)

        // App process opens the same file and deletes "친구".
        let appStore = KoreanPersonalLearningStore(directory: tempDir)
        appStore.forgetAndPersist(word: "친구")
        XCTAssertEqual(appStore.allWords().map(\.surface), ["학교"])

        // Keyboard resets/reloads: sees the deletion and does not resurrect "친구".
        keyboardStore.reloadIfModified()
        XCTAssertEqual(keyboardStore.allWords().map(\.surface), ["학교"])

        // Keyboard records a new word and flushes: "친구" must stay deleted.
        XCTAssertTrue(keyboardStore.record(word: "시간"))
        keyboardStore.flushSync()

        let reloaded = KoreanPersonalLearningStore(directory: tempDir)
        let surfaces = Set(reloaded.allWords().map(\.surface))
        XCTAssertEqual(surfaces, ["학교", "시간"])
        XCTAssertFalse(surfaces.contains("친구"))
    }

    func testCrossProcessClearAllIsObservedByKeyboard() {
        let keyboardStore = KoreanPersonalLearningStore(directory: tempDir)
        XCTAssertTrue(keyboardStore.record(word: "한국어"))
        keyboardStore.flushSync()
        XCTAssertEqual(keyboardStore.frequency(of: "한국어"), 1)

        let appStore = KoreanPersonalLearningStore(directory: tempDir)
        appStore.clearAllAndPersist()
        XCTAssertFalse(appStore.hasStoredRecords)

        keyboardStore.reloadIfModified()
        XCTAssertEqual(keyboardStore.frequency(of: "한국어"), 0)
        XCTAssertTrue(keyboardStore.allWords().isEmpty)
    }
}
