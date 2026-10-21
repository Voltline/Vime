import Foundation

/// The 12-key kana pad: flick outputs, toggle cycles and the ゛゜小 key.
nonisolated enum KeyboardKanaLayout {
    /// Center, left, up, right, down; "" leaves a direction unused.
    static let keys: [[String]] = [
        ["あ", "い", "う", "え", "お"], ["か", "き", "く", "け", "こ"], ["さ", "し", "す", "せ", "そ"],
        ["た", "ち", "つ", "て", "と"], ["な", "に", "ぬ", "ね", "の"], ["は", "ひ", "ふ", "へ", "ほ"],
        ["ま", "み", "む", "め", "も"], ["や", "「", "ゆ", "」", "よ"], ["ら", "り", "る", "れ", "ろ"],
        ["わ", "を", "ん", "ー", "〜"],
    ]
    static let punctuation = ["、", "。", "？", "！", "…"]
    /// Stable key IDs (accessibility and skins), by row of `keys`.
    static let identifiers = ["a", "ka", "sa", "ta", "na", "ha", "ma", "ya", "ra", "wa"]

    /// Repeated taps on one key step through its cycle (toggle input).
    static let cycles: [[Character]] = [
        Array("あいうえおぁぃぅぇぉ"), Array("かきくけこ"), Array("さしすせそ"), Array("たちつてとっ"),
        Array("なにぬねの"), Array("はひふへほ"), Array("まみむめも"), Array("やゆよゃゅょ"),
        Array("らりるれろ"), Array("わをんゎー"),
    ]

    static func next(after character: Character, key: Int) -> Character? {
        guard cycles.indices.contains(key), let index = cycles[key].firstIndex(of: character) else { return nil }
        return cycles[key][(index + 1) % cycles[key].count]
    }

    /// ↶ steps back through whichever cycle contains the character.
    static func previous(_ character: Character) -> Character? {
        for cycle in cycles {
            if let index = cycle.firstIndex(of: character) { return cycle[(index + cycle.count - 1) % cycle.count] }
        }
        return nil
    }

    /// ゛゜小 cycles a character through its voiced, semi-voiced and small forms.
    static let modifierCycles: [[Character]] = [
        "かが", "きぎ", "くぐ", "けげ", "こご", "さざ", "しじ", "すず", "せぜ", "そぞ",
        "ただ", "ちぢ", "つっづ", "てで", "とど", "はばぱ", "ひびぴ", "ふぶぷ", "へべぺ", "ほぼぽ",
        "あぁ", "いぃ", "うぅゔ", "えぇ", "おぉ", "やゃ", "ゆゅ", "よょ", "わゎ",
    ].map(Array.init)

    static func modified(_ character: Character) -> Character? {
        for cycle in modifierCycles {
            if let index = cycle.firstIndex(of: character) { return cycle[(index + 1) % cycle.count] }
        }
        return nil
    }

    /// Taps on the same key this close together continue its cycle.
    static let toggleInterval: TimeInterval = 1
}
