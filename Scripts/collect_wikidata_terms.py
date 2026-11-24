#!/usr/bin/env python3
"""Collects candidate game and game character names from Wikidata for review.

    python3 Scripts/collect_wikidata_terms.py <generated vime_pinyin.dict.yaml> \
        <review.md> [--cache DIR]

Wikidata (CC0) is queried through its search and entity APIs rather than the
SPARQL endpoint, whose per-client time quota and outages made bulk queries
unreliable. Each domain lists items of some classes that carry a Chinese
label; their labels, dates, developers and sitelink counts (the popularity
measure) come from wbgetentities, fifty at a time. Every response is cached,
so an interrupted run picks up where it stopped.

The output is a Markdown sheet for a person to review. Nothing here edits
Scripts/rime_words.txt: approved words are copied there by hand. It needs
pypinyin and opencc-python-reimplemented, and runs only on a development
machine; the app itself never goes online.
"""

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from opencc import OpenCC
from pypinyin import Style, lazy_pinyin

API = "https://www.wikidata.org/w/api.php"
USER_AGENT = "VimeLexiconScript/1.0 (offline dictionary build)"
LANGUAGES = ["zh-cn", "zh-hans", "zh-sg", "zh", "zh-hant", "zh-tw", "zh-hk", "zh-mo", "en"]
SIMPLIFIED = ["zh-cn", "zh-hans", "zh-sg"]
ANY_CHINESE = "haslabel:" + ",".join(code for code in LANGUAGES if code != "en")
SEARCH_LIMIT = 500
SEARCH_WINDOW = 10_000
ROWS_PER_DOMAIN = 150
MIXED_ROWS_PER_DOMAIN = 40

HAN = "㐀-䶿一-鿿\U00020000-\U0003134f"
PURE_HAN = re.compile(f"^[{HAN}]{{2,8}}$")
HAS_HAN = re.compile(f"[{HAN}]")
MIXED = re.compile(f"^[{HAN}A-Za-z0-9 .+\\-]+$")
NAME_DOT = re.compile("[·・•‧]")
CHARACTER_CLASS = re.compile(r"character|fictional|角色|人物|虚构|虛構", re.IGNORECASE)


@dataclass
class Domain:
    key: str
    title: str
    classes: list
    allowed: set = field(default_factory=set)  # characters: classes that are characters


DOMAINS = [
    Domain("games", "电子游戏", ["Q7889"]),
    Domain("characters", "游戏角色", []),
]

GAME_MIN_YEAR = 2015
RECENT_YEAR = 2020
GAME_CLASSIC_SITELINKS = 15
CHARACTER_MIN_SITELINKS = 3

VENDORS = [
    ("米哈游", ["mihoyo", "hoyoverse", "米哈游", "cognosphere"]),
    ("库洛（鸣潮）", ["kuro game", "库洛"]),
    ("腾讯", ["tencent", "腾讯", "timi", "天美", "lightspeed", "光子"]),
    ("网易", ["netease", "网易"]),
]


