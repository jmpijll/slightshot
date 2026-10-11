#!/usr/bin/env python3
"""Probe exact candidate appcast bytes through real Sparkle on owned loopback HTTP."""
import argparse
import hashlib
import http.server
import json
import pathlib
import subprocess
import threading
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--feed", type=pathlib.Path, required=True)
parser.add_argument("--framework", type=pathlib.Path, required=True)
parser.add_argument("--public-key-file", type=pathlib.Path, required=True)
parser.add_argument("--source-commit", required=True)
parser.add_argument("--output-name", required=True)
args = parser.parse_args()
feed = args.feed.read_bytes()
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.fromstring(feed).find("channel/item")
candidate_build = item.findtext("sparkle:version", namespaces=ns)
candidate_version = item.findtext("sparkle:shortVersionString", namespaces=ns)
if candidate_version != "1.5.1" or not candidate_build.isdecimal() or int(candidate_build) <= 162:
    raise SystemExit("Candidate must be 1.5.1 with its actual release build greater than162.")
output = root / args.output_name
if output.exists():
    raise SystemExit(f"Refusing to overwrite existing evidence: {output}")
output.mkdir()
(output / "candidate-appcast.xml").write_bytes(feed)
requests = []

class FeedHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append({"method": "GET", "path": self.path})
        if self.path.split("?", 1)[0] != "/appcast.xml":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/rss+xml")
        self.send_header("Content-Length", str(len(feed)))
        self.end_headers()
        self.wfile.write(feed)

    def log_message(self, format, *parameters):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FeedHandler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
feed_url = f"http://127.0.0.1:{server.server_port}/appcast.xml"
cases = []
try:
    for host_build, case_name in [("128", "reported128"), ("162", "high162"), ("9", "public9")]:
        name = f"{args.output_name}-{case_name}"
        subprocess.run(["python3", str(root / "build_probe.py"), "--framework", str(args.framework),
                        "--host-build", host_build, "--host-version", "1.4.0",
                        "--feed-url", feed_url, "--name", name,
                        "--public-key-file", str(args.public_key_file)], check=True)
        subprocess.run(["python3", str(root / "run_probe.py"), "--app", str(root / (name + ".app")),
                        "--output", str(output / case_name),
                        "--label", f"After fix · candidate 1.5.1 build {candidate_build} · information only",
                        "--expected", "update-found", "--source-commit", args.source_commit], check=True)
        report = json.loads((output / case_name / "discovery-report.json").read_text())
        selected = report.get("selectedUpdate", {})
        if selected != {"marketingVersion": candidate_version, "build": candidate_build,
                        "downloadURL": item.find("enclosure").attrib["url"]}:
            raise SystemExit(f"Sparkle did not select the exact candidate item for installed {host_build}.")
        cases.append({"case": case_name, "hostBuild": host_build,
                      "selectedBuild": selected["build"], "result": report["result"]})
finally:
    server.shutdown()
    server.server_close()
    (output / "loopback-requests.json").write_text(json.dumps(requests, indent=2) + "\n")
    (output / "candidate-provenance.json").write_text(json.dumps({
        "sourceCommit": args.source_commit, "candidateVersion": candidate_version,
        "candidateBuild": candidate_build, "inputFeed": str(args.feed.resolve()),
        "feedSHA256": hashlib.sha256(feed).hexdigest(), "feedURL": feed_url,
        "fixture": "Synthetic installed metadata; exact candidate appcast bytes served on owned loopback.",
        "scope": "Real Sparkle SDK discovery only; no publication, download, signature or installation claim.",
        "cases": cases}, indent=2) + "\n")
print(output)
