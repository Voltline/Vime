import XCTest

final class HangulComposerTests: XCTestCase {
    func testBasicSyllableComposition() {
        var c = HangulComposer()
        XCTAssertTrue(c.input("ㅎ"))
        XCTAssertEqual(c.text, "ㅎ")
        XCTAssertTrue(c.input("ㅏ"))
        XCTAssertEqual(c.text, "하")
        XCTAssertTrue(c.input("ㄴ"))
        XCTAssertEqual(c.text, "한")
        XCTAssertTrue(c.input("ㄱ"))
        XCTAssertEqual(c.text, "한ㄱ")
        XCTAssertTrue(c.input("ㅡ"))
        XCTAssertEqual(c.text, "한그")
        XCTAssertTrue(c.input("ㄹ"))
        XCTAssertEqual(c.text, "한글")
    }

    func testAllSevenCompoundVowels() {
        let cases: [(Character, Character, String)] = [
            ("ㅗ", "ㅏ", "와"),
            ("ㅗ", "ㅐ", "왜"),
            ("ㅗ", "ㅣ", "외"),
            ("ㅜ", "ㅓ", "워"),
            ("ㅜ", "ㅔ", "웨"),
            ("ㅜ", "ㅣ", "위"),
            ("ㅡ", "ㅣ", "의")
        ]
        for (v1, v2, expected) in cases {
            var c = HangulComposer()
            c.input("ㅇ")
            c.input(v1)
            c.input(v2)
            XCTAssertEqual(c.text, expected, "Failed compound vowel \(v1)+\(v2)")
            // Backspace unrolls compound vowel to first vowel, then initial consonant.
            XCTAssertTrue(c.backspace())
            XCTAssertEqual(c.text, String(HangulComposer.compose(cho: 11, jung: HangulComposer.jungseongIndex[v1]!, jong: 0)))
            XCTAssertTrue(c.backspace())
            XCTAssertEqual(c.text, "ㅇ")
            XCTAssertTrue(c.backspace())
            XCTAssertEqual(c.text, "")
        }
    }

    func testAllElevenCompoundJongseong() {
        let cases: [(Character, Character, String, String)] = [
            ("ㄱ", "ㅅ", "갃", "각사"),
            ("ㄴ", "ㅈ", "앉", "안자"),
            ("ㄴ", "ㅎ", "않", "안하"),
            ("ㄹ", "ㄱ", "닭", "달가"),
            ("ㄹ", "ㅁ", "삶", "살마"),
            ("ㄹ", "ㅂ", "밟", "발바"),
            ("ㄹ", "ㅅ", "갌", "갈사"),
            ("ㄹ", "ㅌ", "핥", "할타"),
            ("ㄹ", "ㅍ", "읊", "을파"),
            ("ㄹ", "ㅎ", "앓", "알하"),
            ("ㅂ", "ㅅ", "값", "갑사")
        ]
        let choFor: [String: Character] = [
            "갃": "ㄱ", "앉": "ㅇ", "않": "ㅇ", "닭": "ㄷ", "삶": "ㅅ",
            "밟": "ㅂ", "갌": "ㄱ", "핥": "ㅎ", "읊": "ㅇ", "앓": "ㅇ", "값": "ㄱ"
        ]
        let jungFor: [String: Character] = [
            "갃": "ㅏ", "앉": "ㅏ", "않": "ㅏ", "닭": "ㅏ", "삶": "ㅏ",
            "밟": "ㅏ", "갌": "ㅏ", "핥": "ㅏ", "읊": "ㅡ", "앓": "ㅏ", "값": "ㅏ"
        ]
        for (j1, j2, compound, splitWithA) in cases {
            var c = HangulComposer()
            c.input(choFor[compound]!)
            c.input(jungFor[compound]!)
            c.input(j1)
            c.input(j2)
            XCTAssertEqual(c.text, compound, "Failed compound jongseong \(j1)+\(j2)")
            // Adding ㅏ splits the compound jongseong into first jong + second cho+ㅏ.
            c.input("ㅏ")
            XCTAssertEqual(c.text, splitWithA, "Failed compound jongseong split for \(compound)+ㅏ")
        }
    }

    func testSimpleJongseongSpilloverAndDoubleConsonantRestrictions() {
        var c = HangulComposer()
        XCTAssertTrue(c.input(string: "ㄱㅏㄱㅏ"))
        XCTAssertEqual(c.text, "가가")

        // ㄸ, ㅃ, ㅉ cannot be jongseong; they start the next syllable.
        for nonJong: Character in ["ㄸ", "ㅃ", "ㅉ"] {
            var c2 = HangulComposer()
            c2.input("ㄱ")
            c2.input("ㅏ")
            c2.input(nonJong)
            XCTAssertEqual(c2.text, "가\(nonJong)")
            c2.input("ㅏ")
            let expectedSecond = HangulComposer.compose(cho: HangulComposer.choseongIndex[nonJong]!, jung: 0, jong: 0)
            XCTAssertEqual(c2.text, "가\(expectedSecond)")
        }
    }