class Client:
    def __init__(self, cache: Path):
        self.cache = cache
        cache.mkdir(parents=True, exist_ok=True)
        self.last = 0.0
        self.calls = 0
        # Anonymous API clients are rate limited; slow down on each 429 and
        # speed up again gradually while requests go through.
        self.spacing = 1.0

    def get(self, params):
        params = {**params, "format": "json", "formatversion": "2"}
        key = hashlib.sha256(json.dumps(params, sort_keys=True).encode()).hexdigest()[:32]
        path = self.cache / f"{key}.json"
        if path.exists():
            return json.loads(path.read_text())
        url = API + "?" + urllib.parse.urlencode(params)
        delay = 5.0
        for attempt in range(10):
            wait = self.last + self.spacing - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            self.last = time.monotonic()
            self.calls += 1
            try:
                request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(request, timeout=60) as response:
                    data = json.loads(response.read())
                if "error" in data:
                    raise RuntimeError(data["error"].get("info", data["error"]))
                path.write_text(json.dumps(data, ensure_ascii=False))
                self.spacing = max(1.0, self.spacing * 0.97)
                return data
            except urllib.error.HTTPError as error:
                retry = error.headers.get("Retry-After")
                pause = float(retry) if retry and retry.isdigit() else delay
                if error.code == 429:
                    self.spacing = min(self.spacing * 1.5, 30.0)
                print(f"  HTTP {error.code}, waiting {pause:.0f} s, spacing now {self.spacing:.1f} s", file=sys.stderr)
            except (urllib.error.URLError, json.JSONDecodeError, TimeoutError, RuntimeError) as error:
                pause = delay
                print(f"  {type(error).__name__}: {error}; waiting {pause:.0f} s", file=sys.stderr)
            time.sleep(pause)
            delay = min(delay * 2, 300)
        raise SystemExit(f"giving up on {url}")

    def search(self, query):
        """Every item id the search returns, past the 10,000-result window
        by reading it from both ends of the creation order."""
        ids, total = [], None
        for order in ["create_timestamp_asc", "create_timestamp_desc"]:
            offset = 0
            while offset < SEARCH_WINDOW:
                data = self.get({"action": "query", "list": "search", "srsearch": query, "srnamespace": 0,
                                 "srlimit": SEARCH_LIMIT, "sroffset": offset, "srprop": "", "srinfo": "totalhits",
                                 "srsort": order})
                total = data["query"]["searchinfo"]["totalhits"]
                ids += [hit["title"] for hit in data["query"]["search"]]
                if "continue" not in data:
                    break
                offset = data["continue"]["sroffset"]
            if total <= SEARCH_WINDOW:
                break
        unique = list(dict.fromkeys(ids))
        if total and len(unique) < total:
            print(f"  {query[:80]}: {len(unique)} of {total} reachable", file=sys.stderr)
        return unique

    def entities(self, ids, store):
        missing = [i for i in dict.fromkeys(ids) if i not in store]
        for start in range(0, len(missing), 50):
            batch = missing[start:start + 50]
            data = self.get({"action": "wbgetentities", "ids": "|".join(batch),
                             "props": "labels|claims|sitelinks", "languages": "|".join(LANGUAGES)})
            for qid, entity in data.get("entities", {}).items():
                store[qid] = summarize(entity) if "missing" not in entity else None
            for qid in batch:
                store.setdefault(qid, None)
            if start // 50 % 20 == 19:
                print(f"  entities {start + 50}/{len(missing)}", file=sys.stderr)
        return {i: store[i] for i in ids if store.get(i)}


def summarize(entity):
    claims = entity.get("claims", {})

    def values(prop):
        out = []
        for claim in claims.get(prop, []):
            snak = claim.get("mainsnak", {})
            if snak.get("snaktype") == "value" and claim.get("rank") != "deprecated":
                out.append(snak["datavalue"]["value"])
        return out

    def items(*props):
        return [v["id"] for p in props for v in values(p) if isinstance(v, dict) and "id" in v]

    years = []
    for prop in ["P577", "P571"]:
        for value in values(prop):
            match = re.match(r"^\+(\d{4})", value.get("time", "")) if isinstance(value, dict) else None
            if match:
                years.append(int(match.group(1)))
    return {
        "labels": {code: label["value"] for code, label in entity.get("labels", {}).items()},
        "sitelinks": len(entity.get("sitelinks", {})),
        "year": min(years) if years else None,
        "classes": items("P31"),
        "developers": items("P178"),
        "publishers": items("P123"),
        "works": items("P1441", "P8345"),
    }


def chinese_label(labels, t2s):
    """The simplified label to type, and whether it was converted from traditional."""
    # Simplified labels are converted too: some still hold traditional characters.
    for code in SIMPLIFIED + ["zh", "zh-hant", "zh-tw", "zh-hk", "zh-mo"]:
        if code in labels:
            label = labels[code]
            simplified = t2s.convert(label)
            return simplified, simplified != label
    return None, False


