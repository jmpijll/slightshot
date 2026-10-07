"""The shared catalogue must survive Windows checkout line-ending conversion."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ui_icons", ROOT / "Scripts/generate_ui_icons.py")
ICONS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ICONS)


class IconCatalogueTests(unittest.TestCase):
    def test_windows_checkout_produces_identical_native_assets(self):
        data, digest = ICONS.catalogue()
        original = ICONS.SOURCE.read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory) / "icons.json"
            checkout.write_bytes(original.replace(b"\n", b"\r\n"))
            with patch.object(ICONS, "SOURCE", checkout):
                windows_data, windows_digest = ICONS.catalogue()
        self.assertEqual(ICONS.swift(data, digest), ICONS.swift(windows_data, windows_digest))
        self.assertEqual(ICONS.csharp(data, digest), ICONS.csharp(windows_data, windows_digest))
