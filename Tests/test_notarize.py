"""Exercise release gating without sending anything to Apple."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/notarize.sh"


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.calls = self.root / "calls"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = self.bin / "mock"
        mock.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as log:
    log.write(json.dumps([name] + args) + "\\n")
if name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"id": "submission-id", "status": os.environ.get("STATUS", "Accepted")}))
    sys.exit(int(os.environ.get("MOCK_SUBMIT_EXIT", "0")))
if name == "xcrun" and args[:2] == ["notarytool", "log"]:
    pathlib.Path(args[-1]).write_text('{"issues": ["test rejection"]}')
if name == "spctl":
    sys.exit(int(os.environ.get("ASSESS_EXIT", "0")))
''')
        mock.chmod(0o755)
        for name in ("xcrun", "spctl", "codesign", "ditto"):
            (self.bin / name).symlink_to(mock)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        CALLS=str(self.calls), NOTARY_PROFILE="test-profile")

    def run_notary(self, suffix=".dmg", **env):
        target = self.root / f"Test app{suffix}"
        target.mkdir() if suffix == ".app" else target.touch()
        result = subprocess.run(["bash", str(SCRIPT), str(target)],
                                env=dict(self.env, **env), text=True, capture_output=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return result, calls, target

    def test_dmg_uses_disk_image_assessment(self):
        result, calls, _ = self.run_notary()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[:4] == ["spctl", "--assess", "--type", "open"] for call in calls))
        self.assertTrue(any(call[:3] == ["xcrun", "stapler", "validate"] for call in calls))

    def test_app_archive_is_temporary_and_app_is_assessed(self):
        result, calls, _ = self.run_notary(".app")
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = next(call[-1] for call in calls if call[0] == "ditto")
        self.assertFalse(Path(archive).parent.exists())
        self.assertTrue(any(call[:4] == ["spctl", "--assess", "--type", "execute"] for call in calls))

    def test_apple_rejection_blocks_stapling_and_preserves_log(self):
        result, calls, target = self.run_notary(STATUS="Invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ["xcrun", "stapler"] for call in calls))
        self.assertTrue(Path(f"{target}.notary-log.json").exists())

    def test_submission_error_blocks_stapling(self):
        result, calls, _ = self.run_notary(MOCK_SUBMIT_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ["xcrun", "stapler"] for call in calls))

    def test_pending_submission_is_not_success(self):
        result, calls, _ = self.run_notary(STATUS="In Progress")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "spctl" for call in calls))

    def test_gatekeeper_rejection_is_not_swallowed(self):
        result, _, _ = self.run_notary(ASSESS_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Notarised and verified", result.stdout)

    def test_zip_rejected_before_submission(self):
        result, calls, _ = self.run_notary(".zip")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