def load_dictionary(path):
    """Every word with its readings, and each character's readings by weight."""
    words, readings = {}, {}
    with open(path, encoding="utf-8") as handle:
        body = False
        for line in handle:
            if not body:
                body = line.strip() == "..."
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            words.setdefault(parts[0], set()).add(parts[1])
            if len(parts[0]) == 1:
                weight = float(parts[2]) if len(parts) > 2 and parts[2] else 0.0
                readings.setdefault(parts[0], {})[parts[1]] = weight
    return words, readings


def load_listed(path):
    listed = set()
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            listed.add(line.split("\t")[0])
    return listed


def spell(word, words, readings, valid):
    """pypinyin's reading of the word, checked against the dictionary.

    A polyphonic character is settled when a dictionary word inside the term
    covers it with the same reading; one that a dictionary word reads
    differently is flagged as a likely mistake."""
    syllables = lazy_pinyin(word, style=Style.NORMAL, v_to_u=False, errors=lambda c: ["?"] * len(c))
    flags = []
    if len(syllables) != len(word) or any(s not in valid for s in syllables):
        return " ".join(syllables), ["音节无效"]
    settled, conflicts = set(), set()
    for start in range(len(word)):
        for end in range(start + 2, len(word) + 1):
            spelled = words.get(word[start:end])
            if not spelled:
                continue
            ours = " ".join(syllables[start:end])
            if ours in spelled:
                settled.update(range(start, end))
            else:
                conflicts.add(f"{word[start:end]}：词库读 {sorted(spelled)[0]}")
    polyphonic = []
    for index, (char, syllable) in enumerate(zip(word, syllables)):
        known = readings.get(char, {})
        top = max(known.values(), default=0.0)
        common = [s for s, w in known.items() if top and w >= top * 0.05]
        if known and syllable not in known:
            flags.append(f"读音存疑（{char}）")
        elif len(common) > 1 and index not in settled:
            polyphonic.append(char)
    if polyphonic:
        flags.append("多音字待核（" + "".join(dict.fromkeys(polyphonic)) + "）")
    flags += [f"读音与词库不同（{c}）" for c in sorted(conflicts)]
    return " ".join(syllables), flags


def vendor_of(item, maker_labels):
    """The vendor by developer, or by publisher when no developer matches."""
    label = " ".join(item["labels"].values()).lower()
    for makers in [item["developers"], item["publishers"]]:
        names = " ".join(maker_labels.get(m, "") for m in makers).lower()
        for vendor, needles in VENDORS:
            if any(n in names for n in needles):
                return vendor
    if "鸣潮" in label or "wuthering waves" in label:
        return "库洛（鸣潮）"
    return "其他"


def keep(domain, item):
    if domain.key == "games":
        year = item["year"]
        return (year is not None and year >= GAME_MIN_YEAR) or item["sitelinks"] >= GAME_CLASSIC_SITELINKS
    if domain.key == "characters":
        return item["sitelinks"] >= CHARACTER_MIN_SITELINKS and bool(set(item["classes"]) & domain.allowed)
    return True


def candidates(client, store, domain, games):
    if domain.key == "characters":
        ids = []
        works = sorted(games)
        for start in range(0, len(works), 40):
            batch = works[start:start + 40]
            clause = "|".join(f"P1441={q}|P8345={q}" for q in batch)
            ids += client.search(f"haswbstatement:{clause} {ANY_CHINESE}")
    else:
        queries = [f"haswbstatement:P31={c} {ANY_CHINESE}" for c in domain.classes]
        ids = [qid for q in queries for qid in client.search(q)]
    ids = list(dict.fromkeys(ids))
    print(f"{domain.key}: {len(ids)} items with a Chinese label", file=sys.stderr)
    items = client.entities(ids, store)
    if domain.key == "characters":
        # "Present in work" also links real people, places and spells to
        # games; keep items whose class is some kind of character.
        classes = client.entities(sorted({c for i in items.values() for c in i["classes"]}), store)
        domain.allowed = {q for q, c in classes.items()
                          if CHARACTER_CLASS.search(" ".join(c["labels"].values()))}
    return ids, items


