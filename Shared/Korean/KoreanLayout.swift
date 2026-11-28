import Foundation

/// Standard KS X 5002 2-beolsik (두벌식) keyboard layout, VoiceOver jamo names,
/// and physical QWERTY neighbor geometry for jamo-level error correction.
nonisolated enum KoreanLayout {
    /// Physical QWERTY rows mapped to unshifted 2-beolsik jamo.
    static let rows: [[(key: Character, normal: Character, shifted: Character)]] = [
        [
            ("q", "ㅂ", "ㅃ"), ("w", "ㅈ", "ㅉ"), ("e", "ㄷ", "ㄸ"), ("r", "ㄱ", "ㄲ"), ("t", "ㅅ", "ㅆ"),
            ("y", "ㅛ", "ㅛ"), ("u", "ㅕ", "ㅕ"), ("i", "ㅑ", "ㅑ"), ("o", "ㅐ", "ㅒ"), ("p", "ㅔ", "ㅖ")
        ],
        [
            ("a", "ㅁ", "ㅁ"), ("s", "ㄴ", "ㄴ"), ("d", "ㅇ", "ㅇ"), ("f", "ㄹ", "ㄹ"), ("g", "ㅎ", "ㅎ"),
            ("h", "ㅗ", "ㅗ"), ("j", "ㅓ", "ㅓ"), ("k", "ㅏ", "ㅏ"), ("l", "ㅣ", "ㅣ")
        ],
        [
            ("z", "ㅋ", "ㅋ"), ("x", "ㅌ", "ㅌ"), ("c", "ㅊ", "ㅊ"), ("v", "ㅍ", "ㅍ"),
            ("b", "ㅠ", "ㅠ"), ("n", "ㅜ", "ㅜ"), ("m", "ㅡ", "ㅡ")
        ]
    ]

    /// Maps lowercase ASCII physical key to (unshifted, shifted) Hangul jamo.
    static let byQWERTY: [Character: (normal: Character, shifted: Character)] = {
        var map: [Character: (Character, Character)] = [:]
        for row in rows {
            for entry in row {
                map[entry.key] = (entry.normal, entry.shifted)
            }
        }
        return map
    }()

    /// Maps any 2-beolsik jamo (including shifted double consonants/vowels) back to
    /// its physical QWERTY key position `(row, col)` in normalized keycap coordinates.
    static let keyPosition: [Character: (x: Double, y: Double)] = {
        // Row offsets match standard QWERTY stagger: row 0 = 0.0, row 1 = 0.5, row 2 = 1.5
        let rowOffsets: [Double] = [0.0, 0.5, 1.5]
        var map: [Character: (Double, Double)] = [:]
        for (r, row) in rows.enumerated() {
            for (c, entry) in row.enumerated() {
                let pos = (Double(c) + rowOffsets[r], Double(r))
                map[entry.normal] = pos
                map[entry.shifted] = pos
            }
        }
        return map
    }()

    /// Physical neighbor jamo within Euclidean distance <= 1.25 key units (including
    /// shifted counterparts on the same key, e.g. ㄱ <-> ㄲ, ㅐ <-> ㅒ).
    static let neighbors: [Character: Set<Character>] = {
        let allJamo = Array(keyPosition.keys)
        var map: [Character: Set<Character>] = [:]
        for a in allJamo {
            guard let pa = keyPosition[a] else { continue }
            var set: Set<Character> = []
            for b in allJamo where b != a {
                guard let pb = keyPosition[b] else { continue }
                let dx = pa.x - pb.x
                let dy = pa.y - pb.y
                if dx * dx + dy * dy <= 1.25 * 1.25 {
                    set.insert(b)
                }
            }
            map[a] = set
        }
        return map
    }()

    /// Whether `a` and `b` are adjacent (or share the same physical key via Shift) on KS X 5002.
    static func areNeighbors(_ a: Character, _ b: Character) -> Bool {
        neighbors[a]?.contains(b) ?? false
    }

    /// Returns the jamo for a physical QWERTY letter key under the given Shift state.
    static func jamo(forQWERTY key: Character, shifted: Bool) -> Character? {
        guard let pair = byQWERTY[Character(String(key).lowercased())] else { return nil }
        return shifted ? pair.shifted : pair.normal
    }

    /// Whether Shift changes this physical QWERTY key's displayed jamo (q, w, e, r, t, o, p).
    static func hasShiftedVariant(forQWERTY key: Character) -> Bool {
        guard let pair = byQWERTY[Character(String(key).lowercased())] else { return false }
        return pair.normal != pair.shifted
    }

    /// Standard Korean letter names for VoiceOver accessibility labels.
    static let voiceOverNames: [Character: String] = [
        "ㄱ": "기역", "ㄲ": "쌍기역",
        "ㄴ": "니은",
        "ㄷ": "디귿", "ㄸ": "쌍디귿",
        "ㄹ": "리을",
        "ㅁ": "미음",
        "ㅂ": "비읍", "ㅃ": "쌍비읍",
        "ㅅ": "시옷", "ㅆ": "쌍시옷",
        "ㅇ": "이응",
        "ㅈ": "지읒", "ㅉ": "쌍지읒",
        "ㅊ": "치읓",
        "ㅋ": "키읔",
        "ㅌ": "티읕",
        "ㅍ": "피읖",
        "ㅎ": "히읗",
        "ㅏ": "아", "ㅐ": "애", "ㅑ": "야", "ㅒ": "얘",
        "ㅓ": "어", "ㅔ": "에", "ㅕ": "여", "ㅖ": "예",
        "ㅗ": "오", "ㅛ": "요",
        "ㅜ": "우", "ㅠ": "유",
        "ㅡ": "으", "ㅣ": "이"
    ]

    static func voiceOverLabel(for jamo: Character) -> String {
        voiceOverNames[jamo] ?? String(jamo)
    }
}
