#!/usr/bin/env python3
"""Use the local bundle's Git build counter and reject non-increasing releases."""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def marketing_version(value):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError(f"Invalid release version: {value!r}")
    return tuple(int(part) for part in value.split("."))


def release_build(repository, version, appcast):
    requested = marketing_version(version)
    shallow = subprocess.check_output(
        ["git", "rev-parse", "--is-shallow-repository"], cwd=repository, text=True
    ).strip()
    if shallow != "false":
        raise ValueError("Release builds require full Git history (fetch-depth: 0).")
    # Scripts/bundle.sh uses this same counter for ordinary local bundles.
    build = int(subprocess.check_output(
        ["git", "rev-list", "--count", "HEAD"], cwd=repository, text=True
    ).strip())
    if build < 1:
        raise ValueError("Release build must be a positive Git commit count.")
    root = ET.parse(appcast).getroot()
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise ValueError("Invalid appcast: expected an RSS channel.")
    items = channel.findall("item")
    for item in items:
        previous = item.findtext(f"{SPARKLE}version", "")
        previous_version = item.findtext(f"{SPARKLE}shortVersionString", "")
        if not previous.isascii() or not previous.isdecimal():
            raise ValueError(f"Invalid published integer build: {previous!r}")
        if build <= int(previous):
            raise ValueError(
                f"Release build {build} must exceed published build {previous}; "
                "Sparkle compares build numbers, not marketing versions."
            )
        if requested <= marketing_version(previous_version):
            raise ValueError(
                f"Release version {version} must exceed published version {previous_version}."
            )
    return build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    parser.add_argument("--appcast", type=Path, default=Path("public/appcast.xml"))
    args = parser.parse_args()
    repository = args.repository.resolve()
    appcast = args.appcast if args.appcast.is_absolute() else repository / args.appcast
    try:
        print(release_build(repository, args.version, appcast))
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