def markdown_table(rows):
    lines = ["| 词 | 拼音 | QID | sitelinks | 年份 | 标记 |", "|---|---|---|---:|---:|---|"]
    for row in rows:
        lines.append(f"| {row['word']} | {row['pinyin']} | [{row['qid']}](https://www.wikidata.org/wiki/{row['qid']}) "
                     f"| {row['sitelinks']} | {row['year'] or ''} | {'；'.join(row['flags'])} |")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dictionary", type=Path, help="vime_pinyin.dict.yaml from build_rime_dicts.py")
    parser.add_argument("review", type=Path, help="Markdown review sheet to write")
    parser.add_argument("--cache", type=Path, default=Path("/private/tmp/vime-wikidata-cache"))
    parser.add_argument("--words", type=Path, default=Path(__file__).with_name("rime_words.txt"))
    parser.add_argument("--only", help="comma-separated domain keys to run (games always runs for characters)")
    args = parser.parse_args()

    t2s = OpenCC("t2s")
    words, readings = load_dictionary(args.dictionary)
    valid = {s for r in readings.values() for s in r}
    listed = load_listed(args.words)
    client = Client(args.cache / "api")
    store_path = args.cache / "entities.json"
    store = json.loads(store_path.read_text()) if store_path.exists() else {}
    only = set(args.only.split(",")) if args.only else None
    if only and "characters" in only:
        only.add("games")

    sections, games = [], set()
    try:
        for domain in DOMAINS:
            if only and domain.key not in only:
                continue
            ids, items = candidates(client, store, domain, games)
            store_path.write_text(json.dumps(store, ensure_ascii=False))
            kept = {q: i for q, i in items.items() if keep(domain, i)}
            if domain.key == "games":
                games = set(kept)
            game_vendor, maker_labels = {}, {}
            if domain.key == "games":
                makers = client.entities(sorted({m for i in kept.values() for m in i["developers"] + i["publishers"]}), store)
                maker_labels = {q: " ".join(m["labels"].values()) for q, m in makers.items()}
            elif domain.key == "characters":
                game_items = {q: store[q] for q in games if store.get(q)}
                makers = client.entities(sorted({m for g in game_items.values() for m in g["developers"] + g["publishers"]}), store)
                labels = {q: " ".join(m["labels"].values()) for q, m in makers.items()}
                game_vendor = {q: vendor_of(g, labels) for q, g in game_items.items()}

            main_rows, mixed_rows, seen = [], [], set()
            counts = {"found": len(ids), "kept": len(kept), "no_label": 0, "known": 0, "other": 0}
            for qid, item in sorted(kept.items(), key=lambda kv: -kv[1]["sitelinks"]):
                label, converted = chinese_label(item["labels"], t2s)
                if not label:
                    counts["no_label"] += 1
                    continue
                flags = ["转换"] if converted else []
                if NAME_DOT.search(label):
                    label = NAME_DOT.sub("", label)
                    flags.append("去掉间隔号")
                label = label.strip()
                if label in seen:
                    continue
                seen.add(label)
                if label in words or label in listed:
                    counts["known"] += 1
                    continue
                row = {"word": label, "qid": qid, "sitelinks": item["sitelinks"], "year": item["year"], "flags": flags}
                if domain.key == "games":
                    row["vendor"] = vendor_of(item, maker_labels)
                elif domain.key == "characters":
                    # A vendor only for characters of that vendor's games alone, so
                    # crossover and franchise characters stay under 其他.
                    vendors = {game_vendor.get(w, "其他") for w in item["works"]}
                    row["vendor"] = vendors.pop() if len(vendors) == 1 else "其他"
                if PURE_HAN.match(label):
                    row["pinyin"], spelled_flags = spell(label, words, readings, valid)
                    row["flags"] = flags + spelled_flags
                    main_rows.append(row)
                elif HAS_HAN.search(label) and MIXED.match(label) and re.search("[A-Za-z0-9]", label):
                    row["pinyin"] = ""
                    mixed_rows.append(row)
                else:
                    counts["other"] += 1
            counts["new"] = len(main_rows)
            counts["mixed"] = len(mixed_rows)
            sections.append((domain, main_rows, mixed_rows, counts))
            print(f"  {domain.key}: {counts}", file=sys.stderr)
    finally:
        store_path.write_text(json.dumps(store, ensure_ascii=False))

    write_review(args.review, sections)
    print(f"{client.calls} API calls; review written to {args.review}", file=sys.stderr)


