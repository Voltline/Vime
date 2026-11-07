import CRime
import Foundation
import XCTest

final class PinyinToleranceTests: XCTestCase {
    static let data = ProcessInfo.processInfo.environment["VIME_RIME_DATA"].map { URL(fileURLWithPath: $0) } ?? RimeSmokeTests.data

    override class func setUp() {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("vime-rime-tolerance-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        precondition(vime_rime_start(data.path, user.path))
    }

    private func candidates(_ input: String, limit: Int32 = 10) -> [String] {
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        for scalar in input.unicodeScalars { _ = vime_rime_process_key(session, Int32(scalar.value), 0) }
        var raw = vime_rime_snapshot(session, limit)
        defer { vime_rime_snapshot_free(&raw) }
        return (0..<Int(raw.candidateCount)).map { String(cString: raw.candidates[$0].text) }
    }

    /// Exact input keeps its reading on top; corrections never displace it.
    func testExactInputKeepsItsTopCandidate() {
        let cases: KeyValuePairs = [
            "ni": "你", "wo": "我", "shi": "是", "de": "的", "hao": "好",
            "nihao": "你好", "women": "我们", "zhongguo": "中国", "xianzai": "现在",
            "xiexie": "谢谢", "pengyou": "朋友", "gongzuo": "工作", "xuexi": "学习",
            "dianhua": "电话", "shijian": "时间", "mingtian": "明天", "jintian": "今天",
            "xihuan": "喜欢", "yinwei": "因为", "suoyi": "所以", "danshi": "但是",
            "ruguo": "如果", "meiyou": "没有", "keyi": "可以", "zhidao": "知道",
            "nihai": "你还", "xi'an": "西安", "fang'an": "方案",
            "nihaoma": "你好吗", "wobuzhidao": "我不知道", "xiexienimen": "谢谢你们",
            "jintiantianqizhenhao": "今天天气真好", "womenyiqiqu": "我们一起去",
            "womenyiqiqukandianying": "我们一起去看电影",
        ]
        for (input, expected) in cases {
            XCTAssertEqual(candidates(input).first, expected, input)
        }
        // Full syllables make their sentence without corrections: wo yu o
        // stays three characters even though "yuo" is a typo of "you".
        for input in ["woyuo", "pengyuo"] {
            XCTAssertEqual(candidates(input).first?.count, 3, input)
        }
        // A correction in a phrase's fourth syllable or later costs as much as
        // anywhere else: valid "zhenhai" does not turn into 真好 (天气真好).
        XCTAssertNotEqual(candidates("jintiantianqizhenhai").first, "今天天气真好")
        // A single syllable stays a single character, not 西安.
        XCTAssertEqual(candidates("xian").prefix(5).filter { $0.count > 1 }, [], "xian")
    }

    /// Initials stay abbreviations: a vowelless input is never read as a typo.
    func testInitialsStayAbbreviations() {
        XCTAssertTrue(candidates("zg").contains("中国"))
        XCTAssertTrue(candidates("sj").prefix(5).contains("时间"))
        for input in ["hsn", "zsn", "bjd"] {
            XCTAssertEqual(candidates(input).first?.count, 3, input)
        }
    }

    /// (input, intended word, the rank it must reach at worst)
    static let typos: [(String, String, Int)] = [
        // One neighbouring key on QWERTY. "nihai" is valid pinyin itself, so
        // its exact phrases come first and 你好 follows as a correction.
        ("nihai", "你好", 4), ("zhomg", "中", 1), ("diamhua", "电话", 1), ("pemgyou", "朋友", 1),
        ("gonhzuo", "工作", 1), ("mingtiam", "明天", 1), ("jintiam", "今天", 1), ("womem", "我们", 1),
        ("xiexir", "谢谢", 1), ("diamying", "电影", 1), ("beijimg", "北京", 1), ("shamghai", "上海", 1),
        ("gomgsi", "公司", 1), ("tiamqi", "天气", 1), ("pengyiu", "朋友", 1), ("xuexiap", "学校", 1),
        ("huanyimg", "欢迎", 1), ("chifam", "吃饭", 1), ("shuijiap", "睡觉", 1), ("zaijiam", "再见", 3),
        // Two letters swapped inside a syllable.
        ("zaho", "照", 3), ("hoa", "好", 1), ("nihoa", "你好", 1), ("xain", "先", 3),
        ("zhnog", "中", 1), ("xeixie", "谢谢", 1), ("pnegyou", "朋友", 1), ("mingtain", "明天", 1),
        ("jintain", "今天", 1), ("dainhua", "电话", 1), ("womne", "我们", 1), ("shuijaio", "睡觉", 1),
        ("xeuxi", "学习", 1), ("tainqi", "天气", 1), ("beijnig", "北京", 1), ("huanyign", "欢迎", 1),
        ("pengyuo", "朋友", 2),
        // An unfinished syllable in the middle.
        ("wodo", "我都", 3), ("donxi", "东西", 1), ("zhonwen", "中文", 1), ("xionmao", "熊猫", 1),
        ("zhomo", "周末", 1), ("tonxue", "同学", 1), ("chonfu", "重复", 1), ("konqi", "空气", 1),
        ("yonyuan", "永远", 1), ("dotian", "冬天", 1), ("sogei", "送给", 1),
        // A missing g before the next syllable.
        ("zhonguo", "中国", 1), ("zhonhua", "中华", 1), ("gonsi", "公司", 1), ("zhonguoren", "中国人", 1),
        // Typos inside sentences.
        ("jintiantianqizhenhap", "今天天气真好", 1), ("womenyiqiqukandiamying", "我们一起去看电影", 1),
        ("wozaixuexiap", "我在学校", 1), ("woxiangchifam", "我想吃饭", 1), ("mingtianjiam", "明天见", 1),
        ("wohemhao", "我很好", 1),
    ]

    func testTyposRecoverTheIntendedWord() {
        var misses: [String] = []
        for (input, word, rank) in Self.typos {
            let list = candidates(input)
            if !list.prefix(rank).contains(word) {
                misses.append("\(input) -> \(word) within \(rank): \(list.prefix(5).joined(separator: " "))")
            }
        }
        XCTAssertEqual(misses, [], "\(misses.count) of \(Self.typos.count) typos missed")
    }

    func testDump() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let list = environment["VIME_DUMP"] else { throw XCTSkip("set VIME_DUMP") }
        let limit = environment["VIME_DUMP_LIMIT"].flatMap { Int32($0) } ?? 10
        for input in list.split(separator: ",") {
            print("DUMP \(input): \(candidates(String(input), limit: limit).joined(separator: " "))")
            fflush(stdout)
        }
    }

    func testTiming() throws {
        guard let list = ProcessInfo.processInfo.environment["VIME_TIME"] else { throw XCTSkip("set VIME_TIME") }
        let session = vime_rime_create_session()
        defer { vime_rime_destroy_session(session) }
        for input in list.split(separator: ",") {
            var total = 0.0, worst = 0.0
            let rounds = 20
            for _ in 0..<rounds {
                vime_rime_clear(session)
                for scalar in input.unicodeScalars {
                    let start = DispatchTime.now().uptimeNanoseconds
                    _ = vime_rime_process_key(session, Int32(scalar.value), 0)
                    var raw = vime_rime_snapshot(session, 60)
                    vime_rime_snapshot_free(&raw)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                    total += ms
                    worst = max(worst, ms)
                }
            }
            print(String(format: "TIME %@: %.2f ms/key, worst %.2f ms", String(input), total / Double(rounds * input.count), worst))
            fflush(stdout)
        }
    }
}
