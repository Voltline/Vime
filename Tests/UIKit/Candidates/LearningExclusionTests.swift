import XCTest

final class LearningExclusionTests: XCTestCase {
    func testSipHashReferenceVectors() {
        // Key 00…0F from the SipHash paper's reference vectors.
        let k0: UInt64 = 0x0706_0504_0302_0100, k1: UInt64 = 0x0F0E_0D0C_0B0A_0908
        XCTAssertEqual(SipHash24.hash([][...], k0: k0, k1: k1), 0x726F_DB47_DD0E_0E31)
        XCTAssertEqual(SipHash24.hash(Array(0..<15)[...], k0: k0, k1: k1), 0xA129_CA61_49BE_45E5)
        XCTAssertEqual(SipHash24.hash(Array(0..<63)[...], k0: k0, k1: k1), 0x958A_324C_EB06_4572)
    }

    func testHashesAgreeWithBuildScript() {
        // Values printed by Scripts/build_learning_exclusions.py.
        func scriptHash(_ text: String) -> UInt64 {
            var bytes: [UInt8] = []
            for scalar in LearningExclusionList.normalized(text) { UTF8.encode(scalar) { bytes.append($0) } }
            return LearningExclusionList.hash(bytes[...])
        }
        XCTAssertEqual(scriptHash("测试ＡＢＣ"), 0xA874_DB71_9115_4426)
        XCTAssertEqual(scriptHash("vime"), 0xD693_26DE_2746_58B7)
    }

    func testMatchesNormalizedSubstrings() {
        let list = LearningExclusionList(data: LearningExclusionList.encode(blocked: ["红茶", "abc", "四个字的"], allowed: []))
        XCTAssertTrue(list.isAvailable)
        XCTAssertTrue(list.matches("红茶"))
        XCTAssertTrue(list.matches("我想喝红茶了"))
        XCTAssertTrue(list.matches("xＡＢＣx"))
        XCTAssertTrue(list.matches("这是四个字的词"))
        XCTAssertFalse(list.matches("绿茶"))
        XCTAssertFalse(list.matches("ab c"))
        XCTAssertFalse(list.matches(""))
    }

    func testEverydayWordCuttingAShortMatchCancelsIt() {
        let list = LearningExclusionList(data: LearningExclusionList.encode(
            blocked: ["红茶", "茶杯子", "很长的词语"], allowed: ["大红", "杯子们", "长的"]))
        XCTAssertFalse(list.matches("大红茶"), "大红 straddles the start of 红茶")
        XCTAssertTrue(list.matches("大红 红茶"), "a separate occurrence still counts")
        XCTAssertFalse(list.matches("茶杯子们"), "杯子们 straddles the end of 茶杯子")
        XCTAssertTrue(list.matches("很长的词语"), "longer matches are never cancelled")
    }

    func testMalformedDataIsUnavailable() {
        XCTAssertFalse(LearningExclusionList(data: Data()).isAvailable)
        XCTAssertFalse(LearningExclusionList(data: Data("VLX0".utf8) + Data(count: 24)).isAvailable)
        var truncated = LearningExclusionList.encode(blocked: ["红茶"], allowed: [])
        truncated.removeLast()
        XCTAssertFalse(LearningExclusionList(data: truncated).isAvailable)
        XCTAssertFalse(LearningExclusionList(data: Data()).matches("红茶"))
    }

    func testBundledTableLoads() throws {
        // The table is opened from its sealed copy on Xcode Cloud and kept
        // locally; other checkouts build without it.
        try XCTSkipIf(Bundle(for: Self.self).url(forResource: "LearningExclusions", withExtension: "bin") == nil,
                      "LearningExclusions.bin is not in this checkout")
        XCTAssertTrue(LearningExclusionList(bundle: Bundle(for: Self.self)).isAvailable)
        XCTAssertTrue(LearningExclusionList.shared.isAvailable)
        XCTAssertFalse(LearningExclusionList.shared.matches("今天天气很好"))
    }

    func testPolicyPrefersStorefrontOverRegion() {
        XCTAssertTrue(LearningExclusionPolicy.isActive(storefront: "CHN", region: "US"))
        XCTAssertFalse(LearningExclusionPolicy.isActive(storefront: "HKG", region: "CN"))
        XCTAssertFalse(LearningExclusionPolicy.isActive(storefront: "USA", region: "CN"))
        XCTAssertTrue(LearningExclusionPolicy.isActive(storefront: nil, region: "CN"))
        XCTAssertTrue(LearningExclusionPolicy.isActive(storefront: "", region: "cn"))
        XCTAssertFalse(LearningExclusionPolicy.isActive(storefront: nil, region: "TW"))
        XCTAssertFalse(LearningExclusionPolicy.isActive(storefront: nil, region: nil))
    }

    func testPolicyReadsRecordedStorefront() throws {
        let suite = "LearningExclusionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let china = Locale(identifier: "zh_CN"), japan = Locale(identifier: "ja_JP")
        XCTAssertTrue(LearningExclusionPolicy.isActive(defaults: defaults, locale: china))
        XCTAssertFalse(LearningExclusionPolicy.isActive(defaults: defaults, locale: japan))
        defaults.set("JPN", forKey: LearningExclusionPolicy.storefrontKey)
        XCTAssertFalse(LearningExclusionPolicy.isActive(defaults: defaults, locale: china))
        defaults.set("CHN", forKey: LearningExclusionPolicy.storefrontKey)
        XCTAssertTrue(LearningExclusionPolicy.isActive(defaults: defaults, locale: japan))
    }

    func testLearningIsOnlyWithheldWhenActive() {
        let list = LearningExclusionList(data: LearningExclusionList.encode(blocked: ["红茶"], allowed: []))
        XCTAssertFalse(LearningExclusionPolicy.allowsLearning("红茶", active: true, list: list))
        XCTAssertTrue(LearningExclusionPolicy.allowsLearning("红茶", active: false, list: list))
        XCTAssertTrue(LearningExclusionPolicy.allowsLearning("绿茶", active: true, list: list))
    }
}
