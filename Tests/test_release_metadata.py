"""Exercise the release build policy with real Git histories and appcasts."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/release_metadata.py"
WORKFLOWS = SCRIPT.parents[1] / ".github/workflows"


def workflow_step(workflow, name):
    match = re.search(rf"      - name: {re.escape(name)}\n[\s\S]*?        run: \|\n((?:(?:          .*)?\n)+)",
                      (WORKFLOWS / workflow).read_text())
    assert match, f"{workflow} has no run block named {name!r}"
    return textwrap.dedent(match.group(1))


class ReleaseMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.repository = Path(cls.workspace.name) / "repository"
        subprocess.run(["git", "init", "-q", "-b", "main", str(cls.repository)], check=True)
        # Real commits, including empty/documentation commits, just like bundle.sh counts.
        feed = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
                '<item><sparkle:version>12</sparkle:version>'
                '<sparkle:shortVersionString>1.5.0</sparkle:shortVersionString></item></channel></rss>')
        commits = f"blob\nmark :1\ndata {len(feed)}\n{feed}\n" + "".join(
            f"commit refs/heads/main\ncommitter Test <test@example.invalid> {1700000000 + i} +0000\n"
            f"data {len(str(i))}\n{i}\n" + ("M 100644 :1 public/appcast.xml\n" if i == 0 else "") + "\n"
            for i in range(190)
        )
        subprocess.run(["git", "fast-import", "--quiet"], cwd=cls.repository,
                       input=commits, text=True, check=True)
        subprocess.run(["git", "remote", "add", "origin", cls.repository.as_uri()],
                       cwd=cls.repository, check=True)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.appcast = Path(self.directory.name) / "appcast.xml"

    def run_policy(self, items=(("1.5.0", "12"),), version="1.5.1", repository=None):
        xml = '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
        for short, build in items:
            xml += (f"<item><sparkle:version>{build}</sparkle:version>"
                    f"<sparkle:shortVersionString>{short}</sparkle:shortVersionString></item>")
        self.appcast.write_text(xml + "</channel></rss>")
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repository", str(repository or self.repository),
             "--appcast", str(self.appcast), "--version", version],
            env=dict(os.environ, GITHUB_RUN_NUMBER="13"), text=True, capture_output=True
        )

    def test_local_high_build_can_update_despite_small_ci_run_counter(self):
        result = self.run_policy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "190")
        # The reported 1.4.0/128 and later local 1.4.x/162 can both discover it.
        self.assertGreater(int(result.stdout), 128)
        self.assertGreater(int(result.stdout), 162)

    def run_workflow(self, repository=None, version="1.5.1"):
        repository = repository or self.repository
        workflow = (SCRIPT.parents[1] / ".github/workflows/release.yml").read_text()
        step = re.search(r"      - name: Resolve version\n[\s\S]*?        run: \|\n((?:          .+\n)+)", workflow)
        self.assertIsNotNone(step)
        scripts = repository / "Scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
        public = repository / "public"
        public.mkdir(exist_ok=True)
        self.run_policy()
        shutil.copyfile(self.appcast, public / "appcast.xml")
        output = Path(self.directory.name) / "github-output"
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", textwrap.dedent(step.group(1))],
            cwd=repository, text=True, capture_output=True,
            env=dict(os.environ, REQUESTED_VERSION=version, PUBLISH="false", RUNNER_TEMP=self.directory.name,
                     GITHUB_REF_NAME=f"v{version}", GITHUB_RUN_NUMBER="13", GITHUB_OUTPUT=str(output))
        )
        return result, output, workflow

    def test_actual_release_workflow_resolves_and_passes_git_counter(self):
        result, output, workflow = self.run_workflow()
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(outputs.get("build"), "190", "release must use the same counter as local bundles")
        self.assertEqual(outputs.get("version"), "1.5.1")
        build_step = workflow.split("      - name: Build and sign the app\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("BUILD: ${{ steps.version.outputs.build }}", build_step)

    def test_actual_workflow_rejects_stale_tag_against_newer_canonical_feed(self):
        root = Path(self.directory.name)
        canonical, candidate = root / "canonical", root / "candidate"
        for clone in (canonical, candidate):
            subprocess.run(["git", "clone", "-q", self.repository.as_uri(), str(clone)], check=True)
        feed = canonical / "public/appcast.xml"
        feed.write_text(feed.read_text().replace(">12<", ">191<").replace("1.5.0", "1.5.1"))
        subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-q", "-am", "Publish newer feed"], cwd=canonical, check=True)
        subprocess.run(["git", "remote", "set-url", "origin", canonical.as_uri()], cwd=candidate, check=True)
        before = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=candidate)
        result, output, _ = self.run_workflow(candidate, version="1.5.2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must exceed published build 191", result.stderr)
        self.assertFalse(output.exists())
        self.assertEqual(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=candidate), before)

    def test_build_must_exceed_every_published_item_not_only_first(self):
        result = self.run_policy(items=(("1.5.0", "12"), ("1.4.2", "191")))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("must exceed published build 191", result.stderr)

    def test_equal_build_cannot_be_republished(self):
        result = self.run_policy(items=(("1.5.0", "190"),))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must exceed published build 190", result.stderr)

    def test_newer_build_cannot_reuse_or_decrease_marketing_version(self):
        for version in ("1.5.0", "1.4.9"):
            with self.subTest(version=version):
                result = self.run_policy(version=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must exceed published version 1.5.0", result.stderr)

    def test_marketing_versions_are_numeric(self):
        result = self.run_policy(items=(("1.9.9", "12"),), version="1.10.0")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shallow_checkout_cannot_silently_publish_small_counter(self):
        clone = Path(self.directory.name) / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth", "1", self.repository.as_uri(), str(clone)],
                       check=True)
        result = self.run_policy(repository=clone)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("require full Git history", result.stderr)

    def test_malformed_feed_or_versions_block_publication(self):
        for items, version in ((("1.5.0", "invalid"),), "1.5.1"), ((("bad", "12"),), "1.5.1"), ((("1.5.0", "12"),), "1.5"):
            with self.subTest(items=items, version=version):
                result = self.run_policy(items=items, version=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_missing_rss_channel_blocks_publication(self):
        self.appcast.write_text("<not-an-appcast />")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--repository", str(self.repository),
             "--appcast", str(self.appcast), "--version", "1.5.1"],
            text=True, capture_output=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected an RSS channel", result.stderr)


TRUSTING_RUNNER = """
import runpy, ssl, sys, urllib.request
context = ssl.create_default_context(cafile=sys.argv.pop(1))
urllib.request.install_opener(urllib.request.build_opener(urllib.request.HTTPSHandler(context=context)))
sys.argv[0] = sys.argv[1]
del sys.argv[1]
runpy.run_path(sys.argv[0], run_name="__main__")
"""


class DownloadCheckTests(unittest.TestCase):
    """The Pages gate and the publish job refuse a feed whose downloads are not public HTTPS files."""

    @classmethod
    def setUpClass(cls):
        workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(workspace.cleanup)
        cls.certificate = Path(workspace.name) / "cert.pem"
        key = Path(workspace.name) / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
                        "-keyout", str(key), "-out", str(cls.certificate)], check=True, capture_output=True)
        payload = b"signed disk image" * 1000
        cls.size = len(payload)
        cls.requests = {}
        servers = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                name = self.path.rsplit("/", 1)[-1]
                count = cls.requests[name] = cls.requests.get(name, 0) + 1
                if name == "dropped-once.dmg" and count == 1:
                    self.close_connection = True
                    return
                if name in ("busy-once.dmg", "limited-once.dmg") and count == 1 or name == "down.dmg":
                    self.send_response(429 if name.startswith("limited") else 503)
                    self.send_header("Retry-After", "0")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                elif name == "redirected.dmg":
                    self.send_response(302)
                    self.send_header("Location", "/download/ok.dmg")
                    self.end_headers()
                elif name == "downgraded.dmg":
                    self.send_response(302)
                    self.send_header("Location", f"{servers['http']}ok.dmg")
                    self.end_headers()
                elif name == "forbidden.dmg":
                    self.send_error(403)
                elif name in ("ok.dmg", "dropped-once.dmg", "busy-once.dmg", "limited-once.dmg", "partial.dmg"):
                    self.send_response(206 if name == "partial.dmg" else 200)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                else:
                    self.send_error(404)

            def log_message(self, *args):
                pass

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cls.certificate, key)
        for scheme in ("https", "http"):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            if scheme == "https":
                server.socket = context.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cls.addClassCleanup(server.server_close)
            cls.addClassCleanup(server.shutdown)
            servers[scheme] = f"{scheme}://127.0.0.1:{server.server_port}/download/"
        cls.base, cls.plain = servers["https"], servers["http"]

    def setUp(self):
        self.requests.clear()

    def check(self, *enclosures):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        appcast = Path(directory.name) / "appcast.xml"
        appcast.write_text("<rss><channel>" + "".join(
            f'<item><enclosure url="{url if ":" in url else self.base + url}" length="{length}"/></item>'
            for url, length in enclosures) + "</channel></rss>")
        return subprocess.run([sys.executable, "-c", TRUSTING_RUNNER, str(self.certificate), str(SCRIPT),
                               "--check-downloads", str(appcast)], text=True, capture_output=True)

    def test_public_https_downloads_with_matching_lengths_pass(self):
        result = self.check(("ok.dmg", self.size), ("redirected.dmg", self.size))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count(f"{self.size} bytes"), 2)

    def test_unavailable_download_blocks_the_feed_without_retrying(self):
        for name, code in (("draft.dmg", 404), ("forbidden.dmg", 403)):
            with self.subTest(name=name):
                result = self.check(("ok.dmg", self.size), (name, self.size))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{name} is not publicly available: HTTP Error {code}", result.stderr)
                self.assertEqual(self.requests[name], 1)

    def test_only_a_final_https_200_counts_as_public(self):
        for name in ("partial.dmg", "downgraded.dmg"):
            with self.subTest(name=name):
                result = self.check((name, self.size))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("expected 200 over HTTPS", result.stderr)

    def test_non_https_enclosures_are_rejected_before_any_request(self):
        for url in (self.plain + "ok.dmg", "file:///etc/hosts", "data:,signed", "https:///missing-host"):
            with self.subTest(url=url):
                result = self.check((url, self.size))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("is not an https:// download URL", result.stderr)
        self.assertEqual(self.requests, {})

    def test_transient_failures_are_retried(self):
        result = self.check(("busy-once.dmg", self.size), ("limited-once.dmg", self.size),
                            ("dropped-once.dmg", self.size))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests, {"busy-once.dmg": 2, "limited-once.dmg": 2, "dropped-once.dmg": 2})
        self.assertIn("busy-once.dmg: attempt 1 failed; retrying in 0s", result.stderr)

    def test_persistent_server_errors_stop_after_five_attempts(self):
        result = self.check(("down.dmg", self.size))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("down.dmg is not publicly available: HTTP Error 503", result.stderr)
        self.assertEqual(self.requests["down.dmg"], 5)

    def test_length_mismatch_blocks_the_feed(self):
        result = self.check(("ok.dmg", self.size + 1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"has {self.size} bytes; the appcast expects {self.size + 1}", result.stderr)

    def test_pages_checks_downloads_before_uploading_the_feed(self):
        pages = (WORKFLOWS / "pages.yml").read_text()
        gate = pages.index("--check-downloads public/appcast.xml")
        self.assertLess(gate, pages.index("actions/upload-pages-artifact@"))
        self.assertLess(gate, pages.index("actions/deploy-pages@"))


FAKE_GH = r'''
import hashlib, json, os, sys
state_path = os.environ["FAKE_GH_STATE"]
state = json.load(open(state_path))
args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(" ".join(args[:2]) + "\n")
def digest(path):
    return "sha256:" + hashlib.sha256(open(path, "rb").read()).hexdigest()
def files():
    return {os.path.basename(a): digest(a) for a in args if os.path.isfile(a)}
if args[:2] == ["release", "view"]:
    release = state.get(args[2])
    if release is None:
        sys.exit("release not found")
    if "isDraft" in args:
        print("true" if release["draft"] else "false")
    else:
        for name, value in release["assets"].items():
            print(name, value)
elif args[:2] == ["release", "create"]:
    state[args[2]] = {"draft": "--draft" in args, "assets": files()}
elif args[:2] == ["release", "upload"]:
    state[args[2]]["assets"].update(files())
elif args[:2] == ["release", "edit"]:
    state[args[2]]["draft"] = "--draft=false" not in args
elif args[:1] == ["api"]:
    print(os.environ.get("FAKE_RUN_ID", "4242"))
elif args[:2] == ["run", "watch"]:
    sys.exit(int(os.environ.get("FAKE_WATCH_EXIT", "0")) if "--exit-status" in args else 0)
else:
    sys.exit("unexpected gh call: " + " ".join(args))
json.dump(state, open(state_path, "w"))
'''


class PublishJobTests(unittest.TestCase):
    """Run the Release publish job's own steps against a local remote and a stateful fake gh."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.identity = {"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                         "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        self.remote = self.root / "remote.git"
        self.git("init", "-q", "--bare", "-b", "main", str(self.remote), cwd=self.root)
        self.maintainer = self.root / "maintainer"
        self.git("clone", "-q", str(self.remote), str(self.maintainer), cwd=self.root)
        (self.maintainer / "public").mkdir()
        (self.maintainer / "public/appcast.xml").write_text("<rss>1.6.0</rss>\n")
        (self.maintainer / "README.md").write_text("source\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "Release source")
        self.source = self.git("rev-parse", "HEAD").strip()
        (self.maintainer / "README.md").write_text("source\nlater main commit\n")
        self.git("commit", "-q", "-am", "Later main commit")
        self.git("push", "-q", "origin", "main")
        self.runner = self.root / "runner"
        self.git("clone", "-q", str(self.remote), str(self.runner), cwd=self.root)
        self.git("checkout", "-q", self.source, cwd=self.runner)
        (self.runner / "feed").mkdir()
        (self.runner / "feed/appcast.xml").write_text("<rss>1.7.0 1.6.0</rss>\n")
        assets = self.runner / "release-assets"
        assets.mkdir()
        for name in ("Slightshot-1.7.0.dmg", "Slightshot-windows-x64.zip", "Slightshot-windows-arm64.zip",
                     "Slightshot-windows-x64-setup.exe", "Slightshot-windows-arm64-setup.exe"):
            (assets / name).write_bytes(name.encode() * 100)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "gh").write_text(f"#!/bin/sh\nexec {sys.executable} {self.root / 'fake_gh.py'} \"$@\"\n")
        (self.root / "fake_gh.py").write_text(FAKE_GH)
        (self.bin / "sleep").write_text("#!/bin/sh\n")
        for tool in self.bin.iterdir():
            tool.chmod(0o755)
        self.state = self.root / "gh-state.json"
        self.state.write_text("{}")
        self.log = self.root / "gh-log.txt"
        self.log.touch()

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.maintainer, check=True, text=True,
                              capture_output=True, env=dict(os.environ, **self.identity)).stdout

    def step(self, name, **env):
        environment = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", RUNNER_TEMP=str(self.root),
                           VERSION="1.7.0", GITHUB_SHA=self.source, GITHUB_REPOSITORY="owner/slightshot",
                           GITHUB_SERVER_URL="https://github.com", FAKE_GH_STATE=str(self.state),
                           FAKE_GH_LOG=str(self.log), **self.identity)
        environment.update(env)
        return subprocess.run(["bash", "-e", "-c", workflow_step("release.yml", name)], cwd=self.runner,
                              env=environment, text=True, capture_output=True)

    def release(self):
        return json.loads(self.state.read_text()).get("v1.7.0")

    def digests(self):
        return {path.name: "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (self.runner / "release-assets").iterdir()}

    def test_new_release_is_uploaded_verified_and_published(self):
        result = self.step("Publish the GitHub release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.release(), {"draft": False, "assets": self.digests()})

    def test_rerun_reuses_a_published_release_with_the_same_bytes(self):
        self.state.write_text(json.dumps({"v1.7.0": {"draft": False, "assets": self.digests()}}))
        result = self.step("Publish the GitHub release")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertNotIn("release create", calls)
        self.assertNotIn("release upload", calls)

    def test_published_release_with_other_bytes_is_not_reused(self):
        assets = dict(self.digests(), **{"Slightshot-1.7.0.dmg": "sha256:" + "0" * 64})
        self.state.write_text(json.dumps({"v1.7.0": {"draft": False, "assets": assets}}))
        result = self.step("Publish the GitHub release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not carry this run's Slightshot-1.7.0.dmg", result.stdout)
        self.assertNotIn("release upload", self.log.read_text())

    def test_leftover_draft_gets_this_runs_bytes_before_publication(self):
        stale = {name: "sha256:" + "0" * 64 for name in self.digests()}
        self.state.write_text(json.dumps({"v1.7.0": {"draft": True, "assets": stale}}))
        result = self.step("Publish the GitHub release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.release(), {"draft": False, "assets": self.digests()})

    def test_existing_tag_must_point_at_the_release_source(self):
        result = self.step("Check the version tag")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.git("tag", "v1.7.0", self.source)
        self.git("push", "-q", "origin", "v1.7.0")
        result = self.step("Check the version tag")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.git("tag", "-f", "v1.7.0", "main")
        self.git("push", "-q", "-f", "origin", "v1.7.0")
        result = self.step("Check the version tag")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v1.7.0 points at", result.stdout)

    def feed_base(self):
        return self.git("rev-parse", "main:public/appcast.xml").strip()

    def test_feed_is_committed_onto_current_main_not_the_source(self):
        result = self.step("Commit the appcast onto main", FEED_BASE=self.feed_base())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.git("pull", "-q", "--ff-only")
        self.assertEqual((self.maintainer / "public/appcast.xml").read_text(), "<rss>1.7.0 1.6.0</rss>\n")
        self.assertIn("later main commit", (self.maintainer / "README.md").read_text())
        self.assertEqual(self.git("log", "-1", "--format=%s"), "Publish appcast for v1.7.0\n")

    def test_feed_retries_when_main_moves_during_the_push(self):
        real_git = shutil.which("git")
        (self.bin / "git").write_text(textwrap.dedent(f"""\
            #!/bin/sh
            if [ "$1" = push ] && [ ! -e "{self.root}/raced" ]; then
              touch "{self.root}/raced"
              cd "{self.maintainer}" && echo race >> README.md && "{real_git}" commit -qam Race \\
                && "{real_git}" push -q origin main && cd - > /dev/null
            fi
            exec "{real_git}" "$@"
            """))
        (self.bin / "git").chmod(0o755)
        result = self.step("Commit the appcast onto main", FEED_BASE=self.feed_base())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rejected", result.stderr)
        self.git("pull", "-q", "--ff-only")
        self.assertEqual(self.git("log", "-2", "--format=%s"), "Publish appcast for v1.7.0\nRace\n")

    def test_rerun_skips_a_feed_main_already_publishes(self):
        base = self.feed_base()
        self.assertEqual(self.step("Commit the appcast onto main", FEED_BASE=base).returncode, 0)
        head = self.git("ls-remote", "origin", "main")
        result = self.step("Commit the appcast onto main", FEED_BASE=base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("main already publishes this appcast.", result.stdout)
        self.assertEqual(self.git("ls-remote", "origin", "main"), head)

    def test_feed_changed_on_main_is_not_overwritten(self):
        base = self.feed_base()
        (self.maintainer / "public/appcast.xml").write_text("<rss>edited</rss>\n")
        self.git("commit", "-q", "-am", "Edit feed")
        self.git("push", "-q", "origin", "main")
        head = self.git("ls-remote", "origin", "main")
        result = self.step("Commit the appcast onto main", FEED_BASE=base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed on main after this feed was generated", result.stdout)
        self.assertEqual(self.git("ls-remote", "origin", "main"), head)

    def test_failed_pages_deployment_fails_the_publish_job(self):
        result = self.step("Deploy the update feed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("https://github.com/owner/slightshot/actions/runs/4242", result.stdout)
        result = self.step("Deploy the update feed", FAKE_WATCH_EXIT="1")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
