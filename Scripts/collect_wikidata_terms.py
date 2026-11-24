#!/usr/bin/env python3
"""Collects candidate names of games, anime, films, TV series and their
characters from Wikidata for review.

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
    works_from: str | None = None  # character domains: the domain whose works they appear in
    group: str = "origin"  # how the review groups rows: "vendor" or "origin" (country of origin)
    min_year: int | None = None  # with classic_sitelinks: keep newer items or well-known ones
    classic_sitelinks: int = 0
    min_sitelinks: int = 0
    allowed: set = field(default_factory=set)  # character domains: classes that are characters


# Country of origin (P495) slices let a search reach past its 10,000-result
# window, and they show where a name is likely the mainland one.
ORIGIN_SLICES = ["Q148", "Q8646", "Q865", "Q17", "Q884", "Q30"]

DOMAINS = [
    Domain("games", "电子游戏", ["Q7889"], group="vendor", min_year=2015, classic_sitelinks=15),
    Domain("characters", "游戏角色", [], works_from="games", group="vendor", min_sitelinks=3),
    # Anime series, anime films, manga series, manga.
    Domain("anime", "动画与漫画", ["Q63952888", "Q20650540", "Q21198342", "Q8274"], min_sitelinks=2),
    Domain("anime_characters", "动漫角色", [], works_from="anime", min_sitelinks=2),
    # Films and animated films.
    Domain("films", "电影", ["Q11424", "Q202866"], min_year=2015, classic_sitelinks=25, min_sitelinks=3),
    # Television series and miniseries.
    Domain("tv", "电视剧与剧集", ["Q5398426", "Q1259759"], min_year=2015, classic_sitelinks=15, min_sitelinks=2),
]

RECENT_YEAR = 2020
ROWS_PER_ORIGIN = 60  # per origin group: the most linked, then as many from RECENT_YEAR on

ORIGINS = [
    ("中国大陆", {"Q148"}),
    ("港澳台", {"Q8646", "Q865", "Q14773"}),
    ("日本", {"Q17"}),
    ("韩国", {"Q884"}),
]

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

    def get(self, params, cache=True):
        params = {**params, "format": "json", "formatversion": "2"}
        key = hashlib.sha256(json.dumps(params, sort_keys=True).encode()).hexdigest()[:32]
        path = self.cache / f"{key}.json"
        if cache and path.exists():
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
                if cache:
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

    def search(self, query, popular=False):
        """Every item id the search returns, past the 10,000-result window
        by reading it from both ends of the creation order; with popular, the
        most linked items are read first."""
        ids, total = [], None
        orders = ["create_timestamp_asc", "create_timestamp_desc"]
        for order in (["incoming_links_desc"] if popular else []) + orders:
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
            if len(set(ids)) >= total:
                break
        unique = list(dict.fromkeys(ids))
        if total and len(unique) < total:
            print(f"  {query[:80]}: {len(unique)} of {total} reachable", file=sys.stderr)
        return unique

    def entities(self, ids, store, refresh=False):
        """Summaries of the items, fetched fifty at a time into store. With
        refresh, summaries written before countries were recorded are fetched
        again. Film and series entities are large, so only the summaries in
        store are kept, not the raw responses."""
        missing = [i for i in dict.fromkeys(ids)
                   if i not in store or (refresh and store[i] is not None and "countries" not in store[i])]
        for start in range(0, len(missing), 50):
            batch = missing[start:start + 50]
            data = self.get({"action": "wbgetentities", "ids": "|".join(batch),
                             "props": "labels|claims|sitelinks", "languages": "|".join(LANGUAGES)}, cache=False)
            for qid, entity in data.get("entities", {}).items():
                store[qid] = summarize(entity) if "missing" not in entity else None
            for qid in batch:
                store.setdefault(qid, None)
            if start // 50 % 100 == 99:
                self.save(store)
            if start // 50 % 20 == 19:
                print(f"  entities {start + 50}/{len(missing)}", file=sys.stderr)
        return {i: store[i] for i in ids if store.get(i)}

    def save(self, store):
        self.store_path.write_text(json.dumps(store, ensure_ascii=False))


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
        "countries": items("P495"),
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
    if item["sitelinks"] < domain.min_sitelinks:
        return False
    if domain.works_from and not set(item["classes"]) & domain.allowed:
        return False
    if domain.min_year is not None:
        year = item["year"]
        return (year is not None and year >= domain.min_year) or item["sitelinks"] >= domain.classic_sitelinks
    return True


def origin_of(countries):
    for name, codes in ORIGINS:
        if set(countries) & codes:
            return name
    return "欧美及其他"


def candidates(client, store, domain, works):
    if domain.works_from:
        ids = []
        works = sorted(works)
        for start in range(0, len(works), 40):
            batch = works[start:start + 40]
            clause = "|".join(f"P1441={q}|P8345={q}" for q in batch)
            ids += client.search(f"haswbstatement:{clause} {ANY_CHINESE}")
    else:
        ids = []
        for c in domain.classes:
            query = f"haswbstatement:P31={c} {ANY_CHINESE}"
            found = client.search(query, popular=domain.group == "origin")
            ids += found
            if domain.group == "origin" and len(found) >= SEARCH_WINDOW:
                for country in ORIGIN_SLICES:
                    ids += client.search(f"haswbstatement:P31={c} haswbstatement:P495={country} {ANY_CHINESE}",
                                         popular=True)
    ids = list(dict.fromkeys(ids))
    print(f"{domain.key}: {len(ids)} items with a Chinese label", file=sys.stderr)
    items = client.entities(ids, store, refresh=domain.group == "origin")
    if domain.works_from:
        # "Present in work" also links real people, places and spells to
        # works; keep items whose class is some kind of character.
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
    parser.add_argument("--only", help="comma-separated domain keys to run (a character domain also runs its works)")
    args = parser.parse_args()

    t2s = OpenCC("t2s")
    words, readings = load_dictionary(args.dictionary)
    valid = {s for r in readings.values() for s in r}
    listed = load_listed(args.words)
    client = Client(args.cache / "api")
    store_path = args.cache / "entities.json"
    client.store_path = store_path
    store = json.loads(store_path.read_text()) if store_path.exists() else {}
    only = set(args.only.split(",")) if args.only else None
    if only:
        only |= {d.works_from for d in DOMAINS if d.key in only and d.works_from}

    sections, kept_by_domain, seen = [], {}, set()
    try:
        for domain in DOMAINS:
            if only and domain.key not in only:
                continue
            works = set(kept_by_domain.get(domain.works_from, {}))
            ids, items = candidates(client, store, domain, works)
            client.save(store)
            kept = {q: i for q, i in items.items() if keep(domain, i)}
            kept_by_domain[domain.key] = kept
            work_group, maker_labels = {}, {}
            if domain.key == "games":
                makers = client.entities(sorted({m for i in kept.values() for m in i["developers"] + i["publishers"]}), store)
                maker_labels = {q: " ".join(m["labels"].values()) for q, m in makers.items()}
            elif domain.works_from == "games":
                game_items = kept_by_domain["games"]
                makers = client.entities(sorted({m for g in game_items.values() for m in g["developers"] + g["publishers"]}), store)
                labels = {q: " ".join(m["labels"].values()) for q, m in makers.items()}
                work_group = {q: vendor_of(g, labels) for q, g in game_items.items()}
            elif domain.works_from:
                work_group = {q: origin_of(w.get("countries", [])) for q, w in kept_by_domain[domain.works_from].items()}

            main_rows, mixed_rows = [], []
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
                    row["group"] = vendor_of(item, maker_labels)
                elif domain.works_from:
                    # A group only for characters of that group's works alone, so
                    # crossover and franchise characters stay under the catch-all.
                    fallback = "其他" if domain.group == "vendor" else "欧美及其他"
                    groups = {work_group.get(w, fallback) for w in item["works"]}
                    row["group"] = groups.pop() if len(groups) == 1 else fallback
                else:
                    row["group"] = origin_of(item.get("countries", []))
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
    out = ["# Wikidata 新词审阅表", "",
           "来源：Wikidata（CC0），通过搜索接口和 wbgetentities 抓取。热度是 sitelinks（有多少个维基语种条目）。",
           "已去掉生成词库 `vime_pinyin.dict.yaml`（含万象）和 `rime_words.txt` 里已有的词。",
           f"游戏和游戏角色每节最多列 {ROWS_PER_DOMAIN} 条；影视动漫按出品地区分组，每组列 sitelinks 最高的 "
           f"{ROWS_PER_ORIGIN} 条，再列 {RECENT_YEAR} 年以后的 {ROWS_PER_ORIGIN} 条。"
           "同一个名字只在第一个出现的领域里列出。", "",
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
        if domain.group == "vendor":
            named = [r for r in rows if r["group"] != "其他"]
            others = [r for r in rows if r["group"] == "其他"]
            shown = named + others[:max(0, ROWS_PER_DOMAIN - len(named))]
            out += [f"新词 {len(rows)} 条，列出 {len(shown)} 条，截掉 {len(rows) - len(shown)} 条。", ""]
            for vendor in [v for v, _ in VENDORS] + ["其他"]:
                group = [r for r in shown if r["group"] == vendor]
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
            parts, total = [], 0
            for origin in [name for name, _ in ORIGINS] + ["欧美及其他"]:
                group = [r for r in rows if r["group"] == origin]
                if not group:
                    continue
                top = group[:ROWS_PER_ORIGIN]
                recent = [r for r in group[ROWS_PER_ORIGIN:] if (r["year"] or 0) >= RECENT_YEAR][:ROWS_PER_ORIGIN]
                total += len(top) + len(recent)
                parts += [f"### {origin}（新词 {len(group)} 条）", ""] + markdown_table(top) + [""]
                if recent:
                    parts += [f"#### {origin}：{RECENT_YEAR} 年以后（再列 {len(recent)} 条）", ""]
                    parts += markdown_table(recent) + [""]
            out += [f"新词 {len(rows)} 条，列出 {total} 条，截掉 {len(rows) - total} 条。", ""] + parts
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
