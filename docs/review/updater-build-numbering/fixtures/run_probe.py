#!/usr/bin/env python3
"""Run only a previously built isolated information-only Sparkle fixture."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=pathlib.Path, required=True)
parser.add_argument("--output", type=pathlib.Path, required=True)
parser.add_argument("--label", required=True)
parser.add_argument("--expected", choices=["update-found", "no-update"], required=True)
parser.add_argument("--source-commit", required=True)
args = parser.parse_args()
app = args.app.resolve()
if not str(app).startswith("/private/tmp/slightshot-updater-1.5.1/"):
    raise SystemExit("Only task-owned updater fixture bundles may be run.")
with (app / "Contents" / "Info.plist").open("rb") as file:
    info = plistlib.load(file)
if not info["CFBundleIdentifier"].startswith("com.jmpijll.slightshot.updater-review."):
    raise SystemExit("Refusing to run a production/user app.")
if info["SUEnableAutomaticChecks"] or info["SUAllowsAutomaticUpdates"]:
    raise SystemExit("Automatic checks/downloads must be disabled.")
args.output.mkdir(parents=True, exist_ok=True)
if (args.output / "discovery-report.json").exists():
    raise SystemExit("Refusing to overwrite an existing discovery report.")
feed = urllib.request.urlopen(info["SUFeedURL"], timeout=20).read()
(args.output / "appcast-before-request.xml").write_bytes(feed)
executable = app / "Contents" / "MacOS" / info["CFBundleExecutable"]
command = [str(executable), "--output", str(args.output.resolve()), "--label", args.label,
           "--expected", args.expected, "--source-commit", args.source_commit]
with (args.output / "probe.stdout").open("wb") as stdout, (args.output / "probe.stderr").open("wb") as stderr:
    subprocess.run(command, check=True, timeout=65, stdout=stdout, stderr=stderr)
report = json.loads((args.output / "discovery-report.json").read_text())
provenance = {"command": command, "bundleIdentifier": info["CFBundleIdentifier"],
              "hostMarketingVersion": info["CFBundleShortVersionString"],
              "hostBuild": info["CFBundleVersion"], "sourceCommit": args.source_commit,
              "syntheticHostMetadata": True, "probeOnly": True,
              "feedURL": info["SUFeedURL"], "feedSnapshotSHA256": hashlib.sha256(feed).hexdigest(),
              "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
              "nativeScreenshotSHA256": hashlib.sha256((args.output / "native-discovery.png").read_bytes()).hexdigest(),
              "sparkleVersion": "2.10.0", "result": report.get("result"),
              "matchesExpectedResult": report.get("matchesExpectedResult")}
(args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
if not report.get("matchesExpectedResult") or report.get("updateCheckType") != 2:
    raise SystemExit("Unexpected discovery result or non-probing update type; inspect preserved report.")
print(json.dumps({"result": report["result"], "output": str(args.output), "capture": report["capture"]}, indent=2))
