#!/usr/bin/env python3
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from update_ggm_manifest import (
    build_manifest,
    load_manifest,
    needs_update,
    version_from_setup_url,
    write_manifest,
)


class VersionFromSetupURLTests(unittest.TestCase):
    def test_parses_absolute_setup_url(self):
        self.assertEqual(
            version_from_setup_url("https://tw.beanfun.com/ggm/GGMSetup_1.5.0.2.exe"),
            "1.5.0.2",
        )

    def test_parses_location_with_query(self):
        self.assertEqual(
            version_from_setup_url(
                "https://tw.beanfun.com/ggm/GGMSetup_1.6.0.0.exe?foo=1"
            ),
            "1.6.0.0",
        )

    def test_rejects_unexpected_filename(self):
        with self.assertRaises(ValueError):
            version_from_setup_url("https://tw.beanfun.com/ggm/index.aspx")


class ManifestUpdateTests(unittest.TestCase):
    def test_needs_update_when_cv_differs(self):
        self.assertTrue(needs_update("1.5.0.2", "1.5.0.3"))
        self.assertFalse(needs_update("1.5.0.2", "1.5.0.2"))

    def test_write_manifest_round_trip(self):
        payload = build_manifest(
            version="1.5.0.3",
            sha256="a" * 64,
            updated_at="2026-08-19T00:00:00Z",
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "ggm-manifest.json"
            write_manifest(path, payload)
            loaded = load_manifest(path)
            text = path.read_text(encoding="utf-8")
        self.assertEqual(loaded["schemaVersion"], 1)
        self.assertEqual(loaded["updatedAt"], "2026-08-19T00:00:00Z")
        self.assertEqual(loaded["maplestory"]["ggmClientVersion"], "1.5.0.3")
        self.assertEqual(loaded["maplestory"]["ggmWebStartDllSha256"], "a" * 64)
        self.assertTrue(text.endswith("\n"))
        json.loads(text)


if __name__ == "__main__":
    unittest.main()
