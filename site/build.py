#!/usr/bin/env python3
"""Build the Vime website into a static folder for GitHub Pages.

The home page text comes from site/content/<language>.json. The privacy
policy is read from Docs/Guides at --privacy-ref (the released app), the
changelog from published GitHub Releases, and the version status from the
public App Store lookup, App Store Connect (when the ASC_* keys are set) and
Scripts/release_version.py. Only versions, states and dates are published.
"""

import argparse
import html
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

SITE = Path(__file__).resolve().parent
ROOT = SITE.parent
REPOSITORY = "Voltline/Vime"
BUNDLE_ID = "com.Voltline.Vime"

# URL segment, html lang, release notes section, privacy file, time zone, date-time format.
LANGUAGES = {
    "zh-hans": ("zh-Hans", "zh-Hans", "Privacy.md", "Asia/Shanghai", "{date}（{weekday}）{time}"),
    "zh-hant": ("zh-Hant", "zh-Hant", "Privacy.zh-Hant.md", "Asia/Taipei", "{date}（{weekday}）{time}"),
    "ja": ("ja", "ja", "Privacy.ja.md", "Asia/Tokyo", "{date}（{weekday}）{time}"),
    "en": ("en", "en-US", "Privacy.en.md", "UTC", "{weekday} {date} {time} UTC"),
    "ko": ("ko", "ko", "Privacy.ko.md", "Asia/Seoul", "{date} ({weekday}) {time}"),
}
PAGES = {"home": "", "privacy": "privacy/", "changelog": "changelog/"}
# Weekly TestFlight cut and App Store submission, in Beijing time (weekday, hour).
SCHEDULE = {"next_cut": (2, 3), "next_submit": (5, 10)}
BEIJING = ZoneInfo("Asia/Shanghai")
# App Store versions shown as "in review": submitted and not yet on sale.
REVIEW_STATES = {"WAITING_FOR_REVIEW", "READY_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE",
                 "PENDING_DEVELOPER_RELEASE", "ACCEPTED", "PROCESSING_FOR_APP_STORE",
                 "PROCESSING_FOR_DISTRIBUTION", "WAITING_FOR_EXPORT_COMPLIANCE"}


def warn(message):
    print(f"::warning::{message}")


# Markdown: the subset used by the privacy policies and release notes.

def slug(text):
    """GitHub's heading anchors: lowercase, punctuation dropped, spaces to hyphens."""
    return re.sub(r"[^\w\- ]", "", text.strip().lower()).replace(" ", "-")


