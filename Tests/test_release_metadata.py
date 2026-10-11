"""Exercise the release build policy with real Git histories and appcasts."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/release_metadata.py"


class ReleaseMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.repository = Path(cls.workspace.name) / "repository"
        subprocess.run(["git", "init", "-q", "-b", "main", str(cls.repository)], check=True)
        # Real commits, including empty/documentation commits, just like bundle.sh counts.
        commits = "".join(
            f"commit refs/heads/main\ncommitter Test <test@example.invalid> {1700000000 + i} +0000\n"
            f"data {len(str(i))}\n{i}\n\n" for i in range(190)
        )
        subprocess.run(["git", "fast-import", "--quiet"], cwd=cls.repository,
                       input=commits, text=True, check=True)

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

    def test_actual_release_workflow_resolves_and_passes_git_counter(self):
        workflow = (SCRIPT.parents[1] / ".github/workflows/release.yml").read_text()
        step = re.search(r"      - name: Resolve version\n[\s\S]*?        run: \|\n((?:          .+\n)+)", workflow)
        self.assertIsNotNone(step)
        scripts = self.repository / "Scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
        public = self.repository / "public"
        public.mkdir(exist_ok=True)
        self.run_policy()
        shutil.copyfile(self.appcast, public / "appcast.xml")
        output = Path(self.directory.name) / "github-output"
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", textwrap.dedent(step.group(1))],
            cwd=self.repository, text=True, capture_output=True,
            env=dict(os.environ, REQUESTED_VERSION="1.5.1", PUBLISH="false",
                     GITHUB_REF_NAME="v1.5.1", GITHUB_RUN_NUMBER="13", GITHUB_OUTPUT=str(output))
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(outputs.get("build"), "190", "release must use the same counter as local bundles")
        self.assertEqual(outputs.get("version"), "1.5.1")
        build_step = workflow.split("      - name: Build and sign the app\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("BUILD: ${{ steps.version.outputs.build }}", build_step)

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


if __name__ == "__main__":
    unittest.main()
