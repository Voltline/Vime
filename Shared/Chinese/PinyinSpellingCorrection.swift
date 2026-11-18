import Foundation

/// Spellings one edit away from what was typed, looked up separately for
/// typos Rime's speller misses: across a syllable boundary (shenem for
/// shenme, keiy for keyi, gongzo for gongzuo), and in two-letter syllables,
/// which the speller leaves alone (maoai for maosi, wixiang for woxiang).
nonisolated enum PinyinSpellingCorrection {
    /// Standard Mandarin syllables, as in Scripts/generate_pinyin_algebra.py.
    static let syllables: Set<String> = Set("""
        a ai an ang ao ba bai ban bang bao bei ben beng bi bian biang biao bie bin bing bo bu ca cai can
        cang cao ce cei cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan
        chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei den deng di dia
        dian diao die ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng fiao fo
        fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han
        hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin
        jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang
        kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu
        luan lun luo lv lve ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na
        nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nun nuo nv nve
        o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie
        qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo sa
        sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai
        shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te tei teng ti tian
        tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao
        xie xin xing xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za
        zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu
        zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    static let lengths = 4...14
    /// Full syllables up to a four-character word; a longer reading is a
    /// sentence, which seldom turns into one dictionary word with one edit.
    static let wordSyllables = 4
    /// Letters most often left out: vowels and the n, g, h of finals and initials.
    static let insertions: [Character] = ["a", "e", "i", "o", "u", "h", "n", "g"]

    /// The fewest syllables `input` reads as, or nil when it does not read
    /// as full syllables.
    static func syllableCount(_ input: String) -> Int? {
        let letters = Array(input)
        var fewest: [Int?] = [0] + Array(repeating: nil, count: letters.count)
        for end in 1...max(1, letters.count) where end <= letters.count {
            for start in max(0, end - 6)..<end {
                guard let before = fewest[start], syllables.contains(String(letters[start..<end])) else { continue }
                fewest[end] = min(fewest[end] ?? .max, before + 1)
            }
        }
        return fewest[letters.count]
    }

    /// Whether `input` reads as full syllables.
    static func isFullSyllables(_ input: String) -> Bool { syllableCount(input) != nil }

    /// Whether to look for other spellings of plain letters. Input that does
    /// not read as full syllables, when Rime's best reading is no dictionary
    /// phrase; full syllables of a word's length, when Rime only makes a
    /// sentence of them (mao ai, with no word, may be maosi).
    static func wantsCorrection(_ input: String, top: RimeCandidate?) -> Bool {
        guard lengths.contains(input.count), input.allSatisfy({ ("a"..."z").contains($0) }) else { return false }
        if let count = syllableCount(input) {
            guard count <= wordSyllables else { return false }
            guard let top, top.coversInput else { return true }
            return top.sentence
        }
        guard let top, top.coversInput else { return true }
        return top.sentence || top.quality < 0.75
    }

    /// Full-syllable spellings one edit from `input`: two letters swapped,
    /// then a letter replaced by a neighbouring key, then a letter dropped,
    /// then one added; at most `limit`.
    static func spellings(for input: String, limit: Int = 24) -> [String] {
        let letters = Array(input)
        var found: [String] = []
        var seen: Set<String> = [input]
        func add(_ candidate: [Character]) {
            let text = String(candidate)
            guard found.count < limit, seen.insert(text).inserted, isFullSyllables(text) else { return }
            found.append(text)
        }
        for index in letters.indices.dropLast() where letters[index] != letters[index + 1] {
            var swapped = letters
            swapped.swapAt(index, index + 1)
            add(swapped)
        }
        for index in letters.indices {
            for neighbour in neighbours(of: letters[index]) {
                var replaced = letters
                replaced[index] = neighbour
                add(replaced)
            }
        }
        for index in letters.indices {
            var dropped = letters
            dropped.remove(at: index)
            add(dropped)
        }
        for index in 0...letters.count {
            for letter in insertions {
                var added = letters
                added.insert(letter, at: index)
                add(added)
            }
        }
        return found
    }

    /// One typing slip, by how a sentence's spellings are weighed.
    enum Edit: String, Sendable, CaseIterable {
        case swap, neighbour, drop, insert
    }

    /// Initials typed alone, as an abbreviated syllable.
    static let abbreviations: Set<String> = Set("b c ch d f g h j k l m n p q r s sh t w x y z zh".split(separator: " ").map(String.init))

    /// The fewest abbreviated syllables `letters` reads with, its other
    /// syllables full, and the letters in `full` inside full syllables; nil
    /// when it does not read so.
    static func abbreviationCount(_ letters: [Character], full: Range<Int>? = nil) -> Int? {
        var fewest: [Int?] = [0] + Array(repeating: nil, count: letters.count)
        for end in letters.indices.map({ $0 + 1 }) {
            for start in max(0, end - 6)..<end {
                guard let before = fewest[start] else { continue }
                let piece = String(letters[start..<end])
                let cost: Int
                if syllables.contains(piece) { cost = 0 }
                else if abbreviations.contains(piece), !(full?.overlaps(start..<end) ?? false) { cost = 1 }
                else { continue }
                fewest[end] = min(fewest[end] ?? .max, before + cost)
            }
        }
        return fewest[letters.count]
    }

    /// Spellings one edit from `input`, of any length, each with its edit,
    /// whose edited letters read as full syllables; abbreviations elsewhere
    /// stay as typed. Where some edit leaves fewer abbreviations than were
    /// typed (zakzhang, with a stray k), only those, so the slip finds itself.
    /// The last letter is never dropped: it is the syllable being typed.
    static func sentenceSpellings(for input: String) -> [(spelling: String, edit: Edit)] {
        let letters = Array(input)
        guard let typed = abbreviationCount(letters) else { return [] }
        var found: [(spelling: String, edit: Edit, abbreviations: Int)] = []
        var seen: Set<String> = [input]
        func add(_ candidate: [Character], _ edit: Edit, _ edited: Range<Int>) {
            let text = String(candidate)
            let clamped = max(0, edited.lowerBound)..<min(candidate.count, edited.upperBound)
            guard seen.insert(text).inserted, let count = abbreviationCount(candidate, full: clamped),
                  count <= typed else { return }
            found.append((text, edit, count))
        }
        for index in letters.indices.dropLast() where letters[index] != letters[index + 1] {
            var swapped = letters
            swapped.swapAt(index, index + 1)
            add(swapped, .swap, index..<index + 2)
        }
        for index in letters.indices {
            for neighbour in neighbours(of: letters[index]) {
                var replaced = letters
                replaced[index] = neighbour
                add(replaced, .neighbour, index..<index + 1)
            }
        }
        // Never the last letter: it starts the syllable being typed, and
        // dropping it would shorten the sentence under the user's fingers.
        for index in letters.indices.dropLast() {
            var dropped = letters
            dropped.remove(at: index)
            add(dropped, .drop, index - 1..<index + 1)
        }
        for index in 0...letters.count {
            for letter in insertions {
                var added = letters
                added.insert(letter, at: index)
                add(added, .insert, index..<index + 1)
            }
        }
        let fixesOne = found.contains { $0.abbreviations < typed }
        return found.filter { !fixesOne || $0.abbreviations < typed }
            .map { ($0.spelling, $0.edit) }
    }

    /// The letters of `input` each character of `text` spells, in order:
    /// one of its syllables in `lexicon`, or its initial (first letter, or
    /// zh, ch, sh); full syllables preferred. Nil when `text` does not spell
    /// `input`.
    static func letterSpans(of text: String, in input: String, lexicon: ChinesePinyinLexicon) -> [Range<Int>]? {
        let characters = Array(text.unicodeScalars), letters = Array(input.utf8)
        // best[i][j]: fewest initials for the first i characters spelling the first j letters.
        var best = [[Int?]](repeating: [Int?](repeating: nil, count: letters.count + 1), count: characters.count + 1)
        var step = [[Int]](repeating: [Int](repeating: 0, count: letters.count + 1), count: characters.count + 1)
        best[0][0] = 0
        for i in characters.indices {
            var ways: [(spelling: [UInt8], length: Int, cost: Int)] = []
            for spelling in lexicon.spellings(of: characters[i]) where !spelling.isEmpty {
                ways.append((spelling, spelling.count, 0))
                let initial = spelling.count > 1 && [UInt8(ascii: "z"), UInt8(ascii: "c"), UInt8(ascii: "s")].contains(spelling[0])
                    && spelling[1] == UInt8(ascii: "h") ? 2 : 1
                if initial < spelling.count { ways.append((spelling, initial, 1)) }
            }
            for j in 0...letters.count {
                guard let before = best[i][j] else { continue }
                func reach(_ length: Int, _ cost: Int) {
                    guard j + length <= letters.count, best[i + 1][j + length].map({ before + cost < $0 }) ?? true else { return }
                    best[i + 1][j + length] = before + cost
                    step[i + 1][j + length] = length
                }
                for (spelling, length, cost) in ways {
                    let target = Array(spelling.prefix(length))
                    if j + length <= letters.count, letters[j..<j + length].elementsEqual(target) { reach(length, cost) }
                    // Where Rime's own spelling corrections read a slip, one edit off.
                    guard cost == 0 else { continue }
                    for typed in max(1, length - 1)...(length + 1) where j + typed <= letters.count
                        && isOneEdit(Array(letters[j..<j + typed]), target) {
                        reach(typed, editCost)
                    }
                }
            }
        }
        guard best[characters.count][letters.count] != nil else { return nil }
        var spans: [Range<Int>] = []
        var end = letters.count
        for i in stride(from: characters.count, to: 0, by: -1) {
            let length = step[i][end]
            spans.append(end - length..<end)
            end -= length
        }
        return spans.reversed()
    }

    /// What one slip costs an alignment, against one initial.
    static let editCost = 8

    /// Whether `a` becomes `b` by one letter replaced, added, dropped, or two
    /// neighbouring letters swapped.
    static func isOneEdit(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a == b { return false }
        if a.count == b.count {
            let differ = a.indices.filter { a[$0] != b[$0] }
            return differ.count == 1 || (differ.count == 2 && differ[1] == differ[0] + 1
                && a[differ[0]] == b[differ[1]] && a[differ[1]] == b[differ[0]])
        }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        guard long.count == short.count + 1 else { return false }
        var i = 0
        while i < short.count, long[i] == short[i] { i += 1 }
        return long[(i + 1)...].elementsEqual(short[i...])
    }

    /// Keys within a key and a quarter on QWERTY, nearest first, as the
    /// Japanese keyboard's corrections measure them.
    static func neighbours(of letter: Character) -> [Character] { neighbourTable[letter] ?? [] }

    private static let neighbourTable: [Character: [Character]] = {
        var positions: [Character: (x: Double, y: Double)] = [:]
        for (row, keys, inset) in [(0, "qwertyuiop", 0.0), (1, "asdfghjkl", 0.5), (2, "zxcvbnm", 1.4)] {
            for (column, key) in keys.enumerated() { positions[key] = (Double(column) + inset, Double(row)) }
        }
        return positions.mapValues { origin in
            positions.compactMap { key, point -> (Character, Double)? in
                let distance = hypot(point.x - origin.x, point.y - origin.y)
                return distance > 0 && distance <= 1.25 ? (key, distance) : nil
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.0)
        }
    }()

    /// The phrase a spelling stands for: Rime's first candidate when it is one
    /// dictionary word of two characters or more covering the spelling.
    static func phrase(in candidates: [RimeCandidate]) -> RimeCandidate? {
        guard let first = candidates.first, first.coversInput, !first.sentence, first.quality >= 0.9,
              first.genuine.count >= 2 else { return nil }
        return first
    }
}