def inline(text):
    links = []

    def keep(markup):
        links.append(markup)
        return f"\0{len(links) - 1}\0"

    def link(match):
        label, href = match.group(1), match.group(2)
        external = href.startswith("http")
        attributes = ' rel="noopener"' if external else ""
        return keep(f'<a href="{html.escape(href)}"{attributes}>{inline(label)}</a>')

    text = re.sub(r"`([^`]+)`", lambda match: keep(f"<code>{html.escape(match.group(1))}</code>"), text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)
    def autolink(match):
        url = match.group(0).rstrip(".,;:!?")
        return keep(f'<a href="{html.escape(url)}" rel="noopener">{html.escape(url)}</a>') + match.group(0)[len(url):]

    text = re.sub(r"https?://[^\s<>)）。、，]+", autolink, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    return re.sub(r"\0(\d+)\0", lambda match: links[int(match.group(1))], text)


def markdown(text, shift=0):
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    lines = text.splitlines()
    out, paragraph, index = [], [], 0

    def flush():
        if paragraph:
            out.append(f"<p>{inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    while index < len(lines):
        line = lines[index].rstrip()
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if not line.strip():
            flush()
        elif heading:
            flush()
            level = min(len(heading.group(1)) + shift, 6)
            title = heading.group(2).strip()
            out.append(f'<h{level} id="{html.escape(slug(title))}">{inline(title)}</h{level}>')
        elif re.match(r"^(-{3,}|\*{3,})$", line.strip()):
            flush()
            out.append("<hr>")
        elif re.match(r"^\s*([-*]|\d+\.)\s+", line):
            flush()
            ordered = bool(re.match(r"^\s*\d+\.", line))
            items = []
            while index < len(lines) and lines[index].strip():
                item = re.match(r"^\s*(?:[-*]|\d+\.)\s+(.*)$", lines[index])
                if item:
                    items.append(item.group(1))
                elif items:
                    items[-1] += " " + lines[index].strip()
                index += 1
            tag = "ol" if ordered else "ul"
            out.append(f"<{tag}>" + "".join(f"<li>{inline(item)}</li>" for item in items) + f"</{tag}>")
            continue
        elif line.lstrip().startswith("|"):
            flush()
            rows = []
            while index < len(lines) and lines[index].lstrip().startswith("|"):
                rows.append([cell.strip() for cell in lines[index].strip().strip("|").split("|")])
                index += 1
            header, body = rows[0], [row for row in rows[1:] if not all(re.match(r"^:?-+:?$", cell) for cell in row)]
            out.append('<div class="table"><table><thead><tr>'
                       + "".join(f"<th>{inline(cell)}</th>" for cell in header) + "</tr></thead><tbody>"
                       + "".join("<tr>" + "".join(f"<td>{inline(cell)}</td>" for cell in row) + "</tr>"
                                 for row in body)
                       + "</tbody></table></div>")
            continue
        else:
            paragraph.append(line.strip())
        index += 1
    flush()
    return "\n".join(out)


# Data sources.

def fetch_json(url, headers=None, attempts=3):
    request = urllib.request.Request(url, headers={"User-Agent": "vime-site", **(headers or {})})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except OSError:
            if attempt == attempts - 1:
                raise
            time.sleep(2 * (attempt + 1))


def releases():
    """Published releases, newest first. Drafts are skipped."""
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    items = fetch_json(f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=100", headers)
    published = [item for item in items if not item.get("draft") and item.get("published_at")]
    return sorted(published, key=lambda item: item["published_at"], reverse=True)


def release_sections(body):
    """The localized sections above the `---` line, keyed by locale."""
    body = re.sub(r"<!--.*?-->", "", (body or "").replace("\r\n", "\n"), flags=re.S).split("\n---", 1)[0]
    sections = re.findall(r"^## (\S+)[ \t]*\n(.*?)(?=^## |\Z)", body, flags=re.M | re.S)
    return {locale: text.strip() for locale, text in sections if text.strip()}


def app_store_live():
    """The version on sale, from the public lookup. Tries a few storefronts."""
    for country in ("us", "jp", "cn", "tw", "kr"):
        query = urllib.parse.urlencode({"bundleId": BUNDLE_ID, "country": country})
        results = fetch_json(f"https://itunes.apple.com/lookup?{query}").get("results", [])
        if results:
            app = results[0]
            return {"version": app.get("version"), "date": app.get("currentVersionReleaseDate"),
                    "url": f"https://apps.apple.com/app/id{app['trackId']}"}
    return None


def app_store_connect():
    """The version in review and the latest TestFlight build, or None without keys or access."""
    names = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY")
    if not all(os.environ.get(name) for name in names):
        print("App Store Connect keys are not set; showing public data only.")
        return None

    def attempt(what, function):
        try:
            return function()
        except (Exception, SystemExit) as error:  # Client.get exits on HTTP errors.
            warn(f"Could not read {what} from App Store Connect: {str(error).replace('::error::', '')}")
            return None

    spec = importlib.util.spec_from_file_location("app_store", ROOT / ".github/scripts/app_store.py")
    asc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(asc)
    client = attempt("a token", lambda: asc.Client(asc.token(*(os.environ[name] for name in names))))
    apps = client and attempt("the app", lambda: client.get("apps", **{"filter[bundleId]": BUNDLE_ID}))
    if not apps:
        return None
    app_id = apps[0]["id"]

    def review():
        versions = client.get(f"apps/{app_id}/appStoreVersions", **{"filter[platform]": "IOS", "limit": 20})
        versions.sort(key=lambda version: version["attributes"].get("createdDate") or "", reverse=True)
        for version in versions:
            attributes = version["attributes"]
            state = attributes.get("appStoreState") or attributes.get("appVersionState")
            if state in REVIEW_STATES:
                return {"version": attributes["versionString"], "state": state, "date": submitted()}
        return {}

    def submitted():
        submissions = attempt("review submissions", lambda: client.get(
            "reviewSubmissions", **{"filter[app]": app_id, "filter[platform]": "IOS", "limit": 20}))
        dates = [item["attributes"].get("submittedDate") for item in submissions or []]
        return max(filter(None, dates), default=None)

    def testflight():
        builds = client.get("builds", **{"filter[app]": app_id, "filter[preReleaseVersion.platform]": "IOS",
                                         "filter[processingState]": "VALID", "filter[expired]": "false",
                                         "sort": "-uploadedDate", "limit": 1})
        if not builds:
            return {}
        build = builds[0]
        version = client.get(f"builds/{build['id']}/preReleaseVersion")
        return {"version": version["attributes"]["version"], "build": build["attributes"]["version"],
                "date": build["attributes"].get("uploadedDate")}

    return {"review": attempt("the version in review", review),
            "testflight": attempt("TestFlight builds", testflight)}


def next_version():
    try:
        return subprocess.run([sys.executable, "Scripts/release_version.py", "current"], cwd=ROOT,
                              check=True, capture_output=True, text=True).stdout.strip()
    except subprocess.CalledProcessError as error:
        warn(f"Could not read the version on dev: {error.stderr.strip()}")
        return None


def privacy_policy(ref, name):
    return subprocess.run(["git", "show", f"{ref}:Docs/Guides/{name}"], cwd=ROOT,
                          check=True, capture_output=True, text=True).stdout


# Rendering.

class Site:
    def __init__(self, base_url, out, data):
        self.base_url = base_url.rstrip("/") + "/"
        self.base = urllib.parse.urlparse(self.base_url).path
        self.out = out
        self.data = data
        self.content = {code: json.loads((SITE / "content" / f"{LANGUAGES[code][0]}.json").read_text())
                        for code in LANGUAGES}

    def url(self, path=""):
        return self.base + path

    def write(self, path, text):
        target = self.out / path / "index.html" if not path.endswith(".html") else self.out / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def date(self, value, code, with_time=False):
        """An ISO date from an API, or a datetime, in the language's time zone."""
        if not value:
            return ""
        moment = value if isinstance(value, datetime) else datetime.fromisoformat(value.replace("Z", "+00:00"))
        local = moment.astimezone(ZoneInfo(LANGUAGES[code][3]))
        if not with_time:
            return local.strftime("%Y-%m-%d")
        weekday = self.content[code]["status"]["weekdays"][local.weekday()]
        return LANGUAGES[code][4].format(date=local.strftime("%Y-%m-%d"), weekday=weekday,
                                         time=local.strftime("%H:%M"))

    def page(self, code, key, title, description, main):
        text = self.content[code]
        lang = LANGUAGES[code][0]
        path = PAGES[key]
        alternates = "\n".join(
            f'<link rel="alternate" hreflang="{LANGUAGES[other][0]}" href="{self.base_url}{other}/{path}">'
            for other in LANGUAGES) + f'\n<link rel="alternate" hreflang="x-default" href="{self.base_url}{path}">'
        page_current, language_current = ' aria-current="page"', ' aria-current="true"'
        nav = "".join(
            f'<a href="{self.url(f"{code}/{PAGES[item]}")}"{page_current if item == key else ""}>'
            f'{html.escape(text["nav"][item])}</a>' for item in ("privacy", "changelog"))
        languages = "".join(
            f'<li><a href="{self.url(f"{other}/{path}")}" hreflang="{LANGUAGES[other][0]}" lang="{LANGUAGES[other][0]}"'
            f' data-lang="{other}"{language_current if other == code else ""}>'
            f'{html.escape(self.content[other]["name"])}</a></li>' for other in LANGUAGES)
        footer = text["footer"]
        return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(description)}">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#f7f9fc" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0f1115" media="(prefers-color-scheme: dark)">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(description)}">
<meta property="og:image" content="{self.base_url}apple-touch-icon.png">
<link rel="canonical" href="{self.base_url}{code}/{path}">
{alternates}
<link rel="icon" href="{self.url('logo.svg')}" type="image/svg+xml">
<link rel="apple-touch-icon" href="{self.url('apple-touch-icon.png')}">
<link rel="stylesheet" href="{self.url('style.css')}">
<script src="{self.url('site.js')}" defer></script>
</head>
<body>
<header class="site-header">
<div class="wrap header-row">
<a class="brand" href="{self.url(f'{code}/')}"><img src="{self.url('logo.svg')}" alt="" width="30" height="30"><span>Vime</span></a>
<nav class="site-nav" aria-label="{html.escape(text['nav']['home'])}">{nav}</nav>
<details class="language">
<summary aria-label="{html.escape(text['nav']['language'])}"><svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z"/></svg><span>{html.escape(text['name'])}</span></summary>
<ul>{languages}</ul>
</details>
</div>
</header>
<main>
{main}
</main>
<footer class="site-footer">
<div class="wrap footer-row">
<div class="footer-brand"><img src="{self.url('logo.svg')}" alt="" width="22" height="22"><span>Vime</span></div>
<nav aria-label="Footer">
<a href="{self.url(f'{code}/')}">{html.escape(text['nav']['home'])}</a>
<a href="{self.url(f'{code}/privacy/')}">{html.escape(text['nav']['privacy'])}</a>
<a href="{self.url(f'{code}/changelog/')}">{html.escape(text['nav']['changelog'])}</a>
<a href="https://github.com/{REPOSITORY}" rel="noopener">GitHub</a>
</nav>
<p>© Voltline · {html.escape(footer['license'])} {html.escape(footer['notrack'])}</p>
</div>
</footer>
</body>
</html>
"""

    def home(self, code):
        text = self.content[code]
        home = text["home"]
        live = self.data["live"]
        buttons = []
        if live:
            buttons.append(f'<a class="button primary" href="{html.escape(live["url"])}" rel="noopener">'
                           f'{html.escape(home["appstore"])}</a>')
        buttons.append(f'<a class="button" href="https://github.com/{REPOSITORY}" rel="noopener">'
                       f'{html.escape(home["source"])}</a>')
        points = "".join(f'<div class="point"><h3>{html.escape(point["title"])}</h3>'
                         f'<p>{inline(point["text"])}</p></div>' for point in home["points"])
        groups = "".join(f'<section class="card"><h3>{html.escape(group["title"])}</h3><ul>'
                         + "".join(f"<li>{inline(item)}</li>" for item in group["items"]) + "</ul></section>"
                         for group in home["groups"])
        setup = "".join(f"<li>{inline(step)}</li>" for step in home["setup"])
        privacy = "".join(f"<li>{inline(item)}</li>" for item in home["privacy"])
        main = f"""
<section class="hero">
<div class="wrap">
<img class="hero-logo" src="{self.url('logo.svg')}" alt="" width="104" height="104">
<h1>Vime</h1>
<p class="tagline">{html.escape(home['tagline'])}</p>
<p class="intro">{inline(home['intro'])}</p>
<div class="buttons">{''.join(buttons)}</div>
{self.chips(code)}
</div>
</section>
<section class="wrap points">{points}</section>
<section class="wrap section">
<h2>{html.escape(home['features_title'])}</h2>
<div class="grid">{groups}</div>
</section>
<section class="wrap section split">
<div class="card">
<h2>{html.escape(home['setup_title'])}</h2>
<ol class="steps">{setup}</ol>
<p class="muted">{inline(home['requirements'])}</p>
</div>
<div class="card">
<h2>{html.escape(home['privacy_title'])}</h2>
<ul class="checks">{privacy}</ul>
<p><a class="more" href="{self.url(f'{code}/privacy/')}">{html.escape(home['privacy_link'])} →</a></p>
</div>
</section>
<section class="wrap section">
<div class="card wide">
<h2>{html.escape(home['open_title'])}</h2>
<p>{inline(home['open_text'])}</p>
<p><a class="more" href="https://github.com/{REPOSITORY}" rel="noopener">github.com/{REPOSITORY} →</a></p>
</div>
</section>
"""
        self.write(f"{code}/", self.page(code, "home", home["title"], home["description"], main))

    def chips(self, code):
        """A short version summary under the hero buttons, linking to the status section."""
        status = self.content[code]["status"]
        chips = []
        if self.data["live"]:
            chips.append(f'{html.escape(status["appstore"])} <b>{html.escape(self.data["live"]["version"])}</b>')
        review = (self.data["asc"] or {}).get("review")
        if review:
            state = status["states"].get(review["state"], review["state"])
            chips.append(f'{html.escape(status["review"])} <b>{html.escape(review["version"])}</b>'
                         f' · {html.escape(state)}')
        testflight = (self.data["asc"] or {}).get("testflight")
        if testflight:
            chips.append(f'{html.escape(status["testflight"])} <b>{html.escape(testflight["version"])}</b>')
        if not chips and self.data["next"]:
            chips.append(f'{html.escape(status["next"])} <b>{html.escape(self.data["next"])}</b>')
        if not chips:
            return ""
        return (f'<a class="chips" href="{self.url(f"{code}/changelog/#status")}">'
                + "".join(f"<span>{chip}</span>" for chip in chips) + "</a>")

    def status(self, code):
        status = self.content[code]["status"]
        live, asc, cards = self.data["live"], self.data["asc"], []

        def card(label, value, note="", extra=""):
            cards.append(f'<div class="status-item"><div class="label">{html.escape(label)}</div>'
                         f'<div class="value">{value}</div>'
                         + (f'<div class="note">{note}</div>' if note else "") + extra + "</div>")

        if live:
            card(status["appstore"], html.escape(live["version"]),
                 html.escape(status["released"].format(date=self.date(live["date"], code))),
                 f'<a class="more" href="{html.escape(live["url"])}" rel="noopener">{html.escape(status["appstore_link"])} →</a>')
        else:
            card(status["appstore"], f'<span class="none">{html.escape(status["appstore_none"])}</span>')
        if asc and asc.get("review") is not None:
            review = asc["review"]
            if review:
                state = status["states"].get(review["state"], review["state"].replace("_", " ").title())
                note = html.escape(status["submitted"].format(date=self.date(review["date"], code))) if review["date"] else ""
                card(status["review"], f'{html.escape(review["version"])} <span class="badge">{html.escape(state)}</span>', note)
            else:
                card(status["review"], f'<span class="none">{html.escape(status["review_none"])}</span>')
        if asc and asc.get("testflight"):
            testflight = asc["testflight"]
            card(status["testflight"],
                 f'{html.escape(testflight["version"])} <span class="build">({html.escape(status["build"])} {html.escape(testflight["build"])})</span>',
                 html.escape(status["uploaded"].format(date=self.date(testflight["date"], code))))
        if self.data["next"]:
            card(status["next"], html.escape(self.data["next"]), html.escape(status["next_note"]))
        upcoming = "".join(
            f"<li>{html.escape(status[key].format(date=self.date(self.data[key], code, with_time=True)))}</li>"
            for key in SCHEDULE)
        rhythm = "".join(f"<li>{inline(step)}</li>" for step in status["rhythm"])
        return f"""
<section class="section" id="status">
<h2>{html.escape(status['title'])}</h2>
<div class="status-grid">{''.join(cards)}</div>
<div class="card rhythm">
<h3>{html.escape(status['rhythm_title'])}</h3>
<ol class="steps">{rhythm}</ol>
<ul class="upcoming">{upcoming}</ul>
</div>
<p class="muted small">{html.escape(status['updated'].format(date=self.date(self.data['generated'], code, with_time=True)))}</p>
</section>"""

    def changelog(self, code):
        text = self.content[code]
        changelog = text["changelog"]
        section = LANGUAGES[code][1]
        entries = []
        for release in self.data["releases"]:
            sections = release_sections(release.get("body"))
            notes, note = sections.get(section), ""
            if not notes:
                notes = sections.get("en-US") or sections.get("zh-Hans")
                if notes and changelog["missing"]:
                    note = f'<p class="muted small">{html.escape(changelog["missing"])}</p>'
            title = release.get("name") or release["tag_name"]
            entries.append(f"""<article class="card release" id="{html.escape(release['tag_name'])}">
<header><h3>{html.escape(title)}</h3><time datetime="{html.escape(release['published_at'])}">{self.date(release['published_at'], code)}</time></header>
{note}{markdown(notes, shift=2) if notes else ''}
<p><a class="more" href="{html.escape(release['html_url'])}" rel="noopener">{html.escape(changelog['github'])} →</a></p>
</article>""")
        if not entries:
            entries.append(f'<p class="card muted">{html.escape(changelog["empty"])}</p>')
        main = f"""
<div class="wrap page">
<h1>{html.escape(changelog['title'])}</h1>
{self.status(code)}
<section class="section">
<h2>{html.escape(changelog['releases'])}</h2>
<div class="releases">{''.join(entries)}</div>
</section>
</div>
"""
        self.write(f"{code}/changelog/", self.page(code, "changelog", f"{changelog['title']} · Vime",
                                                     changelog["description"], main))

    def privacy(self, code):
        source = self.data["privacy"][code]
        body = markdown(source)
        anchors = set(re.findall(r'id="([^"]+)"', body))
        missing = [href for href in re.findall(r'href="#([^"]+)"', body) if html.unescape(href) not in anchors
                   and href not in anchors]
        if missing:
            sys.exit(f"::error::{LANGUAGES[code][2]} links to missing headings: {', '.join(missing)}")
        heading = re.search(r"^#\s+(.*)$", source, flags=re.M)
        title = heading.group(1).strip() if heading else self.content[code]["privacy"]["title"]
        description = next((line.strip() for line in source.splitlines()[1:]
                            if len(line.strip()) > 40 and not line.startswith(("#", "-", "|"))), title)
        main = f"""
<div class="wrap page">
<article class="prose">
{body}
<p class="muted small">{html.escape(self.content[code]['privacy']['note'])}</p>
</article>
</div>
"""
        self.write(f"{code}/privacy/", self.page(code, "privacy", title, description, main))

    def chooser(self, path, status=""):
        """A language picker that sends visitors to their browser's language."""
        targets = {code: self.url(f"{code}/{path}") for code in LANGUAGES}
        links = "".join(f'<li><a href="{targets[code]}" hreflang="{LANGUAGES[code][0]}" lang="{LANGUAGES[code][0]}"'
                        f' data-lang="{code}">{html.escape(self.content[code]["name"])}</a></li>' for code in LANGUAGES)
        alternates = "\n".join(f'<link rel="alternate" hreflang="{LANGUAGES[code][0]}" href="{self.base_url}{code}/{path}">'
                               for code in LANGUAGES)
        notice = "".join(f'<p lang="{LANGUAGES[code][0]}">{html.escape(self.content[code]["notfound"])}</p>'
                         for code in LANGUAGES) if status else ""
        redirect = "" if status else f"""<script>
(function () {{
  var targets = {json.dumps(targets)};
  var choice = null;
  try {{ choice = localStorage.getItem("vime.lang"); }} catch (error) {{}}
  if (!targets[choice]) {{
    var list = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || "en"];
    for (var i = 0; i < list.length && !targets[choice]; i++) {{
      var tag = String(list[i]).toLowerCase();
      if (tag.indexOf("zh") === 0) choice = /hant|-tw|-hk|-mo/.test(tag) ? "zh-hant" : "zh-hans";
      else choice = tag.split("-")[0];
    }}
  }}
  location.replace((targets[choice] || targets.en) + location.hash);
}})();
</script>"""
        return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Vime</title>
<meta name="description" content="{html.escape(self.content['en']['home']['description'])}">
<meta name="color-scheme" content="light dark">
{alternates}
<link rel="icon" href="{self.url('logo.svg')}" type="image/svg+xml">
<link rel="apple-touch-icon" href="{self.url('apple-touch-icon.png')}">
<link rel="stylesheet" href="{self.url('style.css')}">
{redirect}
<script src="{self.url('site.js')}" defer></script>
</head>
<body class="chooser">
<main>
<img src="{self.url('logo.svg')}" alt="" width="88" height="88">
<h1>Vime</h1>
{notice}
<ul>{links}</ul>
</main>
</body>
</html>
"""

    def build(self):
        if self.out.exists():
            shutil.rmtree(self.out)
        shutil.copytree(SITE / "static", self.out)
        for code in LANGUAGES:
            self.home(code)
            self.privacy(code)
            self.changelog(code)
        for path in PAGES.values():
            self.write(path, self.chooser(path))
        self.write("404.html", self.chooser("", status="404"))


def upcoming(now, weekday, hour):
    """The next weekly slot in Beijing time after now."""
    local = now.astimezone(BEIJING)
    slot = local.replace(hour=hour, minute=0, second=0, microsecond=0) + timedelta(days=(weekday - local.weekday()) % 7)
    return slot if slot > local else slot + timedelta(days=7)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=str(ROOT / "_site"), help="output folder (replaced)")
    parser.add_argument("--base-url", default="https://voltline.github.io/Vime/")
    parser.add_argument("--privacy-ref", default="origin/main", help="git ref of the released privacy policy")
    arguments = parser.parse_args()

    now = datetime.now(timezone.utc)
    data = {
        "generated": now,
        "privacy": {code: privacy_policy(arguments.privacy_ref, LANGUAGES[code][2]) for code in LANGUAGES},
        "releases": releases(),
        "live": app_store_live(),
        "asc": app_store_connect(),
        "next": next_version(),
        **{key: upcoming(now, *slot) for key, slot in SCHEDULE.items()},
    }
    summary = {"live": data["live"] and data["live"]["version"], "asc": data["asc"], "next": data["next"],
               "releases": [release["tag_name"] for release in data["releases"]]}
    print(json.dumps(summary, ensure_ascii=False))
    Site(arguments.base_url, Path(arguments.out), data).build()
    print(f"Built {arguments.out}")


if __name__ == "__main__":
    main()
