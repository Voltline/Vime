#!/usr/bin/env python3
"""Build mmap-friendly sorted binary Korean lexicon + bigram table (VKL1).

Usage:
    python3 Scripts/build_korean_lexicon.py \
        --wordfreq /path/to/wordfreq-3.1.1-py3-none-any.whl \
        --mecab /path/to/python_mecab_ko_dic-2.1.1.post2-py3-none-any.whl \
        --tatoeba /path/to/kor_sentences.tsv.bz2 \
        [--blocklist /path/to/korean_blocklist.txt] \
        [--output Shared/Resources/KoreanLexicon.bin]

Upstream licenses (all GPL-3.0-or-later & App Store compatible):
- wordfreq (ko): CC BY-SA 4.0 (Robyn Speer)
- mecab-ko-dic: Apache 2.0 (Eunjeon Project)
- Tatoeba (kor): CC BY 2.0 FR (Tatoeba contributors)
"""

import argparse
import bz2
import gzip
import hashlib
import json
import math
import re
import struct
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

import msgpack

HANGUL_BASE = 0xAC00
HANGUL_END = 0xD7A3
HANGUL_RE = re.compile(r"^[\uAC00-\uD7A3]+$")
TOKEN_RE = re.compile(r"[\uAC00-\uD7A3]+")

CHOSEONG = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"
JUNGSEONG = "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ"
JONGSEONG = [
    "", "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ",
    "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ",
    "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
]

SPLIT_VOWEL = {
    9: (8, 0), 10: (8, 1), 11: (8, 20),
    14: (13, 4), 15: (13, 5), 16: (13, 20),
    19: (18, 20),
}
SPLIT_JONG = {
    3: (1, 9), 5: (4, 12), 6: (4, 18),
    9: (8, 0), 10: (8, 6), 11: (8, 7), 12: (8, 9),
    13: (8, 16), 14: (8, 17), 15: (8, 18), 18: (17, 9),
}

# Fixed SipHash-2-4 key (must match KoreanLexicon.swift).
SIPHASH_K0 = 0x564B_4C31_4B4F_5230
SIPHASH_K1 = 0x9E37_79B9_7F4A_7C15

# Tatoeba corpus has heavy over-representation of example character names.
TATOEBA_BIAS_PREFIXES = ("톰", "메리", "존", "사미", "보스턴", "레일라")

# Everyday conversational words and bigrams to ensure natural mobile chat ranking.
CORE_CONVERSATIONAL_WORDS = [
    "안녕하세요", "안녕", "감사합니다", "고맙습니다", "고마워요", "고마워",
    "죄송합니다", "미안해요", "미안해", "괜찮아요", "괜찮아", "알겠습니다",
    "알겠어요", "알았어", "네", "아니요", "아니야", "맞아요", "맞아",
    "좋아요", "좋아", "좋아해요", "사랑해요", "사랑해", "보고싶어요", "보고싶어",
    "수고하셨습니다", "수고했어요", "수고해", "잘자요", "잘자", "안녕히",
    "계세요", "가세요", "주무세요", "오랜만이에요", "오랜만이야", "반가워요",
    "반갑습니다", "축하해요", "축하합니다", "화이팅", "파이팅", "힘내세요",
    "어디에요", "어디야", "뭐해요", "뭐해", "지금", "오늘", "내일", "어제",
    "주말", "시간", "약속", "저녁", "점심", "아침", "커피", "식사",
    "있어요", "없어요", "할게요", "갈게요", "올게요", "볼게요", "줄게요",
    "먹었어요", "먹을까요", "갈까요", "할까요", "볼까요", "만나요", "연락해요",
    "부탁드립니다", "부탁해요", "확인했습니다", "확인했어요", "보냈어요",
    "도착했어요", "출발했어요", "잠시만요", "잠깐만요", "기다려요", "조금만",
    "정말", "진짜", "너무", "많이", "조금", "아마", "혹시", "근데", "그래서",
    "그런데", "하지만", "그리고", "그러면", "그럼", "어떻게", "왜요", "무슨",
    "어느", "언제", "얼마나", "누구", "무엇", "어디",
]

