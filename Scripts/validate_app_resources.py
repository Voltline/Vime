#!/usr/bin/env python3
"""Check App legal resources, localized privacy policies and string translations."""
import argparse
import json
from pathlib import Path


def slug(title: str) -> str:
    """GitHub heading anchor: keep letters, digits, spaces and hyphens."""
    return "".join(c for c in title.lower() if c.isalnum() or c in " -_").replace(" ", "-")


def render_block(block) -> str:
    if isinstance(block, str):
        return block
    cell = lambda text: text.replace("|", "\\|")
    lines = ["| " + " | ".join(map(cell, block["columns"])) + " |",
             "| " + " | ".join("---" for _ in block["columns"]) + " |"]
    lines += ["| " + " | ".join(map(cell, row)) + " |" for row in block["rows"]]
    return "\n".join(lines)


# language: (policy file suffix, public Markdown name, title, updated, effective, key points, contents, contact)
POLICY_LANGUAGES = {
    "zh-Hans": ("", "Privacy.md", "Vime 隐私政策", "更新日期：", "生效日期：", "要点速览", "目录", "联系"),
    "zh-Hant": ("-zh-Hant", "Privacy.zh-Hant.md", "Vime 隱私權政策", "更新日期：", "生效日期：", "重點摘要", "目錄", "聯絡"),
    "ja": ("-ja", "Privacy.ja.md", "Vime プライバシーポリシー", "更新日：", "施行日：", "要点", "目次", "お問い合わせ："),
    "en": ("-en", "Privacy.en.md", "Vime Privacy Policy", "Updated: ", "Effective: ", "Key Points", "Contents", "Contact: "),
}


def render_policy(policy, language="zh-Hans") -> str:
    """A public Markdown policy, generated from the App's PrivacyPolicy JSON."""
    _, _, title, updated, effective, points, contents, contact = POLICY_LANGUAGES[language]
    if contact in ("联系", "聯絡"):
        contact += "："
    text = (
        f"# {title}\n\n{updated}" + policy["updated"]
        + f"\n\n{effective}" + policy["effective"]
        + "\n\n" + policy["scope"]
        + "\n\n" + policy["introduction"] + "\n"
    )
    text += f"\n## {points}\n\n" + "\n".join("- " + item for item in policy["highlights"]) + "\n"
    text += f"\n## {contents}\n\n" + "\n".join(
        f"- [{section['title']}](#{slug(section['title'])})" for section in policy["sections"]) + "\n"
    for section in policy["sections"]:
        text += "\n## " + section["title"] + "\n\n" + "\n\n".join(map(render_block, section["paragraphs"])) + "\n"
    return text + f"\n{contact}[Vime Issues](https://github.com/Voltline/Vime/issues)\n"


def policy_shape(policy):
    return (policy["updated"], policy["effective"], len(policy["highlights"]),
            [[(len(b["columns"]), [len(r) for r in b["rows"]]) if isinstance(b, dict) else "text"
              for b in section["paragraphs"]] for section in policy["sections"]])


def load_policies(resources: Path):
    return {language: json.loads((resources / f"PrivacyPolicy{suffix}.json").read_text())
            for language, (suffix, *_) in POLICY_LANGUAGES.items()}


def validate(resources: Path, root: Path) -> None:
    manifest = json.loads((resources / "LicenseManifest.json").read_text())
    ids = [row["id"] for row in manifest]
    if len(ids) != len(set(ids)) or "vime" not in ids:
        raise ValueError("License component IDs must be unique and include Vime")
    original = (root / "Shared/Resources/ThirdPartyNotices.txt").read_bytes()
    sections = []
    for row in manifest:
        name = row["noticeFile"]
        if Path(name).name != name:
            raise ValueError("Notice names must be plain resource names")
        path = resources / "Licenses" / (name + ".txt")
        if not path.exists():
            path = resources / (name + ".txt")  # Xcode's flattened resource bundle
        notice = path.read_bytes()
        if row["id"] == "vime":
            # The App shows Vime's additional permission ahead of the GPL text.
            if notice != (root / "LICENSE-EXCEPTION").read_bytes() + b"\n\n" + (root / "LICENSE").read_bytes():
                raise ValueError("Vime notice differs from LICENSE-EXCEPTION and LICENSE")
        else:
            sections.append((original.index(notice), notice))
    if b"".join(text for _, text in sorted(sections)) != original:
        raise ValueError("Component notices do not cover ThirdPartyNotices exactly")
    policies = load_policies(resources)
    source = policy_shape(policies["zh-Hans"])
    for language, policy in policies.items():
        if policy_shape(policy) != source:
            raise ValueError(f"{language} privacy policy differs in dates or structure from the source")
        if render_policy(policy, language) != (root / "Docs/Guides" / POLICY_LANGUAGES[language][1]).read_text():
            raise ValueError(f"Public {language} privacy policy and App policy disagree; regenerate with --write-policy")
    catalog = json.loads((root / "Shared/Resources/Localizable.xcstrings").read_text())
    untranslated = [
        f"{language}: {key}" for key, entry in catalog["strings"].items()
        if entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale"
        for language in ("zh-Hant", "ja", "en")
        if entry.get("localizations", {}).get(language, {}).get("stringUnit", {}).get("state") != "translated"
    ]
    if untranslated:
        raise ValueError("Untranslated strings:\n" + "\n".join(untranslated[:20]))
    print(f"Verified {len(ids)} component notices, {len(POLICY_LANGUAGES)} matching privacy policies "
          f"and {len(catalog['strings'])} translated strings")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, help="App resource directory or built Vime.app")
    parser.add_argument("--write-policy", action="store_true",
                        help="Regenerate the public Docs/Guides/Privacy*.md files from the App policy JSON")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    if args.write_policy:
        for language, policy in load_policies(repository / "Vime/Resources").items():
            (repository / "Docs/Guides" / POLICY_LANGUAGES[language][1]).write_text(render_policy(policy, language))
    validate(args.resources or repository / "Vime/Resources", repository)
