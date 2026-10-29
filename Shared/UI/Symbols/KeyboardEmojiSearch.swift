import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Emoji search for the toolbar: Japanese readings through azooKey's emoji
/// dictionary, then English Unicode names for typed letters.
enum KeyboardEmojiSearch {
    static let limit = 40
    private static let replacer = TextReplacer.withDefaultEmojiDictionary()
    private static let names = KeyboardSymbolCatalog.emoji.groups.flatMap(\.items).map {
        (text: $0.text, words: $0.name.lowercased().split { !$0.isLetter })
    }

    static func results(reading: String, typed: String) -> [String] {
        var seen = Set<String>(), values: [String] = []
        func add(_ text: String) {
            if values.count < limit, KeyboardEmojiAvailability.supports(text), seen.insert(text).inserted { values.append(text) }
        }
        if !reading.isEmpty {
            for result in replacer.getSearchResult(query: reading, target: [.emoji], ignoreNonBaseEmoji: true) { add(catalogForm(result.text)) }
        }
        let word = typed.lowercased()
        if word.count >= 2, word.allSatisfy({ $0.isASCII && $0.isLetter }) {
            for item in names where values.count < limit && item.words.contains(where: { $0.hasPrefix(word) }) { add(item.text) }
        }
        return values
    }

    /// The dictionary appends U+FE0F even to emoji-presentation characters;
    /// use the catalog's spelling so recents and the panel agree.
    private static func catalogForm(_ text: String) -> String {
        guard KeyboardSymbolCatalog.emojiNames[text] == nil, text.unicodeScalars.last == "\u{FE0F}" else { return text }
        var scalars = text.unicodeScalars
        scalars.removeLast()
        let trimmed = String(scalars)
        return KeyboardSymbolCatalog.emojiNames[trimmed] == nil ? text : trimmed
    }
}