CORE_CONVERSATIONAL_BIGRAMS = [
    ("안녕히", "계세요", 120), ("안녕히", "가세요", 120), ("안녕히", "주무세요", 100),
    ("잘", "지내세요", 90), ("잘", "지냈어", 80), ("잘", "부탁드립니다", 110),
    ("잘", "부탁해요", 90), ("잘", "먹겠습니다", 100), ("잘", "먹었습니다", 95),
    ("정말", "감사합니다", 120), ("정말", "죄송합니다", 100), ("정말", "고마워요", 95),
    ("정말", "좋아요", 85), ("너무", "좋아요", 100), ("너무", "고마워요", 90),
    ("너무", "감사합니다", 90), ("너무", "예뻐요", 70), ("너무", "맛있어요", 80),
    ("오늘", "날씨", 90), ("오늘", "하루도", 80), ("오늘", "저녁", 85),
    ("오늘", "시간", 85), ("내일", "봐요", 100), ("내일", "만나요", 90),
    ("내일", "시간", 80), ("지금", "어디", 95), ("지금", "어디야", 95),
    ("지금", "뭐해", 95), ("지금", "가고", 85), ("지금", "출발해요", 80),
    ("잠시만", "기다려", 90), ("조금", "늦을", 85), ("조금만", "기다려", 90),
    ("확인", "부탁드립니다", 100), ("확인", "후", 80), ("좋은", "하루", 110),
    ("하루", "보내세요", 110), ("주말", "잘", 95), ("생일", "축하해요", 110),
    ("생일", "축하해", 100), ("새해", "복", 110), ("복", "많이", 110),
    ("많이", "받으세요", 110), ("수고", "많으셨습니다", 100), ("고생", "많으셨습니다", 95),
    ("감사", "드립니다", 90), ("부탁", "드립니다", 90), ("죄송", "합니다", 85),
    ("다음에", "또", 90), ("다음에", "봐요", 90), ("이따가", "봐요", 95),
    ("이따가", "연락할게요", 90), ("도착하면", "연락할게요", 95), ("집에", "가고", 85),
    ("집에", "도착했어요", 90), ("밥", "먹었어", 95), ("밥", "먹었어요", 95),
    ("커피", "한잔", 90), ("무슨", "일이야", 85), ("무슨", "일이에요", 85),
    ("어떻게", "지내세요", 90), ("어떻게", "해요", 80), ("괜찮은", "것", 80),
    ("할", "수", 120), ("수", "있어요", 115), ("수", "없어요", 110),
    ("수", "있습니다", 105), ("수", "없습니다", 100), ("것", "같아요", 120),
    ("것", "같아", 110), ("것", "같습니다", 105),
]

FLAG_NOUN = 1 << 0
FLAG_VERB_ADJ = 1 << 1
FLAG_COMMON_WORD = 1 << 2


def rotl64(x: int, b: int) -> int:
    return ((x << b) | (x >> (64 - b))) & 0xFFFF_FFFF_FFFF_FFFF


def siphash24(data: bytes, k0: int = SIPHASH_K0, k1: int = SIPHASH_K1) -> int:
    v0 = k0 ^ 0x736F_6D65_7073_6575
    v1 = k1 ^ 0x646F_7261_6E64_6F6D
    v2 = k0 ^ 0x6C79_6765_6E65_7261
    v3 = k1 ^ 0x7465_6462_7974_6573

    def sipround():
        nonlocal v0, v1, v2, v3
        v0 = (v0 + v1) & 0xFFFF_FFFF_FFFF_FFFF
        v1 = rotl64(v1, 13) ^ v0
        v0 = rotl64(v0, 32)
        v2 = (v2 + v3) & 0xFFFF_FFFF_FFFF_FFFF
        v3 = rotl64(v3, 16) ^ v2
        v0 = (v0 + v3) & 0xFFFF_FFFF_FFFF_FFFF
        v3 = rotl64(v3, 21) ^ v0
        v2 = (v2 + v1) & 0xFFFF_FFFF_FFFF_FFFF
        v1 = rotl64(v1, 17) ^ v2
        v2 = rotl64(v2, 32)

    n = len(data)
    end = n - (n % 8)
    for i in range(0, end, 8):
        m = int.from_bytes(data[i:i + 8], "little")
        v3 ^= m
        sipround()
        sipround()
        v0 ^= m
    b = (n & 0xFF) << 56
    for i in range(n - end):
        b |= data[end + i] << (8 * i)
    v3 ^= b
    sipround()
    sipround()
    v0 ^= b
    v2 ^= 0xFF
    for _ in range(4):
        sipround()
    return (v0 ^ v1 ^ v2 ^ v3) & 0xFFFF_FFFF_FFFF_FFFF


