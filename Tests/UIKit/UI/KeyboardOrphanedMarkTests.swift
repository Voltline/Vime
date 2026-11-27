import XCTest

@MainActor
final class KeyboardOrphanedMarkTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "KeyboardOrphanedMarkTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testLeftoverIsClearedInTheNextProcess() {
        KeyboardOrphanedMark(defaults: defaults).record()
        // The extension was ended while hidden: a fresh instance still knows.
        let next = KeyboardOrphanedMark(defaults: defaults)
        XCTAssertFalse(next.shouldClear(hasComposition: false, selectedText: nil), "not before the keyboard shows")
        next.beginShowing()
        XCTAssertTrue(next.shouldClear(hasComposition: false, selectedText: nil))
        XCTAssertTrue(next.shouldClear(hasComposition: false, selectedText: ""))
        next.noteCleared()
        XCTAssertTrue(next.shouldClear(hasComposition: false, selectedText: nil), "retries while the context may still be arriving")
        next.finishShowing()
        XCTAssertFalse(next.isRecorded)
        next.beginShowing()
        XCTAssertFalse(next.shouldClear(hasComposition: false, selectedText: nil), "one leftover is cleared once")
    }

    func testNeverClearsOverASelectionOrNewInput() {
        let mark = KeyboardOrphanedMark(defaults: defaults)
        mark.record()
        mark.beginShowing()
        XCTAssertFalse(mark.shouldClear(hasComposition: false, selectedText: "选中"), "an empty mark would delete the selection")
        XCTAssertFalse(mark.shouldClear(hasComposition: true, selectedText: nil), "the keyboard's own composition stays")
        mark.cancel()
        XCTAssertFalse(mark.isRecorded, "typing replaces the leftover")
        XCTAssertFalse(mark.shouldClear(hasComposition: false, selectedText: nil))
    }

    func testFlagStaysWhenNoClearCouldBeSent() {
        let mark = KeyboardOrphanedMark(defaults: defaults)
        mark.record()
        mark.beginShowing()
        mark.finishShowing()
        XCTAssertTrue(mark.isRecorded, "the next showing tries again")
    }

    func testNewLeftoverOutlivesTheShowingsLastRetry() {
        let mark = KeyboardOrphanedMark(defaults: defaults)
        mark.record()
        mark.beginShowing()
        mark.noteCleared()
        // Dismissed again with a fresh preedit before the last retry ran.
        mark.record()
        mark.finishShowing()
        XCTAssertTrue(mark.isRecorded)
    }
}
