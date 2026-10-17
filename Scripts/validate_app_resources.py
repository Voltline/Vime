#!/usr/bin/env python3
"""Check App legal resources against the original notices and public policy."""
import argparse
import json
from pathlib import Path


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
            if notice != (root / "LICENSE").read_bytes():
                raise ValueError("Vime notice differs from LICENSE")
        else:
            sections.append((original.index(notice), notice))
    if b"".join(text for _, text in sorted(sections)) != original:
        raise ValueError("Component notices do not cover ThirdPartyNotices exactly")
    policy = json.loads((resources / "PrivacyPolicy.json").read_text())
    expected = (
        "# Vime 隐私政策\n\n更新日期：" + policy["updated"]
        + "\n\n生效日期：" + policy["effective"]
        + "\n\n" + policy["scope"]
        + "\n\n" + policy["introduction"] + "\n"
    )
    for section in policy["sections"]:
        expected += "\n## " + section["title"] + "\n\n" + "\n\n".join(section["paragraphs"]) + "\n"
    expected += "\n联系：[Vime Issues](https://github.com/Voltline/Vime/issues)\n"
    if expected != (root / "Docs/Guides/Privacy.md").read_text():
        raise ValueError("Public privacy policy and App policy disagree")
    print(f"Verified {len(ids)} component notices and matching privacy policy")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, help="App resource directory or built Vime.app")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    validate(args.resources or repository / "Vime/Resources", repository)
