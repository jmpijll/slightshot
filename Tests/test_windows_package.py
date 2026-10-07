"""Guard the Windows download layout and architecture before uploading it."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts/package_windows.py"
SPEC = importlib.util.spec_from_file_location("package_windows", SCRIPT)
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)


class WindowsPackageTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.publish = self.root / "published app"
        self.publish.mkdir()
        self.archive = self.root / "download.zip"

    def executable(self, machine=0x8664):
        data = bytearray(256)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 0x3C, 0x80)
        data[0x80:0x84] = b"PE\0\0"
        struct.pack_into("<H", data, 0x84, machine)
        (self.publish / "Slightshot.exe").write_bytes(data)
        return data

    def test_archive_opens_directly_to_one_executable_for_both_architectures(self):
        for architecture, machine in (("x64", 0x8664), ("arm64", 0xAA64)):
            with self.subTest(architecture=architecture):
                original = self.executable(machine)
                PACKAGER.package(self.publish, self.archive, architecture)
                with zipfile.ZipFile(self.archive) as archive:
                    self.assertEqual(archive.namelist(), ["Slightshot.exe"])
                    self.assertEqual(archive.read("Slightshot.exe"), original)

    def test_folder_publish_is_rejected_instead_of_dropping_its_dependencies(self):
        self.executable()
        (self.publish / "Slightshot.dll").touch()
        (self.publish / "runtime").mkdir()
        with self.assertRaisesRegex(ValueError, "only Slightshot.exe"):
            PACKAGER.package(self.publish, self.archive, "x64")
        self.assertFalse(self.archive.exists())

    def test_missing_or_misnamed_executable_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "only Slightshot.exe"):
            PACKAGER.package(self.publish, self.archive, "x64")
        self.executable()
        (self.publish / "Slightshot.exe").rename(self.publish / "Other.exe")
        with self.assertRaisesRegex(ValueError, "only Slightshot.exe"):
            PACKAGER.package(self.publish, self.archive, "x64")

    def test_wrong_architecture_is_rejected_before_archive_creation(self):
        self.executable(0xAA64)
        with self.assertRaisesRegex(ValueError, "not a x64"):
            PACKAGER.package(self.publish, self.archive, "x64")
        self.assertFalse(self.archive.exists())

    def test_non_executable_and_truncated_headers_are_rejected(self):
        for content in (b"", b"MZ", b"MZ" + bytes(62)):
            with self.subTest(content=content):
                (self.publish / "Slightshot.exe").write_bytes(content)
                with self.assertRaises(ValueError):
                    PACKAGER.package(self.publish, self.archive, "x64")
                self.assertFalse(self.archive.exists())


if __name__ == "__main__":
    unittest.main()
