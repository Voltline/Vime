import Foundation

/// Special Chinese candidate conversions triggered by short pinyin codes or a
/// `v` numeric prefix (date, time, weekday, lunar calendar, and RMB uppercase).
///
/// All logic stays self-contained here so `ChineseInputSession` only needs a
/// tiny hook to query and commit these candidates.
nonisolated enum ChineseSpecialConversions {
    enum DateFormat: String, CaseIterable, Sendable {
        case chinese = "chinese"
        case hyphen = "hyphen"
        case slash = "slash"

        var pattern: String {
            switch self {
            case .chinese: "yyyy年M月d日"
            case .hyphen: "yyyy-MM-dd"
            case .slash: "yyyy/MM/dd"
            }
        }
    }

    enum TimeFormat: String, CaseIterable, Sendable {
        case colon = "colon"
        case chinese = "chinese"

        func pattern(traditional: Bool) -> String {
            switch self {
            case .colon: "HH:mm"
            case .chinese: traditional ? "H時mm分" : "H时mm分"
            }
        }
    }

    struct Options: Equatable, Sendable {
        var dateFormat: DateFormat = .chinese
        var timeFormat: TimeFormat = .colon
        var traditional: Bool = false
    }

    struct Candidate: Equatable, Sendable {
        let text: String
        let annotation: String?
    }

    // MARK: Trigger Tables

    private static let relativeDays: [String: Int] = [
        "rq": 0, "riqi": 0,
        "jt": 0, "jintian": 0,
        "mt": 1, "mingtian": 1,
        "ht": 2, "houtian": 2,
        "zt": -1, "zuotian": -1,
        "qt": -2, "qiantian": -2,
    ]

    private static let timeTriggers: Set<String> = ["sj", "shijian", "xz", "xianzai"]
    private static let xingqiTriggers: Set<String> = ["xq", "xingqi"]
    private static let zhouTriggers: Set<String> = ["zj", "zhouji"]
    private static let lunarTriggers: Set<String> = ["nl", "nongli"]

    private static let heavenlyStems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    private static let earthlyBranches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
    private static let lunarMonths = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    private static let lunarMonthsTraditional = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "臘"]
    private static let lunarDays = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    // MARK: Pinyin Trigger Candidates (placed after normal Rime candidates)

    /// Returns special candidates for an open pinyin input (e.g. `rq`, `sj`, `xq`, `zj`, `nl`).
    /// Never matches inputs containing capitals or non-ASCII letters.
    static func candidates(
        for input: String,
        now: Date = Date(),
        options: Options = Options(),
        timeZone: TimeZone = .current
    ) -> [Candidate] {
        let normalized = input.lowercased().filter { $0 != "'" }
        guard !normalized.isEmpty else { return [] }

        if let dayOffset = relativeDays[normalized] {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = timeZone
            guard let day = gregorian.date(byAdding: .day, value: dayOffset, to: now) else { return [] }
            let formatted = format(day, pattern: options.dateFormat.pattern, calendar: gregorian, timeZone: timeZone)
            return [Candidate(text: formatted, annotation: nil)]
        }

        if timeTriggers.contains(normalized) {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = timeZone
            let formatted = format(
                now,
                pattern: options.timeFormat.pattern(traditional: options.traditional),
                calendar: gregorian,
                timeZone: timeZone
            )
            return [Candidate(text: formatted, annotation: nil)]
        }

        if xingqiTriggers.contains(normalized) {
            return [Candidate(text: weekdayString(for: now, prefix: "星期", timeZone: timeZone), annotation: nil)]
        }

        if zhouTriggers.contains(normalized) {
            let prefix = options.traditional ? "週" : "周"
            return [Candidate(text: weekdayString(for: now, prefix: prefix, timeZone: timeZone), annotation: nil)]
        }

        if lunarTriggers.contains(normalized) {
            guard let lunar = lunarDateString(for: now, traditional: options.traditional, timeZone: timeZone) else {
                return []
            }
            return [Candidate(text: lunar, annotation: nil)]
        }

        return []
    }

    // MARK: V-Prefix RMB Uppercase Mode

    /// Whether a typed symbol (`0`...`9` or `.`) can continue an active `v` numeric buffer.
    static func canAppendToVBuffer(_ buffer: String, text: String) -> Bool {
        guard buffer.hasPrefix("v"), text.count == 1, let ch = text.first else { return false }
        let digits = buffer.dropFirst()
        if ch >= "0" && ch <= "9" {
            // Cap integer part at 16 digits (up to 9999兆) and fractional part at 2 digits (角分).
            if let dot = digits.firstIndex(of: ".") {
                return digits.distance(from: digits.index(after: dot), to: digits.endIndex) < 2
            }
            return digits.count < 16
        }
        if ch == "." || ch == "。" {
            return !digits.isEmpty && !digits.contains(".")
        }
        return false
    }

    /// Normalizes a `.` or `。` when appending into the `v` buffer.
    static func normalizedVCharacter(_ text: String) -> String {
        text == "。" ? "." : text
    }

    /// Produces RMB uppercase and fallback numeric candidates for a `v`-prefixed number (e.g. `v1234.56`).
    static func vModeCandidates(for buffer: String, traditional: Bool = false) -> [Candidate] {
        guard buffer.hasPrefix("v") else { return [] }
        let rawNumber = String(buffer.dropFirst())
        guard !rawNumber.isEmpty else { return [] }
        guard let rmb = formatRMBUppercase(rawNumber, traditional: traditional) else {
            return [Candidate(text: rawNumber, annotation: nil)]
        }
        return [
            Candidate(text: rmb, annotation: nil),
            Candidate(text: rawNumber, annotation: nil),
        ]
    }

    /// Converts a non-negative decimal string (up to 16 integer digits and 2 fractional digits)
    /// into formal Chinese RMB uppercase (e.g. `1234` -> `壹仟贰佰叁拾肆元整`, `1234.56` -> `壹仟贰佰叁拾肆元伍角陆分`).
    static func formatRMBUppercase(_ raw: String, traditional: Bool = false) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let intRaw = String(parts[0])
        let fracRaw = parts.count == 2 ? String(parts[1]) : ""
        guard !intRaw.isEmpty,
              intRaw.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              fracRaw.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              fracRaw.count <= 2 else {
            return nil
        }

        // Strip leading zeros while keeping a single "0" when value is zero.
        let intStripped = intRaw.drop(while: { $0 == "0" })
        let intPart = intStripped.isEmpty ? "0" : String(intStripped)
        guard intPart.count <= 16 else { return nil }

        let digits = traditional
            ? ["零", "壹", "貳", "參", "肆", "伍", "陸", "柒", "捌", "玖"]
            : ["零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖"]
        let smallUnits = ["", "拾", "佰", "仟"]
        let bigUnits = traditional ? ["", "萬", "億", "兆"] : ["", "万", "亿", "兆"]
        let yuan = traditional ? "圓" : "元"

        let jiao = fracRaw.count >= 1 ? Int(String(fracRaw[fracRaw.startIndex])) ?? 0 : 0
        let fen = fracRaw.count >= 2 ? Int(String(fracRaw[fracRaw.index(after: fracRaw.startIndex)])) ?? 0 : 0

        if intPart == "0" && jiao == 0 && fen == 0 {
            return "零\(yuan)整"
        }

        // Convert integer part in 4-digit sections from most significant to least significant.
        var intResult = ""
        if intPart != "0" {
            let chars = Array(intPart)
            let totalSections = (chars.count + 3) / 4
            var needZeroBeforeNextNonZeroSection = false

            for sectionOffset in 0..<totalSections {
                let end = chars.count - (totalSections - 1 - sectionOffset) * 4
                let start = max(0, end - 4)
                let slice = chars[start..<end]
                let sectionValue = slice.reduce(0) { $0 * 10 + (Int(String($1)) ?? 0) }
                let bigUnitIndex = totalSections - 1 - sectionOffset

                if sectionValue == 0 {
                    if !intResult.isEmpty {
                        needZeroBeforeNextNonZeroSection = true
                    }
                    continue
                }

                // If an earlier section was all zero, or this non-first section starts with 0
                // (e.g. 1_0005 or 1_0200), emit a single 零 separator.
                if !intResult.isEmpty && (needZeroBeforeNextNonZeroSection || slice.first == "0") {
                    intResult += "零"
                }
                needZeroBeforeNextNonZeroSection = false

                var sectionText = ""
                var zeroPending = false
                for (i, ch) in slice.enumerated() {
                    let d = Int(String(ch)) ?? 0
                    let unitIndex = slice.count - 1 - i
                    if d == 0 {
                        if !sectionText.isEmpty { zeroPending = true }
                    } else {
                        if zeroPending {
                            sectionText += "零"
                            zeroPending = false
                        }
                        sectionText += digits[d] + smallUnits[unitIndex]
                    }
                }
                intResult += sectionText + bigUnits[bigUnitIndex]
            }
            intResult += yuan
        }

        if jiao == 0 && fen == 0 {
            return intResult + "整"
        }

        var fracResult = ""
        if jiao > 0 {
            fracResult += digits[jiao] + "角"
            if fen > 0 {
                fracResult += digits[fen] + "分"
            } else {
                fracResult += "整"
            }
        } else if fen > 0 {
            if !intResult.isEmpty {
                fracResult += "零"
            }
            fracResult += digits[fen] + "分"
        }
        return intResult + fracResult
    }

    // MARK: Formatting Helpers

    private static func format(_ date: Date, pattern: String, calendar: Calendar, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func weekdayString(for date: Date, prefix: String, timeZone: TimeZone) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let weekday = gregorian.component(.weekday, from: date) // 1 = Sunday ... 7 = Saturday
        let index = max(0, min(weekdays.count - 1, weekday - 1))
        return prefix + weekdays[index]
    }

    static func lunarDateString(for date: Date, traditional: Bool = false, timeZone: TimeZone = .current) -> String? {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = timeZone
        let comps = chinese.dateComponents([.year, .month, .day, .isLeapMonth], from: date)
        guard let cycleYear = comps.year, let month = comps.month, let day = comps.day,
              (1...60).contains(cycleYear),
              (1...12).contains(month),
              (1...30).contains(day) else {
            return nil
        }
        let stem = heavenlyStems[(cycleYear - 1) % 10]
        let branch = earthlyBranches[(cycleYear - 1) % 12]
        let leap = (comps.isLeapMonth == true) ? (traditional ? "閏" : "闰") : ""
        let monthName = (traditional ? lunarMonthsTraditional : lunarMonths)[month - 1]
        let dayName = lunarDays[day - 1]
        return "\(stem)\(branch)年\(leap)\(monthName)月\(dayName)"
    }
}
