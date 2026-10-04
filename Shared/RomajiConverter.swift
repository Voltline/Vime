import Foundation

/// Reparse the original keystrokes so backspace can undo a kana syllable one key at a time.
enum RomajiConverter {
    struct Result: Equatable {
        let kana: String
        let pending: String
        var display: String { kana + pending }
    }

    static func convert(_ input: String, finalize: Bool = false) -> Result {
        let letters = Array(input.lowercased())
        var index = 0
        var output = ""
        while index < letters.count {
            let remaining = String(letters[index...])
            let first = letters[index]
            if first == "n" {
                if index + 1 == letters.count {
                    return Result(kana: output + (finalize ? "ん" : ""), pending: finalize ? "" : "n")
                }
                let next = letters[index + 1]
                if next == "'" {
                    output += "ん"
                    index += 2
                    continue
                }
                if next == "n" {
                    output += "ん"
                    index += index + 2 == letters.count ? 2 : 1
                    continue
                }
                if !"aiueoy".contains(next) {
                    output += "ん"
                    index += 1
                    continue
                }
            }
            if index + 1 < letters.count, first == letters[index + 1],
               "bcdfghjklmpqrstvwxyz".contains(first) {
                output += "っ"
                index += 1
                continue
            }
            var matched = false
            for count in stride(from: min(4, letters.count - index), through: 1, by: -1) {
                let key = String(letters[index..<(index + count)])
                if let kana = table[key] {
                    output += kana
                    index += count
                    matched = true
                    break
                }
            }
            if matched { continue }
            if prefixes.contains(remaining) {
                return Result(kana: output, pending: remaining)
            }
            output.append(first)
            index += 1
        }
        return Result(kana: output, pending: "")
    }

    static func katakana(_ hiragana: String) -> String {
        String(String.UnicodeScalarView(hiragana.unicodeScalars.map { scalar in
            (0x3041...0x3096).contains(scalar.value) ? UnicodeScalar(scalar.value + 0x60)! : scalar
        }))
    }

    static let table: [String: String] = {
        var map: [String: String] = [:]
        let vowels = Array("aiueo")
        let rows: [(String, String)] = [
            ("", "あいうえお"), ("k", "かきくけこ"), ("g", "がぎぐげご"),
            ("s", "さしすせそ"), ("z", "ざじずぜぞ"), ("t", "たちつてと"),
            ("d", "だぢづでど"), ("n", "なにぬねの"), ("h", "はひふへほ"),
            ("b", "ばびぶべぼ"), ("p", "ぱぴぷぺぽ"), ("m", "まみむめも"),
            ("r", "らりるれろ"), ("v", "ゔぁゔぃゔゔぇゔぉ")
        ]
        for (prefix, kana) in rows where prefix != "v" {
            for (vowel, character) in zip(vowels, kana) { map[prefix + String(vowel)] = String(character) }
        }
        let aliases: [String: String] = [
            "shi": "し", "chi": "ち", "tsu": "つ", "fu": "ふ", "ji": "じ",
            "ya": "や", "yu": "ゆ", "yo": "よ", "ye": "いぇ",
            "wa": "わ", "wi": "うぃ", "wu": "う", "we": "うぇ", "wo": "を",
            "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
            "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ", "fyu": "ふゅ",
            "tsa": "つぁ", "tsi": "つぃ", "tse": "つぇ", "tso": "つぉ",
            "she": "しぇ", "je": "じぇ", "che": "ちぇ",
            "tha": "てゃ", "thi": "てぃ", "thu": "てゅ", "the": "てぇ", "tho": "てょ",
            "dha": "でゃ", "dhi": "でぃ", "dhu": "でゅ", "dhe": "でぇ", "dho": "でょ",
            "twa": "とぁ", "twi": "とぃ", "twu": "とぅ", "twe": "とぇ", "two": "とぉ",
            "dwa": "どぁ", "dwi": "どぃ", "dwu": "どぅ", "dwe": "どぇ", "dwo": "どぉ",
            "kwa": "くぁ", "kwi": "くぃ", "kwe": "くぇ", "kwo": "くぉ",
            "gwa": "ぐぁ", "gwi": "ぐぃ", "gwe": "ぐぇ", "gwo": "ぐぉ",
            "qa": "くぁ", "qi": "くぃ", "qu": "く", "qe": "くぇ", "qo": "くぉ",
            "xtsu": "っ", "ltsu": "っ", "xtu": "っ", "ltu": "っ",
            "xwa": "ゎ", "lwa": "ゎ", "xka": "ゕ", "lka": "ゕ", "xke": "ゖ", "lke": "ゖ",
            "-": "ー"
        ]
        map.merge(aliases) { _, new in new }
        let contracted = ["ky": "き", "gy": "ぎ", "sy": "し", "sh": "し", "zy": "じ",
                          "jy": "じ", "j": "じ", "ty": "ち", "ch": "ち", "cy": "ち",
                          "dy": "ぢ", "ny": "に", "hy": "ひ", "by": "び", "py": "ぴ",
                          "my": "み", "ry": "り", "fy": "ふ", "vy": "ゔ"]
        for (prefix, base) in contracted {
            for (vowel, small) in [("a", "ゃ"), ("u", "ゅ"), ("o", "ょ")] { map[prefix + vowel] = base + small }
        }
        for prefix in ["x", "l"] {
            for (vowel, small) in zip(vowels, "ぁぃぅぇぉ") { map[prefix + String(vowel)] = String(small) }
            for (vowel, small) in [("a", "ゃ"), ("u", "ゅ"), ("o", "ょ")] { map[prefix + "y" + vowel] = small }
        }
        return map
    }()

    private static let prefixes: Set<String> = {
        var result = Set<String>()
        for key in table.keys {
            for count in 1..<key.count { result.insert(String(key.prefix(count))) }
        }
        return result
    }()
}
