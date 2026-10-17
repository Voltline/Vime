import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// Small offline packs; source provenance and licenses ship alongside the data.
/// Dynamic dictionary lookup installs only matching prefixes (never all 2,000).
nonisolated final class JapaneseLanguageResources: Sendable {
    struct Spelling: Decodable, Sendable {
        let reading: String
        let preferred: String
        let alternatives: [String]
        let authority: String
        let weight: Double
    }
    struct Word: Decodable, Sendable {
        let reading: String
        let surface: String
        let value: Float
    }
    static let shared = JapaneseLanguageResources()
    let spellings: [String: Spelling]
    private let words: [String: [Word]]
    init(bundle: Bundle = .main) {
        func load<T: Decodable>(_ name: String) -> [T] {
            guard let url = bundle.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let result = try? JSONDecoder().decode([T].self, from: data) else { return [] }
            return result
        }
        let styles: [Spelling] = load("OrthographyPreferences")
        spellings = Dictionary(styles.map { (RomajiConverter.katakana($0.reading), $0) }, uniquingKeysWith: { a, _ in a })
        let entries: [Word] = load("SupplementalLexicon")
        words = Dictionary(grouping: entries, by: { RomajiConverter.katakana($0.reading) })
    }
    func matchingWords(_ reading: String) -> [DicdataElement] {
        (1...max(1, reading.count)).flatMap { length in
            (words[String(reading.prefix(length))] ?? []).prefix(4).map {
                DicdataElement(word: $0.surface, ruby: RomajiConverter.katakana($0.reading),
                    cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: PValue($0.value))
            }
        }
    }
    func preference(reading: String, surface: String) -> Double {
        guard let entry = spellings[reading] else { return 0 }
        if surface == entry.preferred { return entry.weight }
        return entry.alternatives.contains(surface) ? -entry.weight : 0
    }
    func preferredSurface(_ candidate: Candidate) -> String {
        candidate.data.map { element in
            guard let entry = spellings[element.ruby], entry.alternatives.contains(element.word) else { return element.word }
            return entry.preferred
        }.joined()
    }
    func preference(_ candidate: CandidateSnapshot) -> Double {
        let whole = preference(reading: candidate.reading, surface: candidate.text)
        if whole != 0 { return whole }
        // Noun-only table: do not turn formal nouns or auxiliary verbs into kana
        // globally. Multiword phrases can still prefer attested noun spellings.
        return candidate.candidate.data.reduce(0) { score, element in
            score + preference(reading: element.ruby,
                surface: candidate.displaySurface == nil ? element.word : spellings[element.ruby]?.preferred ?? element.word)
        }
    }
}
