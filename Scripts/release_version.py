#!/usr/bin/env python3
"""Read and advance the marketing version for the weekly release flow.

`current` prints MARKETING_VERSION. `next` compares the head ref with the
latest release tag: any feature since that tag raises the minor version,
otherwise the patch version. A version already raised on the head ref and not
yet released is kept, so a skipped release week does not bump twice.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

PROJECT = "Vime.xcodeproj/project.pbxproj"
SETTING = re.compile(r"(MARKETING_VERSION = )([0-9.]+)(;)")
TAG = re.compile(r"^v(\d+)\.(\d+)(?:\.(\d+))?$")
FEATURE = re.compile(r"^(feat(\(.+\))?!?:|Merge pull request #\d+ from [^/\s]+/feat/)")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def parse(text):
    parts = [int(part) for part in text.split(".")]
    if not 1 <= len(parts) <= 3:
        raise ValueError(f"unsupported version {text!r}")
    return tuple(parts + [0] * (3 - len(parts)))


def format_version(version):
    major, minor, patch = version
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def project_version(source):
    versions = {match.group(2) for match in SETTING.finditer(source)}
    if len(versions) != 1:
        sys.exit(f"MARKETING_VERSION differs between targets: {sorted(versions)}")
    return parse(versions.pop())


def version_at(ref):
    return project_version(git("show", f"{ref}:{PROJECT}"))


def latest_tag(ref):
    tags = [tag for tag in git("tag", "--merged", ref, "--list", "v*").splitlines() if TAG.match(tag)]
    return max(tags, key=lambda tag: parse(tag[1:]), default=None)


def next_version(base_ref, head_ref):
    tag = latest_tag(base_ref)
    base = parse(tag[1:]) if tag else version_at(base_ref)
    since = tag or base_ref
    subjects = git("log", "--format=%s", f"{since}..{head_ref}").splitlines()
    current = version_at(head_ref)
    if not subjects:
        return current
    major, minor, patch = base
    if any(FEATURE.match(subject) for subject in subjects):
        candidate = (major, minor + 1, 0)
    else:
        candidate = (major, minor, patch + 1)
    return max(current, candidate)


def write(version):
    path = Path(PROJECT)
    path.write_text(SETTING.sub(lambda match: match.group(1) + format_version(version) + match.group(3), path.read_text()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("current")
    upcoming = commands.add_parser("next")
    upcoming.add_argument("--base-ref", default="origin/main", help="last released branch")
    upcoming.add_argument("--head-ref", default="HEAD", help="branch being cut")
    upcoming.add_argument("--write", action="store_true", help="update the project file")
    arguments = parser.parse_args()

    if arguments.command == "current":
        print(format_version(project_version(Path(PROJECT).read_text())))
        return
    version = next_version(arguments.base_ref, arguments.head_ref)
    if arguments.write:
        write(version)
    print(format_version(version))


if __name__ == "__main__":
    main()
