#!/usr/bin/env python3
"""Build task-owned ad-hoc native Sparkle discovery metadata fixtures only."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--framework", type=pathlib.Path, required=True)
parser.add_argument("--host-build", required=True)
parser.add_argument("--host-version", default="1.4.0")
parser.add_argument("--feed-url", required=True)
parser.add_argument("--name", required=True)
parser.add_argument("--public-key-file", type=pathlib.Path, required=True)
args = parser.parse_args()
app = root / (args.name + ".app")
if app.exists():
    raise SystemExit(f"Refusing to overwrite existing task-owned bundle: {app}")
contents = app / "Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Frameworks").mkdir()
executable = contents / "MacOS" / "UpdateDiscoveryProbe"
subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra",
                "-Wno-unused-parameter", "-mmacosx-version-min=27.0",
                "-F", str(args.framework.parent), "-framework", "Cocoa",
                "-framework", "ScreenCaptureKit", "-framework", "Sparkle",
                "-Wl,-rpath,@executable_path/../Frameworks",
                str(root / "UpdateDiscoveryProbe.m"), "-o", str(executable)], check=True)
subprocess.run(["ditto", str(args.framework), str(contents / "Frameworks" / "Sparkle.framework")], check=True)
info = {
    "CFBundleIdentifier": "com.jmpijll.slightshot.updater-review." + args.name.lower(),
    "CFBundleExecutable": "UpdateDiscoveryProbe", "CFBundleName": "Slightshot updater review",
    "CFBundleDisplayName": "Slightshot updater review", "CFBundlePackageType": "APPL",
    "CFBundleVersion": args.host_build, "CFBundleShortVersionString": args.host_version,
    "LSMinimumSystemVersion": "27.0", "NSPrincipalClass": "NSApplication",
    "SUFeedURL": args.feed_url, "SUPublicEDKey": args.public_key_file.read_text().strip(),
    "SUEnableAutomaticChecks": False, "SUAllowsAutomaticUpdates": False,
    "SUAutomaticallyUpdate": False, "SUEnableInstallerLauncherService": False,
}
with (contents / "Info.plist").open("wb") as file:
    plistlib.dump(info, file)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
metadata = {"app": str(app), "bundleIdentifier": info["CFBundleIdentifier"],
            "hostMarketingVersion": args.host_version, "hostBuild": args.host_build,
            "feedURL": args.feed_url, "syntheticMetadata": True,
            "signing": "task-owned ad-hoc host; copied real Sparkle 2.10.0 framework",
            "probeSourceSHA256": hashlib.sha256((root / "UpdateDiscoveryProbe.m").read_bytes()).hexdigest(),
            "probeExecutableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest()}
(root / (args.name + "-bundle.json")).write_text(json.dumps(metadata, indent=2) + "\n")
print(app)