def decompose_to_jamo(word: str) -> str:
    out = []
    for ch in word:
        code = ord(ch)
        if HANGUL_BASE <= code <= HANGUL_END:
            offset = code - HANGUL_BASE
            cho = offset // (21 * 28)
            jung = (offset % (21 * 28)) // 28
            jong = offset % 28
            out.append(CHOSEONG[cho])
            if jung in SPLIT_VOWEL:
                v1, v2 = SPLIT_VOWEL[jung]
                out.append(JUNGSEONG[v1])
                out.append(JUNGSEONG[v2])
            else:
                out.append(JUNGSEONG[jung])
            if jong != 0:
                if jong in SPLIT_JONG:
                    j1, c2 = SPLIT_JONG[jong]
                    out.append(JONGSEONG[j1])
                    out.append(CHOSEONG[c2])
                else:
                    out.append(JONGSEONG[jong])
        else:
            out.append(ch)
    return "".join(out)


def load_wordfreq(path: Path) -> dict[str, int]:
    if path.suffix == ".whl":
        with zipfile.ZipFile(path) as z:
            raw = z.read("wordfreq/data/small_ko.msgpack.gz")
    else:
        raw = path.read_bytes()
    data = msgpack.unpackb(gzip.decompress(raw))
    result: dict[str, int] = {}
    for cb, bucket in enumerate(data[1:]):
        for word in bucket:
            if HANGUL_RE.match(word) and 1 <= len(word) <= 10:
                if word not in result:
                    result[word] = cb
    return result


def load_mecab(path: Path) -> tuple[dict[str, int], set[str]]:
    if path.suffix == ".whl":
        with zipfile.ZipFile(path) as z:
            sysdic = z.read("mecab_ko_dic/dictionary/sys.dic")
    else:
        sysdic = path.read_bytes()
    _, _, _, lexsize, _, _, dsize, tsize, _, _ = struct.unpack_from("<IIIIIIIIII", sysdic, 0)
    token_off = 72 + dsize
    feat_off = token_off + tsize
    nouns: dict[str, int] = {}
    verbs: set[str] = set()
    for i in range(lexsize):
        _, _, _, wcost, fpos, _ = struct.unpack_from("<HHHhII", sysdic, token_off + i * 16)
        end = sysdic.index(b"\x00", feat_off + fpos)
        feat = sysdic[feat_off + fpos:end].decode("utf-8", "ignore")
        parts = feat.split(",")
        if len(parts) < 4:
            continue
        pos, surface = parts[0], parts[3]
        if not (1 <= len(surface) <= 10 and HANGUL_RE.match(surface)):
            continue
        if pos in ("NNG", "NNP", "NP"):
            if surface not in nouns or wcost < nouns[surface]:
                nouns[surface] = wcost
        elif pos in ("VV", "VA"):
            verbs.add(surface)
    return nouns, verbs


def is_tatoeba_biased(word: str) -> bool:
    return any(word.startswith(p) for p in TATOEBA_BIAS_PREFIXES)


def load_tatoeba(path: Path) -> tuple[Counter, Counter]:
    raw = bz2.decompress(path.read_bytes()).decode("utf-8")
    eojeols: Counter = Counter()
    bigrams: Counter = Counter()
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        words = TOKEN_RE.findall(parts[2])
        for w in words:
            if 1 <= len(w) <= 10 and not is_tatoeba_biased(w):
                eojeols[w] += 1
        for a, b in zip(words, words[1:]):
            if 1 <= len(a) <= 10 and 1 <= len(b) <= 10:
                if not is_tatoeba_biased(a) and not is_tatoeba_biased(b):
                    bigrams[(a, b)] += 1
    return eojeols, bigrams


def load_blocklist(path: Path | None) -> set[str]:
    if path is None or not path.exists():
        return set()
    terms = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        w = line.strip()
        if w and not w.startswith("#"):
            terms.add(w)
    return terms


def is_blocked(word: str, blocked: set[str]) -> bool:
    if not blocked:
        return False
    if word in blocked:
        return True
    return any(len(term) >= 2 and term in word for term in blocked)


