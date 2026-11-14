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