def write_review(path, sections):
    out = ["# Wikidata 游戏与角色新词审阅表", "",
           "来源：Wikidata（CC0），通过搜索接口和 wbgetentities 抓取。热度是 sitelinks（有多少个维基语种条目）。",
           "已去掉生成词库 `vime_pinyin.dict.yaml`（含万象）和 `rime_words.txt` 里已有的词。",
           f"每个领域最多列 {ROWS_PER_DOMAIN} 条，按 sitelinks 降序。", "",
           "标记：转换 = 只有繁体名，已转简体；多音字待核；读音存疑 = pypinyin 的读音不在词库该字的读音里；"
           "读音与词库不同 = 词里某个词库已有的词读法不同；音节无效；去掉间隔号。", "",
           "## 总览", "",
           "| 领域 | 搜到 | 符合年份/热度 | 已在词库 | 新词（纯汉字） | 中英混合 |",
           "|---|---:|---:|---:|---:|---:|"]
    for domain, _, _, c in sections:
        out.append(f"| {domain.title} | {c['found']} | {c['kept']} | {c['known']} | {c['new']} | {c['mixed']} |")
    out.append("")
    for domain, rows, mixed, counts in sections:
        out += [f"## {domain.title}", ""]
        if domain.key in ("games", "characters"):
            named = [r for r in rows if r["vendor"] != "其他"]
            others = [r for r in rows if r["vendor"] == "其他"]
            shown = named + others[:max(0, ROWS_PER_DOMAIN - len(named))]
            out += [f"新词 {len(rows)} 条，列出 {len(shown)} 条，截掉 {len(rows) - len(shown)} 条。", ""]
            for vendor in [v for v, _ in VENDORS] + ["其他"]:
                group = [r for r in shown if r["vendor"] == vendor]
                if group:
                    out += [f"### {vendor}（{len(group)} 条）", ""] + markdown_table(group) + [""]
            if domain.key == "games":
                # The most-linked games are mostly classics; list recent ones too.
                recent = [r for r in rows if r not in shown and (r["year"] or 0) >= RECENT_YEAR]
                if recent:
                    out += [f"### {RECENT_YEAR} 年以后的其他新游戏（共 {len(recent)} 条，列前 "
                            f"{min(len(recent), ROWS_PER_DOMAIN)} 条）", ""]
                    out += markdown_table(recent[:ROWS_PER_DOMAIN]) + [""]
        else:
            shown = rows[:ROWS_PER_DOMAIN]
            out += [f"新词 {len(rows)} 条，列出 {len(shown)} 条，截掉 {len(rows) - len(shown)} 条。", ""]
            out += markdown_table(shown) + [""]
    out += ["## 附表：中英混合（不进主表）", ""]
    for domain, _, mixed, _ in sections:
        if not mixed:
            continue
        out += [f"### {domain.title}（共 {len(mixed)} 条，列前 {min(len(mixed), MIXED_ROWS_PER_DOMAIN)} 条）", "",
                "| 名称 | QID | sitelinks | 年份 |", "|---|---|---:|---:|"]
        for row in mixed[:MIXED_ROWS_PER_DOMAIN]:
            out.append(f"| {row['word']} | {row['qid']} | {row['sitelinks']} | {row['year'] or ''} |")
        out.append("")
    path.write_text("\n".join(out), encoding="utf-8")


if __name__ == "__main__":
    main()
