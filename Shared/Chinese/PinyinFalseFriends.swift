import Foundation

/// Japanese words that a Chinese reader takes for something else: 手紙 is a
/// letter, 丈夫 means sturdy, 公司 is only a Chinese company. Read from
/// PinyinFalseFriends.tsv; PinyinLookupCandidates notes the meaning on these
/// words and offers the Japanese word for the Chinese meaning after them.
nonisolated struct PinyinFalseFriends: Sendable {
    struct Entry: Equatable, Sendable {
        /// The Japanese meaning, in Simplified Chinese.
        let meaning: String
        /// The Japanese word for what the Chinese word means, and its reading.
        let equivalent: (surface: String, reading: String)?

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.meaning == rhs.meaning && lhs.equivalent?.surface == rhs.equivalent?.surface
                && lhs.equivalent?.reading == rhs.equivalent?.reading
        }
    }

    private let entries: [String: Entry]

    /// Lines of tab-separated word, meaning, and optionally the equivalent
    /// and its reading; lines starting with # are comments.
    init(text: String) {
        var entries: [String: Entry] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            let equivalent = fields.count >= 4 && !fields[2].isEmpty && !fields[3].isEmpty ? (fields[2], fields[3]) : nil
            entries[fields[0]] = Entry(meaning: fields[1], equivalent: equivalent)
        }
        self.entries = entries
    }

    subscript(surface: String) -> Entry? { entries[surface] }
    var count: Int { entries.count }

    static let shared = PinyinFalseFriends(text: Bundle.main.url(forResource: "PinyinFalseFriends", withExtension: "tsv")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
}

/// What a looked-up word's note says.
nonisolated enum PinyinLookupNote: Equatable, Sendable {
    /// The word means something else in Japanese: its meaning in Chinese.
    case falseFriend(meaning: String)
    /// The Japanese word for what the false friend before it means in Chinese.
    case japaneseEquivalent
}
