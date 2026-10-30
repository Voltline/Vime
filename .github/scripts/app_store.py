#!/usr/bin/env python3
"""Release notes and read-only App Store Connect checks for the weekly release.

`notes` reads the localized "What's New" sections from a draft release body
and can write them as fastlane metadata. `check` asks App Store Connect
whether the version can be submitted: the app's localizations, the builds of
the version and any other version still in review. It changes nothing.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

LOCALES = ["zh-Hans", "zh-Hant", "ja", "en-US", "ko"]
API = "https://api.appstoreconnect.apple.com/v1"
# States in which another version keeps a new one from being submitted.
IN_FLIGHT = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE",
             "PENDING_DEVELOPER_RELEASE", "PROCESSING_FOR_APP_STORE", "WAITING_FOR_EXPORT_COMPLIANCE"}


def release_notes(path):
    """The non-empty localized sections above the `---` line."""
    body = Path(path).read_text().split("\n---", 1)[0] if Path(path).exists() else ""
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    sections = re.findall(r"^## (\S+)[ \t]*\n(.*?)(?=^## |\Z)", body, flags=re.M | re.S)
    return {locale: text.strip() for locale, text in sections if text.strip()}


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(signature):
    """ECDSA signatures from OpenSSL are DER; JWT wants r and s as 32 bytes each."""
    assert signature[0] == 0x30
    offset = 3 if signature[1] & 0x80 else 2
    parts = []
    for _ in range(2):
        assert signature[offset] == 0x02
        length = signature[offset + 1]
        parts.append(signature[offset + 2:offset + 2 + length].lstrip(b"\0").rjust(32, b"\0"))
        offset += 2 + length
    return b"".join(parts)


def token(key_id, issuer_id, private_key):
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    now = int(time.time())
    claims = {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = f"{header}.{b64url(json.dumps(claims).encode())}"
    with tempfile.NamedTemporaryFile("w", suffix=".p8") as key:
        key.write(private_key)
        key.flush()
        signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key.name],
                                   input=signing_input.encode(), capture_output=True, check=True).stdout
    return f"{signing_input}.{b64url(der_to_raw(signature))}"


class Client:
    def __init__(self, bearer):
        self.bearer = bearer

    def get(self, path, **query):
        url = f"{API}/{path}" + (f"?{urllib.parse.urlencode(query)}" if query else "")
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.bearer}"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)["data"]
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:500]
            sys.exit(f"::error::App Store Connect returned {error.code} for {path}: {detail}")


def check(arguments):
    errors, warnings, lines = [], [], []
    environment = {name: os.environ.get(name, "") for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY")}
    if not all(environment.values()):
        sys.exit("::error::Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY.")
    client = Client(token(environment["ASC_KEY_ID"], environment["ASC_ISSUER_ID"], environment["ASC_PRIVATE_KEY"]))

    apps = client.get("apps", **{"filter[bundleId]": arguments.bundle_id})
    if not apps:
        sys.exit(f"::error::No app with bundle ID {arguments.bundle_id} is visible to this API key.")
    app = apps[0]
    lines.append(f"App: {app['attributes']['name']} ({app['id']}), primary locale {app['attributes']['primaryLocale']}")

    versions = client.get(f"apps/{app['id']}/appStoreVersions", **{"filter[platform]": "IOS", "limit": 20})
    versions.sort(key=lambda version: version["attributes"].get("createdDate") or "", reverse=True)
    def state(version):
        attributes = version["attributes"]
        return attributes.get("appStoreState") or attributes.get("appVersionState") or "UNKNOWN"
    for version in versions[:5]:
        lines.append(f"Version {version['attributes']['versionString']}: {state(version)}")
    target = next((version for version in versions if version["attributes"]["versionString"] == arguments.version), None)
    if target and state(target) not in {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                                        "METADATA_REJECTED", "INVALID_BINARY"}:
        errors.append(f"Version {arguments.version} is {state(target)} and cannot be submitted again.")
    for version in versions:
        if version is not target and state(version) in IN_FLIGHT:
            warnings.append(f"Version {version['attributes']['versionString']} is {state(version)}; "
                            f"{arguments.version} can be submitted once it is released or removed from review.")
    rejected = [version for version in versions if version is not target
                and state(version) in {"DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "PREPARE_FOR_SUBMISSION"}]
    if not target and rejected:
        lines.append(f"Version {rejected[0]['attributes']['versionString']} is editable; "
                     f"deliver renames it to {arguments.version}.")

    # A new version copies the localizations of the latest one.
    source = target or (versions[0] if versions else None)
    if source:
        localizations = client.get(f"appStoreVersions/{source['id']}/appStoreVersionLocalizations", limit=50)
        locales = sorted(localization["attributes"]["locale"] for localization in localizations)
        lines.append(f"Localizations of {source['attributes']['versionString']}: {', '.join(locales)}")
        if set(locales) != set(LOCALES):
            errors.append(f"App Store Connect has {', '.join(locales)}, the release notes expect "
                          f"{', '.join(LOCALES)}; update LOCALES in .github/scripts/app_store.py.")

    builds = client.get("builds", **{"filter[app]": app["id"], "filter[preReleaseVersion.version]": arguments.version,
                                     "filter[preReleaseVersion.platform]": "IOS", "sort": "-uploadedDate", "limit": 5})
    for build in builds:
        attributes = build["attributes"]
        lines.append(f"Build {arguments.version} ({attributes['version']}): {attributes['processingState']}, "
                     f"uploaded {attributes['uploadedDate']}" + (", expired" if attributes.get("expired") else ""))
    if not any(build["attributes"]["processingState"] == "VALID" and not build["attributes"].get("expired") for build in builds):
        errors.append(f"No processed build of {arguments.version} is available.")

    if arguments.notes:
        notes = release_notes(arguments.notes)
        missing = [locale for locale in LOCALES if locale not in notes]
        lines.append(f"Release notes filled: {', '.join(locale for locale in LOCALES if locale in notes) or 'none'}")
        if missing:
            warnings.append(f"Release notes are still empty for {', '.join(missing)}.")

    blocking = errors + (warnings if arguments.strict else [])
    report = lines + [f"Warning: {warning}" for warning in warnings] + [f"Error: {error}" for error in errors]
    print("\n".join(report))
    for warning in warnings:
        print(f"::warning::{warning}")
    for error in errors:
        print(f"::error::{error}")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(f"### App Store Connect check for {arguments.version}\n\n")
            summary.write("\n".join(f"- {line}" for line in report) + "\n")
    sys.exit(1 if blocking else 0)


def notes(arguments):
    sections = release_notes(arguments.file)
    missing = [locale for locale in LOCALES if locale not in sections]
    if missing:
        sys.exit(f"::error::Release notes are missing for {', '.join(missing)}; fill them in the draft release.")
    if arguments.metadata:
        for locale in LOCALES:
            path = Path(arguments.metadata, locale, "release_notes.txt")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(sections[locale] + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    notes_parser = commands.add_parser("notes", help="validate the localized release notes")
    notes_parser.add_argument("file", help="draft release body")
    notes_parser.add_argument("--metadata", help="write fastlane release_notes.txt files here")
    check_parser = commands.add_parser("check", help="read-only App Store Connect check")
    check_parser.add_argument("--version", required=True)
    check_parser.add_argument("--bundle-id", default="com.Voltline.Vime")
    check_parser.add_argument("--notes", help="draft release body to report on")
    check_parser.add_argument("--strict", action="store_true", help="fail on warnings too")
    arguments = parser.parse_args()
    {"notes": notes, "check": check}[arguments.command](arguments)


if __name__ == "__main__":
    main()