def build_binary(
    wordfreq_path: Path,
    mecab_path: Path,
    tatoeba_path: Path,
    output_path: Path,
    blocklist_path: Path | None = None,
    max_words: int = 42000,
    max_bigrams: int = 12000,
) -> dict:
    wf = load_wordfreq(wordfreq_path)
    nouns, verbs = load_mecab(mecab_path)
    eojeols, tatoeba_bigrams = load_tatoeba(tatoeba_path)
    blocked = load_blocklist(blocklist_path)

    # Single-character particles/bound morphemes from wordfreq that should not dominate completions.
    isolated_bound_morphemes = {
        "은", "는", "이", "가", "을", "를", "의", "에", "도", "만", "로", "과", "와",
        "하", "다", "고", "지", "어", "아", "게", "기", "했", "었", "았", "되", "해",
        "들", "며", "면", "서", "니", "라", "자", "냐", "야", "요", "죠", "네", "까",
        "습", "니", "었", "겠", "시", "으", "적", "인", "된", "될", "할", "한", "함",
    }

    scores: dict[str, int] = {}
    flags: dict[str, int] = defaultdict(int)

    # 1. wordfreq core vocabulary
    for word, cb in wf.items():
        if is_blocked(word, blocked):
            continue
        if len(word) == 1 and word in isolated_bound_morphemes and word not in ("네", "이", "다", "한", "할"):
            continue
        # cb is typically 120..599; map lower cb (more frequent) to higher UInt16 score.
        score = max(4000, min(62000, int(65535 - cb * 95)))
        if len(word) == 1:
            score = min(score, 32000)
        scores[word] = max(scores.get(word, 0), score)
        if word in nouns:
            flags[word] |= FLAG_NOUN
        if word in verbs:
            flags[word] |= FLAG_VERB_ADJ
        if len(word) >= 2:
            flags[word] |= FLAG_COMMON_WORD

    # 2. Tatoeba conversational eojeols (inflected forms & spoken phrases)
    for word, count in eojeols.most_common(15000):
        if is_blocked(word, blocked):
            continue
        if len(word) == 1 and count < 15:
            continue
        if count < 2 and len(word) > 6:
            continue
        tscore = min(63000, int(18000 + math.log2(count + 1) * 5800))
        if len(word) == 1:
            tscore = min(tscore, 34000)
        scores[word] = max(scores.get(word, 0), tscore)
        flags[word] |= FLAG_COMMON_WORD
        if word in nouns:
            flags[word] |= FLAG_NOUN

    # 3. Core conversational words
    for rank, word in enumerate(CORE_CONVERSATIONAL_WORDS):
        if is_blocked(word, blocked):
            continue
        cscore = max(52000, 64500 - rank * 60)
        scores[word] = max(scores.get(word, 0), cscore)
        flags[word] |= FLAG_COMMON_WORD
        if word in nouns:
            flags[word] |= FLAG_NOUN

    # 4. High-frequency mecab-ko-dic common nouns not yet covered
    mecab_sorted_nouns = sorted(
        ((wcost, w) for w, wcost in nouns.items() if 2 <= len(w) <= 6 and w not in scores and not is_blocked(w, blocked)),
        key=lambda item: (item[0], item[1]),
    )
    remaining_budget = max(0, max_words - len(scores))
    for idx, (wcost, word) in enumerate(mecab_sorted_nouns[: min(10000, remaining_budget)]):
        mscore = max(1500, min(14000, int(14000 - idx * 1.1)))
        scores[word] = mscore
        flags[word] |= FLAG_NOUN | FLAG_COMMON_WORD

    # Keep top max_words by score, then sort lexicographically by decomposed jamo UTF-8 bytes.
    top_words = sorted(scores.items(), key=lambda item: (-item[1], item[0]))[:max_words]
    word_entries = []
    for surface, score in top_words:
        jamo_bytes = decompose_to_jamo(surface).encode("utf-8")
        surface_bytes = surface.encode("utf-8")
        word_entries.append((jamo_bytes, surface_bytes, surface, score, flags[surface]))

    word_entries.sort(key=lambda item: (item[0], -item[3], item[1]))
    surface_to_index = {entry[2]: idx for idx, entry in enumerate(word_entries)}

    # 5. Build next-word bigram table
    combined_bigrams: dict[tuple[str, str], int] = {}
    for (prev_w, next_w), count in tatoeba_bigrams.items():
        if count < 2:
            continue
        if next_w not in surface_to_index:
            continue
        if is_blocked(prev_w, blocked) or is_blocked(next_w, blocked):
            continue
        if len(next_w) == 1 and count < 10:
            continue
        bscore = min(60000, int(10000 + math.log2(count + 1) * 7000))
        combined_bigrams[(prev_w, next_w)] = max(combined_bigrams.get((prev_w, next_w), 0), bscore)

    for prev_w, next_w, weight in CORE_CONVERSATIONAL_BIGRAMS:
        if next_w in surface_to_index and not is_blocked(prev_w, blocked) and not is_blocked(next_w, blocked):
            bscore = min(65000, 35000 + weight * 220)
            combined_bigrams[(prev_w, next_w)] = max(combined_bigrams.get((prev_w, next_w), 0), bscore)

    # Cap to top 10 next words per previous word, and overall max_bigrams.
    by_prev: dict[str, list[tuple[int, int, str]]] = defaultdict(list)
    for (prev_w, next_w), bscore in combined_bigrams.items():
        by_prev[prev_w].append((bscore, surface_to_index[next_w], next_w))

    bigram_records = []
    for prev_w, items in by_prev.items():
        items.sort(key=lambda x: (-x[0], x[1]))
        prev_hash = siphash24(prev_w.encode("utf-8"))
        for bscore, next_idx, _ in items[:10]:
            bigram_records.append((prev_hash, next_idx, bscore))

    if len(bigram_records) > max_bigrams:
        bigram_records.sort(key=lambda x: (-x[2], x[0], x[1]))
        bigram_records = bigram_records[:max_bigrams]

    # Sort bigrams by (prev_hash ASC, score DESC, next_idx ASC) for O(log B) lookup.
    bigram_records.sort(key=lambda x: (x[0], -x[2], x[1]))

    # 6. Serialize binary format VKL1
    # Header (32 bytes):
    #   4s magic ("VKL1")
    #   I  version (1)
    #   I  word_count
    #   I  bigram_count
    #   I  words_offset
    #   I  bigrams_offset
    #   I  strings_offset
    #   I  reserved (0)
    # Word record (16 bytes):
    #   I  jamo_offset (relative to strings_offset)
    #   H  jamo_len
    #   H  surface_len
    #   I  surface_offset (relative to strings_offset)
    #   H  freq
    #   B  flags
    #   B  reserved (0)
    # Bigram record (16 bytes):
    #   Q  prev_hash
    #   I  next_word_index
    #   H  score
    #   H  reserved (0)
    header_size = 32
    word_count = len(word_entries)
    bigram_count = len(bigram_records)
    words_offset = header_size
    bigrams_offset = words_offset + word_count * 16
    strings_offset = bigrams_offset + bigram_count * 16

    string_pool = bytearray()
    word_blob = bytearray()
    for jamo_bytes, surface_bytes, _, score, flg in word_entries:
        jamo_off = len(string_pool)
        string_pool.extend(jamo_bytes)
        surf_off = len(string_pool)
        string_pool.extend(surface_bytes)
        word_blob.extend(
            struct.pack(
                "<IHH I HBB".replace(" ", ""),
                jamo_off,
                len(jamo_bytes),
                len(surface_bytes),
                surf_off,
                score,
                flg,
                0,
            )
        )

    bigram_blob = bytearray()
    for prev_hash, next_idx, bscore in bigram_records:
        bigram_blob.extend(struct.pack("<QIHH", prev_hash, next_idx, bscore, 0))

    header = struct.pack(
        "<4sIIIIIII",
        b"VKL1",
        1,
        word_count,
        bigram_count,
        words_offset,
        bigrams_offset,
        strings_offset,
        0,
    )

    payload = bytes(header + word_blob + bigram_blob + string_pool)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(payload)

    return {
        "output": str(output_path),
        "bytes": len(payload),
        "wordCount": word_count,
        "nounCount": sum(1 for e in word_entries if e[4] & FLAG_NOUN),
        "bigramCount": bigram_count,
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wordfreq", type=Path, required=True)
    parser.add_argument("--mecab", type=Path, required=True)
    parser.add_argument("--tatoeba", type=Path, required=True)
    parser.add_argument("--blocklist", type=Path, default=None)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "Shared/Resources/KoreanLexicon.bin",
    )
    args = parser.parse_args()
    summary = build_binary(
        wordfreq_path=args.wordfreq,
        mecab_path=args.mecab,
        tatoeba_path=args.tatoeba,
        output_path=args.output,
        blocklist_path=args.blocklist,
    )
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
