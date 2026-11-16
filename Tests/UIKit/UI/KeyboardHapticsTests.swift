import UIKit
import XCTest

@MainActor
final class KeyboardHapticsTests: XCTestCase {
    private final class Recorder: KeyboardHaptics.Generator {
        enum Call: Equatable { case prepare, impact(CGFloat) }
        var calls: [Call] = []
        func prepare() { calls.append(.prepare) }
        func impactOccurred(intensity: CGFloat) { calls.append(.impact(intensity)) }
        var impacts: Int { calls.filter { $0 != .prepare }.count }
    }

    private var made: [Recorder] = []
    private func haptics() -> KeyboardHaptics {
        KeyboardHaptics { [unowned self] in
            let recorder = Recorder()
            self.made.append(recorder)
            return recorder
        }
    }

    func testLongTypingNeverPreparesAfterAnImpact() {
        let haptics = haptics()
        haptics.prepare()
        for _ in 0..<1_000 { haptics.play(intensity: 0.6) }
        XCTAssertEqual(made.reduce(0) { $0 + $1.impacts }, 1_000)
        for recorder in made {
            // A prepare after an impact leaks a Core Haptics player channel.
            if let firstImpact = recorder.calls.firstIndex(where: { $0 != .prepare }) {
                XCTAssertFalse(recorder.calls[firstImpact...].contains(.prepare))
            }
        }
        XCTAssertEqual(made.first?.calls.first, .prepare, "the keyboard warms the engine before typing")
    }

    func testGeneratorIsReplacedBeforeChannelsRunOut() {
        let haptics = haptics()
        for _ in 0..<1_000 { haptics.play(intensity: 1) }
        XCTAssertGreaterThan(made.count, 1)
        XCTAssertTrue(made.allSatisfy { $0.impacts <= KeyboardHaptics.impactsPerGenerator })
    }

    func testZeroIntensityPlaysNothing() {
        let haptics = haptics()
        haptics.play(intensity: 0)
        XCTAssertTrue(made.isEmpty)
        haptics.play(intensity: 1.5)
        XCTAssertEqual(made.last?.calls, [.impact(1)])
    }

    func testReleaseStartsANewGenerator() {
        let haptics = haptics()
        haptics.play(intensity: 0.5)
        haptics.release()
        haptics.play(intensity: 0.5)
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made.map(\.impacts), [1, 1])
    }
}
