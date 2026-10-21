import XCTest
@testable import Vime

@MainActor
final class AppOnboardingTests: XCTestCase {
    func testPracticeProgressCountsTheMatchingPrefix() {
        XCTAssertEqual(TypingPractice.matchedCount(typed: "", target: "今日は"), 0)
        XCTAssertEqual(TypingPractice.matchedCount(typed: "今日", target: "今日は"), 2)
        XCTAssertEqual(TypingPractice.matchedCount(typed: "今日が", target: "今日は"), 2)
        XCTAssertEqual(TypingPractice.matchedCount(typed: "  今日は\n", target: "今日は"), 3)
        XCTAssertFalse(TypingPractice.sentences.isEmpty)
    }

    func testSetupProgressReadsAddedKeyboardsAndTheExtensionReport() {
        XCTAssertEqual(KeyboardSetupProgress.load(keyboards: [], status: nil), .init(added: false, fullAccess: false))
        let keyboards = ["en_US@sw=QWERTY", KeyboardSetupProgress.extensionBundleID]
        XCTAssertEqual(KeyboardSetupProgress.load(keyboards: keyboards, status: nil), .init(added: true, fullAccess: false))
        let status = Vime.KeyboardExtensionStatus(lastSeen: Date(), fullAccess: true)
        XCTAssertEqual(KeyboardSetupProgress.load(keyboards: [], status: status), .init(added: true, fullAccess: true))
    }
}
