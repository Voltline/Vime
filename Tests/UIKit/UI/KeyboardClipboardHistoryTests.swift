import XCTest
import UIKit

@MainActor
final class KeyboardClipboardHistoryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(_ value: String?, version: Int, in store: ClipboardHistoryStore,
                        at date: Date) async throws -> Bool {
        let reads = try await store.beginRead(version: version, boot: "test-boot", at: date)
        guard reads else { return false }
        return try await store.record(value, version: version, boot: "test-boot", at: date)
    }

    func testOnlyAdjacentEqualTextIsSuppressedAndHistoryMergesRepeatedText() async throws {
        let store = ClipboardHistoryStore(inMemory: true)
        var offers: [Bool] = []
        for (index, text) in ["A", "A", "B", "A"].enumerated() {
            offers.append(try await record(text, version: index, in: store, at: date.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(offers, [true, false, true, true])
        let entries = try await store.entries(at: date.addingTimeInterval(4))
        XCTAssertEqual(entries.map(\.text), ["A", "B"])
        XCTAssertEqual(entries.first?.capturedAt, date.addingTimeInterval(3))
    }

    func testReadAttemptsAndLastTextPersistAcrossSeparateDatabaseConnections() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ClipboardHistoryStore(directory: directory)
        let value = " hello 👩🏽‍💻\n二行目\t \0end"
        let offered = try await record(value, version: 12, in: first, at: date)
        XCTAssertTrue(offered)
        let second = ClipboardHistoryStore(directory: directory)
        let repeatsVersion = try await second.beginRead(version: 12, boot: "test-boot", at: date)
        XCTAssertFalse(repeatsVersion)
        let repeatsText = try await record(value, version: 13, in: second, at: date)
        XCTAssertFalse(repeatsText)
        let entries = try await second.entries(at: date)
        XCTAssertEqual(entries.map(\.text), [value])
        let backup = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(backup.isExcludedFromBackup, true)
        let rebootRead = try await second.beginRead(version: 13, boot: "another-boot", at: date)
        XCTAssertTrue(rebootRead, "A reboot may reuse the pasteboard counter")
    }

    func testDeniedReadIsNotRetriedAcrossInstancesAndConcurrentClaimsReadOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ClipboardHistoryStore(directory: directory), second = ClipboardHistoryStore(directory: directory)
        async let a = first.beginRead(version: 2, boot: "test-boot", at: date)
        async let b = second.beginRead(version: 2, boot: "test-boot", at: date)
        let claims = try await [a, b]
        XCTAssertEqual(claims.filter { $0 }.count, 1)
        let empty = try await first.record(nil, version: 2, boot: "test-boot", at: date)
        XCTAssertFalse(empty)
        let third = ClipboardHistoryStore(directory: directory)
        let repeated = try await third.beginRead(version: 2, boot: "test-boot", at: date)
        XCTAssertFalse(repeated)
    }

    func testExpiryDeletesTextAndStaleSelectionWhileClearPreservesReadMarker() async throws {
        let store = ClipboardHistoryStore(inMemory: true)
        _ = try await record("expired", version: 1, in: store, at: date)
        let old = try await store.entries(at: date)
        let later = date.addingTimeInterval(ClipboardHistoryStore.lifetime)
        let entries = try await store.entries(at: later)
        XCTAssertTrue(entries.isEmpty)
        let selected = try await store.text(for: try XCTUnwrap(old.first).id, at: later)
        XCTAssertNil(selected)
        let sameAfterExpiry = try await record("expired", version: 99, in: store, at: later)
        XCTAssertFalse(sameAfterExpiry, "Expiring history must not change the adjacent-text rule")
        _ = try await record("current", version: 2, in: store, at: later)
        try await store.clear()
        let cleared = try await store.entries(at: later)
        XCTAssertTrue(cleared.isEmpty)
        let readsAgain = try await store.beginRead(version: 2, boot: "test-boot", at: later)
        XCTAssertFalse(readsAgain)
        let sameAfterClear = try await record("current", version: 3, in: store, at: later)
        XCTAssertFalse(sameAfterClear)
        try await store.clear(includingReadState: true)
        let freshOptIn = try await record("current", version: 3, in: store, at: later)
        XCTAssertTrue(freshOptIn)
    }

    func testHistoryIsBoundedByCountAndUTF8BytesAndKeepsNewestEntries() async throws {
        let store = ClipboardHistoryStore(inMemory: true)
        for index in 0..<110 {
            _ = try await record("item \(index)", version: index, in: store, at: date.addingTimeInterval(Double(index)))
        }
        var entries = try await store.entries(at: date.addingTimeInterval(120))
        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(entries.first?.text, "item 109")
        XCTAssertEqual(entries.last?.text, "item 10")
        for index in 0..<20 {
            let value = "\(index) " + String(repeating: "あ", count: 21_800)
            _ = try await record(value, version: 200 + index, in: store, at: date.addingTimeInterval(Double(200 + index)))
        }
        entries = try await store.entries(at: date.addingTimeInterval(230))
        XCTAssertLessThanOrEqual(entries.reduce(0) { $0 + $1.text.utf8.count }, ClipboardHistoryStore.maximumTotalBytes)
        XCTAssertLessThanOrEqual(entries.count, 100)
        XCTAssertTrue(entries.first?.text.hasPrefix("19 ") == true)
        XCTAssertTrue(entries.allSatisfy { $0.text.hasPrefix("item") == false })
        XCTAssertFalse(ClipboardHistoryStore.accepts(String(repeating: "あ", count: 30_000)))
        XCTAssertFalse(ClipboardHistoryStore.accepts(" \n\t "))
    }

    func testMonitorDoesNotReofferAfterHideOrRecreationButAllowsAThenBThenA() async throws {
        let history = ClipboardHistoryStore(inMemory: true)
        var version = 1, value = "A", reads = 0
        func monitor() -> KeyboardClipboard {
            KeyboardClipboard(changeCount: { version }, readText: { reads += 1; return value }, history: history)
        }
        let first = monitor()
        first.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(first)
        XCTAssertEqual(first.text, "A")
        first.clear()
        first.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(first)
        XCTAssertNil(first.text); XCTAssertEqual(reads, 1)
        let next = monitor()
        next.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(next)
        XCTAssertNil(next.text); XCTAssertEqual(reads, 1)
        version += 1
        next.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(next)
        XCTAssertNil(next.text); XCTAssertEqual(reads, 2)
        for text in ["B", "A"] {
            version += 1; value = text
            next.checkForChanges(enabled: true, hasFullAccess: true)
            await settle(next)
            XCTAssertEqual(next.text, text)
        }
        let entries = try await history.entries()
        XCTAssertEqual(entries.map(\.text), ["A", "B"])
    }

    func testDisablingErasesHistoryAndCancelledTextCannotReturnAfterOptOut() async throws {
        let history = ClipboardHistoryStore(inMemory: true)
        var version = 1
        let first = KeyboardClipboard(changeCount: { version }, readText: { "saved" }, history: history)
        first.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(first)
        let before = try await history.entries()
        XCTAssertEqual(before.map(\.text), ["saved"])
        var completions: [(String?) -> Void] = []
        version += 1
        let pending = KeyboardClipboard(changeCount: { version }, loadText: { completions.append($0); return Progress(totalUnitCount: 1) }, history: history)
        pending.checkForChanges(enabled: true, hasFullAccess: true)
        var deadline = Date().addingTimeInterval(3)
        while completions.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(completions.count, 1)
        guard completions.count == 1 else { return }
        pending.disable()
        completions[0]("late sensitive text")
        await settle(pending)
        XCTAssertNil(pending.text)
        // Re-enabling the same instance waits for the asynchronous erasure.
        pending.checkForChanges(enabled: true, hasFullAccess: true)
        deadline = Date().addingTimeInterval(3)
        while completions.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(completions.count, 2)
        guard completions.count == 2 else { return }
        completions[1]("new opt-in")
        await settle(pending)
        XCTAssertEqual(pending.text, "new opt-in")
        let after = try await history.entries()
        XCTAssertEqual(after.map(\.text), ["new opt-in"])
    }

    func testChangeDuringSlowLoadReadsNewestWithoutAnotherEvent() async throws {
        var version = 1
        var completions: [(String?) -> Void] = []
        let history = ClipboardHistoryStore(inMemory: true)
        let clipboard = KeyboardClipboard(changeCount: { version }, loadText: {
            completions.append($0); return Progress(totalUnitCount: 1)
        }, history: history)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        var deadline = Date().addingTimeInterval(3)
        while completions.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(completions.count, 1)
        guard completions.count == 1 else { return }
        version = 2
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        version = 3
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        completions[0]("obsolete")
        deadline = Date().addingTimeInterval(3)
        while completions.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(completions.count, 2)
        guard completions.count == 2 else { return }
        completions[1]("latest")
        await settle(clipboard)
        XCTAssertEqual(clipboard.text, "latest")
        let entries = try await history.entries()
        XCTAssertEqual(entries.map(\.text), ["latest"])
    }

    func testHidingDropsQueuedChangeDuringSlowLoad() async throws {
        var version = 1
        var completions: [(String?) -> Void] = []
        let clipboard = KeyboardClipboard(changeCount: { version }, loadText: {
            completions.append($0); return Progress(totalUnitCount: 1)
        }, history: ClipboardHistoryStore(inMemory: true))
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        let deadline = Date().addingTimeInterval(3)
        while completions.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard completions.count == 1 else { XCTFail("Read did not start"); return }
        version = 2
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        clipboard.clear()
        completions[0]("late")
        await settle(clipboard)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(clipboard.text)
    }

    func testPreviewExpiresWithoutAnotherCheckAndRetainsHistory() async throws {
        let history = ClipboardHistoryStore(inMemory: true)
        var reads = 0
        let clipboard = KeyboardClipboard(changeCount: { 1 }, loadText: { complete in
            reads += 1; complete("keep in history"); return nil
        }, history: history, previewLifetime: 0.15)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        XCTAssertEqual(clipboard.text, "keep in history")
        let deadline = Date().addingTimeInterval(3)
        while clipboard.text != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(clipboard.text)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        XCTAssertNil(clipboard.text)
        XCTAssertEqual(reads, 1, "A timed-out suggestion must not be rearmed by the unchanged clipboard")
        let entries = try await history.entries()
        XCTAssertEqual(entries.map(\.text), ["keep in history"])
    }

    func testRepeatedChecksDoNotExtendDeadlineAndNewValueGetsThirtySeconds() async throws {
        var time = date, version = 1, value = "first"
        let clipboard = KeyboardClipboard(changeCount: { version }, loadText: { complete in complete(value); return nil },
            history: ClipboardHistoryStore(inMemory: true), now: { time })
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        time = date.addingTimeInterval(29)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        XCTAssertEqual(clipboard.text, "first")
        time = date.addingTimeInterval(30)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        XCTAssertNil(clipboard.text, "Also enforce the deadline after suspension, before the expiry task can run")
        version = 2; value = "second"
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        await settle(clipboard)
        time = date.addingTimeInterval(59)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        XCTAssertEqual(clipboard.text, "second")
        time = date.addingTimeInterval(60)
        clipboard.checkForChanges(enabled: true, hasFullAccess: true)
        XCTAssertNil(clipboard.text)
    }

    private func settle(_ clipboard: KeyboardClipboard) async {
        let deadline = Date().addingTimeInterval(3)
        while clipboard.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(clipboard.isLoading)
    }
}
