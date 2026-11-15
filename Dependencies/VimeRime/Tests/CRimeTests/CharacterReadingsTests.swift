import CRime
import Foundation
import XCTest

/// Single-character readings read straight from the prebuilt pinyin table.
final class CharacterReadingsTests: XCTestCase {
    static let table = RimeSmokeTests.data.appendingPathComponent("vime_pinyin.table.bin")

    private func readings() throws -> [String: Set<String>] {
        let raw = try XCTUnwrap(vime_rime_character_readings(Self.table.path))
        defer { vime_rime_string_free(raw) }
        var result: [String: Set<String>] = [:]
        for line in String(cString: raw).split(separator: "\n") {
            let parts = line.split(separator: "\t")
            XCTAssertEqual(parts.count, 2, String(line))
            result[String(parts[0]), default: []].insert(String(parts[1]))
        }
        return result
    }

    func testCharactersCarryEveryReading() throws {
        let readings = try readings()
        XCTAssertGreaterThan(readings.count, 8000)
        XCTAssertEqual(readings["中"], ["zhong"])
        XCTAssertTrue(readings["行"]?.isSuperset(of: ["xing", "hang"]) ?? false)
        XCTAssertTrue(readings["长"]?.isSuperset(of: ["chang", "zhang"]) ?? false)
        XCTAssertTrue(readings.keys.allSatisfy { $0.unicodeScalars.count == 1 })
    }

    func testAMissingTableGivesNothing() {
        XCTAssertNil(vime_rime_character_readings("/nonexistent/table.bin"))
    }
}
