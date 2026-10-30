import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// iOS text replacements with a kana shortcut, held for this process only.
/// The keyboard supplies them; they are never saved or exported.
nonisolated enum JapaneseSystemShortcuts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: [DicdataElement] = []

    static var entries: [DicdataElement] { lock.withLock { current } }

    /// Pairs whose shortcut is not kana belong to English input and are skipped.
    static func update(_ pairs: [(shortcut: String, phrase: String)]) {
        var seen = Set<String>()
        let values = pairs.compactMap { pair -> DicdataElement? in
            let reading = pair.shortcut.applyingTransform(.hiraganaToKatakana, reverse: false) ?? pair.shortcut
            let phrase = pair.phrase.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard (1...64).contains(reading.count), reading.unicodeScalars.allSatisfy({
                (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC
            }), (1...128).contains(phrase.count), !phrase.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }), seen.insert(reading + "\0" + phrase).inserted else { return nil }
            return DicdataElement(word: phrase, ruby: reading, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -8)
        }.prefix(JapaneseUserDictionaryStore.maximumEntries)
        lock.withLock { current = Array(values) }
    }
}
