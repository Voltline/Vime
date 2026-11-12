import Foundation

/// Spellings one edit away from pinyin that Rime cannot read in full
/// syllables, for typos across a syllable boundary (shenem for shenme,
/// keiy for keyi, gongzo for gongzuo). Rime's speller corrects within a
/// syllable only; these spellings are looked up separately.
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
    /// Letters most often left out: vowels and the n, g, h of finals and initials.
    static let insertions: [Character] = ["a", "e", "i", "o", "u", "h", "n", "g"]

    /// Whether `input` reads as full syllables.
    static func isFullSyllables(_ input: String) -> Bool {
        let letters = Array(input)
        var reachable = [true] + Array(repeating: false, count: letters.count)
        for end in 1...max(1, letters.count) where end <= letters.count {
            for start in max(0, end - 6)..<end where reachable[start] {
                if syllables.contains(String(letters[start..<end])) { reachable[end] = true; break }
            }
        }
        return reachable[letters.count]
    }

    /// Whether to look for other spellings: plain letters that do not read
    /// as full syllables, and Rime's best reading is no dictionary phrase.
    static func wantsCorrection(_ input: String, top: RimeCandidate?) -> Bool {
        guard lengths.contains(input.count), input.allSatisfy({ ("a"..."z").contains($0) }),
              !isFullSyllables(input) else { return false }
        guard let top, top.coversInput else { return true }
        return top.sentence || top.quality < 0.75
    }

    /// Full-syllable spellings one edit from `input`: two letters swapped,
    /// then a letter dropped, then one added; at most `limit`.
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

    /// The phrase a spelling stands for: Rime's first candidate when it is one
    /// dictionary word of two characters or more covering the spelling.
    static func phrase(in candidates: [RimeCandidate]) -> RimeCandidate? {
        guard let first = candidates.first, first.coversInput, !first.sentence, first.quality >= 0.9,
              first.genuine.count >= 2 else { return nil }
        return first
    }
}
