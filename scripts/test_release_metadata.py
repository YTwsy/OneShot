#!/usr/bin/env python3
"""Exercise preview version rules and the metadata consumed by the app verifier."""

import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest


module_path = Path(__file__).resolve().parents[1] / "packaging/release_metadata.py"
spec = importlib.util.spec_from_file_location("oneshot_release_metadata", module_path)
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
COMMIT = "0123456789abcdef0123456789abcdef01234567"


class ReleaseMetadataTests(unittest.TestCase):
    def test_preview_versions_keep_numeric_marketing_and_exact_tag(self):
        for version in ["0.1.0-alpha.1", "1.2.3-beta.0", "12.30.4-rc.12"]:
            with self.subTest(version=version):
                main = metadata.bundle_metadata(version, "17", COMMIT)
                capture = metadata.bundle_metadata(version, "17", COMMIT, True)
                self.assertEqual(main["CFBundleShortVersionString"], version.split("-")[0])
                self.assertEqual(main["OneShotReleaseTag"], "v" + version)
                self.assertEqual(main["CFBundleVersion"], "17")
                self.assertEqual(main["OneShotSourceCommit"], COMMIT)
                self.assertEqual(capture["OneShotReleaseTag"], main["OneShotReleaseTag"])
                self.assertEqual(capture["CFBundleIdentifier"], metadata.CAPTURE_ID)
                self.assertTrue(main["NSScreenCaptureUsageDescription"])
                self.assertEqual(capture["NSScreenCaptureUsageDescription"], main["NSScreenCaptureUsageDescription"])

    def test_ambiguous_or_shell_sensitive_version_and_invalid_provenance_rejected(self):
        versions = ["0.1.0", "v0.1.0-alpha.1", "01.1.0-alpha.1", "0.01.0-alpha.1",
                    "0.1.0-alpha.01", "0.1.0-alpha", "0.1.0-preview.1", "0.1.0-alpha.1+local",
                    "0.1.0-alpha.1\n", "0.1.0-alpha.1;touch-x", "65536.0.0-alpha.1"]
        for version in versions:
            with self.subTest(version=version), self.assertRaises(ValueError):
                metadata.validate(version, "1", COMMIT)
        for build in ["0", "-1", "01", "1.0", "1\n", "10000"]:
            with self.subTest(build=build), self.assertRaises(ValueError):
                metadata.validate("0.1.0-alpha.1", build, COMMIT)
        for commit in ["HEAD", COMMIT[:7], COMMIT.upper(), "g" * 40]:
            with self.subTest(commit=commit), self.assertRaises(ValueError):
                metadata.validate("0.1.0-alpha.1", "1", commit)

    def test_metadata_is_new_only_and_declares_unsigned_preview_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "OneShot.app"
            metadata.write_bundle_metadata(app, "0.1.0-alpha.1", "1", COMMIT)
            plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(plist["LSMinimumSystemVersion"], "14.0")
            self.assertEqual(plist["OneShotSigningStatus"], "ad-hoc-unnotarized")
            with self.assertRaises(FileExistsError):
                metadata.write_bundle_metadata(app, "0.1.0-alpha.1", "1", COMMIT)
            (root / "test.dmg").write_bytes(b"fixture")
            metadata.write_manifest(root, "0.1.0-alpha.1", "1", COMMIT)
            import json
            manifest = json.loads((root / "release-manifest.json").read_text())
            self.assertTrue(manifest["adHocSigned"])
            self.assertFalse(manifest["notarized"])
            self.assertFalse(manifest["developerIDSigned"])
            self.assertEqual(manifest["sourceCommit"], COMMIT)
            with self.assertRaises(FileExistsError):
                metadata.write_manifest(root, "0.1.0-alpha.1", "1", COMMIT)


if __name__ == "__main__":
    unittest.main()