    func testBackspaceJamoByJamoAndCompletedSyllable() {
        var c = HangulComposer()
        XCTAssertTrue(c.input(string: "ㄷㅏㄹㄱ"))
        XCTAssertEqual(c.text, "닭")
        XCTAssertTrue(c.backspace())
        XCTAssertEqual(c.text, "달")
        XCTAssertTrue(c.backspace())
        XCTAssertEqual(c.text, "다")
        XCTAssertTrue(c.backspace())
        XCTAssertEqual(c.text, "ㄷ")
        XCTAssertTrue(c.backspace())
        XCTAssertEqual(c.text, "")
        XCTAssertFalse(c.backspace())

        // Earlier completed syllables in a word delete whole syllable at a time.
        XCTAssertTrue(c.input(string: "ㅎㅏㄴㄱㅡㄹ"))
        XCTAssertEqual(c.text, "한글")
        XCTAssertTrue(c.backspace()); XCTAssertEqual(c.text, "한그")
        XCTAssertTrue(c.backspace()); XCTAssertEqual(c.text, "한ㄱ")
        XCTAssertTrue(c.backspace()); XCTAssertEqual(c.text, "한")
        XCTAssertTrue(c.backspace()); XCTAssertEqual(c.text, "")
    }

    func testStandaloneLettersAndUnicodeRanges() {
        var c = HangulComposer()
        c.input("ㄱ")
        XCTAssertEqual(c.text, "ㄱ")
        XCTAssertEqual(c.text.unicodeScalars.first?.value, 0x3131)
        // Non-combining consonant pair stays separate.
        c.input("ㄱ")
        XCTAssertEqual(c.text, "ㄱㄱ")

        // Verified against iOS system Korean 2-Set: standalone consonants stay separate (ㄱ+ㅅ -> ㄱㅅ, ㄹ+ㄱ -> ㄹㄱ).
        var cc = HangulComposer()
        cc.input("ㄱ"); cc.input("ㅅ")
        XCTAssertEqual(cc.text, "ㄱㅅ")
        XCTAssertTrue(cc.text.unicodeScalars.allSatisfy { HangulComposer.isCompatibilityJamo($0) })
        XCTAssertTrue(cc.backspace()); XCTAssertEqual(cc.text, "ㄱ")
        XCTAssertTrue(cc.backspace()); XCTAssertEqual(cc.text, "")

        var split = HangulComposer()
        split.input("ㄹ"); split.input("ㄱ")
        XCTAssertEqual(split.text, "ㄹㄱ")
        split.input("ㅏ")
        XCTAssertEqual(split.text, "ㄹ가")
        XCTAssertTrue(split.backspace()); XCTAssertEqual(split.text, "ㄹㄱ")
        XCTAssertTrue(split.backspace()); XCTAssertEqual(split.text, "ㄹ")

        // Verified against iOS system Korean 2-Set: standalone vowels combine into compound vowels (ㅗ+ㅏ -> ㅘ, ㅜ+ㅓ -> ㅝ).
        var v = HangulComposer()
        v.input("ㅗ"); v.input("ㅏ")
        XCTAssertEqual(v.text, "ㅘ")
        XCTAssertTrue(v.text.unicodeScalars.allSatisfy { HangulComposer.isCompatibilityJamo($0) })
        XCTAssertTrue(v.backspace()); XCTAssertEqual(v.text, "ㅗ")
        XCTAssertTrue(v.backspace()); XCTAssertEqual(v.text, "")

        var v2 = HangulComposer()
        v2.input("ㅜ"); v2.input("ㅓ")
        XCTAssertEqual(v2.text, "ㅝ")
        v2.input("ㅏ")
        XCTAssertEqual(v2.text, "ㅝㅏ")

        var syl = HangulComposer()
        XCTAssertTrue(syl.input(string: "ㅎㅏㄴ"))
        XCTAssertTrue(syl.text.unicodeScalars.allSatisfy { HangulComposer.isHangulSyllable($0) })
    }

    func testDecomposeAndBatchimHelpers() {
        XCTAssertEqual(HangulComposer.decomposeToJamo("닭"), ["ㄷ", "ㅏ", "ㄹ", "ㄱ"])
        XCTAssertEqual(HangulComposer.decomposeToJamo("와"), ["ㅇ", "ㅗ", "ㅏ"])
        XCTAssertEqual(HangulComposer.hasBatchim("학교"), false)
        XCTAssertEqual(HangulComposer.hasBatchim("집"), true)
        XCTAssertTrue(HangulComposer.hasRieulBatchim("서울"))
        XCTAssertFalse(HangulComposer.hasRieulBatchim("집"))
    }
}
