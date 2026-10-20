#!/usr/bin/env python3
"""Use the local bundle's Git build counter and reject non-increasing releases.

With --check-downloads, require every appcast enclosure to be a public HTTPS download."""
import argparse
import http.client
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def marketing_version(value):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError(f"Invalid release version: {value!r}")
    return tuple(int(part) for part in value.split("."))


def release_build(repository, version, appcasts):
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
    for appcast in appcasts:
        root = ET.parse(appcast).getroot()
        channel = root.find("channel")
        if root.tag != "rss" or channel is None:
            raise ValueError("Invalid appcast: expected an RSS channel.")
        for item in channel.findall("item"):
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


DOWNLOAD_ATTEMPTS = 5
MAX_RETRY_DELAY = 25


def download_size(url):
    """Return the byte count of a public HTTPS download, retrying transient failures."""
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        delay = 2 ** attempt
        try:
            with urllib.request.urlopen(url, timeout=20) as response:
                final = response.geturl()
                if response.status != 200 or urllib.parse.urlsplit(final).scheme != "https":
                    raise ValueError(f"{url} answered HTTP {response.status} from {final}; "
                                     "expected 200 over HTTPS.")
                size = 0
                while chunk := response.read(1 << 20):
                    size += len(chunk)
                return size
        except urllib.error.HTTPError as error:
            if (error.code != 429 and error.code < 500) or attempt == DOWNLOAD_ATTEMPTS:
                raise ValueError(f"{url} is not publicly available: {error}") from error
            retry_after = error.headers.get("Retry-After", "")
            if retry_after.isdigit():
                delay = min(int(retry_after), MAX_RETRY_DELAY)
        except (urllib.error.URLError, http.client.HTTPException, OSError) as error:
            if attempt == DOWNLOAD_ATTEMPTS:
                raise ValueError(f"{url} is not publicly available: {error}") from error
        print(f"{url}: attempt {attempt} failed; retrying in {delay}s", file=sys.stderr)
        time.sleep(delay)


def check_downloads(appcast):
    root = ET.parse(appcast).getroot()
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise ValueError("Invalid appcast: expected an RSS channel.")
    for enclosure in channel.findall("item/enclosure"):
        url, length = enclosure.get("url", ""), enclosure.get("length", "")
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != "https" or not parts.netloc:
            raise ValueError(f"{url!r} is not an https:// download URL.")
        size = download_size(url)
        if str(size) != length:
            raise ValueError(f"{url} has {size} bytes; the appcast expects {length}.")
        print(f"{url}: {size} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--version")
    mode.add_argument("--check-downloads", type=Path, metavar="APPCAST")
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    parser.add_argument("--appcast", type=Path, action="append",
                        help="Check each supplied appcast; defaults to public/appcast.xml.")
    args = parser.parse_args()
    repository = args.repository.resolve()
    appcasts = [path if path.is_absolute() else repository / path
                for path in (args.appcast or [Path("public/appcast.xml")])]
    try:
        if args.check_downloads:
            check_downloads(args.check_downloads)
        else:
            print(release_build(repository, args.version, appcasts))
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
