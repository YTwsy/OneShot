#!/usr/bin/env python3
"""Exercise preview version rules and the metadata consumed by the app verifier."""

import importlib.util
import copy
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


module_path = Path(__file__).resolve().parents[1] / "packaging/release_metadata.py"
spec = importlib.util.spec_from_file_location("oneshot_release_metadata", module_path)
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
COMMIT = "0123456789abcdef0123456789abcdef01234567"


def signing_report(mode):
    certificate = mode != "ad-hoc"
    return {"schemaVersion": 1, "signingMode": mode, "components": [
        {"role": role, "identifier": identifier, "cdhash": str(index) * 40,
         "designatedRequirement": ('identifier "' + identifier + '" and certificate leaf = H"' + "a" * 40 + '"')
         if certificate else 'cdhash H"' + str(index) * 40 + '"',
         "teamIdentifier": "ABCDE12345" if mode in ("apple-development", "developer-id") else None,
         "certificateSHA256": "a" * 64 if certificate else None,
         "signatureKind": "certificate" if certificate else "ad-hoc"}
        for index, (role, identifier) in enumerate(metadata.COMPONENT_IDENTIFIERS.items(), 1)]}


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

    def test_all_signing_modes_have_truthful_bundle_and_manifest_metadata(self):
        for mode in metadata.SIGNING_MODES:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = root / "OneShot.app"
                metadata.write_bundle_metadata(app, "1.2.3-beta.4", "29", COMMIT, mode)
                for bundle in [app, app / "Contents/Helpers/OneShot Capture.app"]:
                    plist = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
                    self.assertEqual(plist["OneShotSigningMode"], mode)
                    self.assertEqual(plist["OneShotSigningStatus"], mode + "-unnotarized")
                report = signing_report(mode)
                metadata.write_manifest(root, "1.2.3-beta.4", "29", COMMIT, mode, report)
                manifest = json.loads((root / "release-manifest.json").read_text())
                self.assertEqual(manifest["signingMode"], mode)
                self.assertEqual(manifest["adHocSigned"], mode == "ad-hoc")
                self.assertEqual(manifest["developerIDSigned"], mode == "developer-id")
                self.assertFalse(manifest["notarized"])
                self.assertEqual(manifest["permissionContinuity"], "not-verified")
                self.assertEqual(manifest["signingReport"], report)

    def test_certificate_modes_need_complete_identity_evidence_and_reject_mismatches(self):
        valid = signing_report("developer-id")
        cases = []
        report = copy.deepcopy(valid); report["signingMode"] = "self-signed"; cases.append(report)
        report = copy.deepcopy(valid); report["schemaVersion"] = True; cases.append(report)
        report = copy.deepcopy(valid); report["components"].pop(); cases.append(report)
        report = copy.deepcopy(valid); report["components"][1] = report["components"][0]; cases.append(report)
        report = copy.deepcopy(valid); report["components"][0]["identifier"] = "other.app"; cases.append(report)
        report = copy.deepcopy(valid); report["components"][0]["cdhash"] = "not-a-hash"; cases.append(report)
        report = copy.deepcopy(valid); report["components"][0]["designatedRequirement"] = " "; cases.append(report)
        report = copy.deepcopy(valid); report["components"][0]["teamIdentifier"] = None; cases.append(report)
        report = copy.deepcopy(valid); report["components"][0]["teamIdentifier"] = "OTHER12345"; cases.append(report)
        report = copy.deepcopy(valid); report["components"][0]["certificateSHA256"] = "b" * 64; cases.append(report)
        report = copy.deepcopy(valid); report["components"][0]["certificateSHA256"] = None; cases.append(report)
        report = copy.deepcopy(valid); report["components"][0]["signatureKind"] = "ad-hoc"; cases.append(report)
        for invalid in cases:
            with self.subTest(report=invalid), self.assertRaises(ValueError):
                metadata.validate_signing_report(invalid, "developer-id")
        with self.assertRaises(ValueError):
            metadata.validate_signing_report(signing_report("self-signed"), "ad-hoc")
        for mode in ("self-signed", "apple-development", "developer-id"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                with self.assertRaises(ValueError):
                    metadata.write_manifest(Path(temporary), "0.1.0-alpha.1", "1", COMMIT, mode)
                self.assertFalse((Path(temporary) / "release-manifest.json").exists())

    def test_reports_do_not_allow_private_material_or_unknown_fields(self):
        for field in ["privateKey", "password", "p12", "certificatePEM", "unsupported"]:
            for location in ["report", "component"]:
                with self.subTest(field=field, location=location), tempfile.TemporaryDirectory() as temporary:
                    report = signing_report("self-signed")
                    target = report if location == "report" else report["components"][0]
                    target[field] = "must-not-be-published"
                    root = Path(temporary)
                    with self.assertRaises(ValueError):
                        metadata.write_manifest(root, "0.1.0-alpha.1", "1", COMMIT, "self-signed", report)
                    self.assertFalse((root / "release-manifest.json").exists())

    def test_invalid_mode_is_rejected_before_creating_bundle_files(self):
        for mode in ["", "identity", "developer-id-notarized", "self-signed\n"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                app = Path(temporary) / "OneShot.app"
                with self.assertRaises(ValueError):
                    metadata.write_bundle_metadata(app, "0.1.0-alpha.1", "1", COMMIT, mode)
                self.assertFalse(app.exists())

    def test_cli_reads_report_for_manifest_and_rejects_bad_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / "signing-report.json"
            report.write_text(json.dumps(signing_report("self-signed")))
            args = [sys.executable, str(module_path), "manifest", "--version", "0.1.0-alpha.1",
                    "--build-number", "2", "--commit", COMMIT, "--path", str(root),
                    "--signing-mode", "self-signed", "--signing-report", str(report)]
            result = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((root / "release-manifest.json").read_text())
            self.assertEqual(manifest["signingReport"]["signingMode"], "self-signed")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / "signing-report.json"
            report.write_text("[]")
            result = subprocess.run([sys.executable, str(module_path), "manifest", "--version", "0.1.0-alpha.1",
                                     "--build-number", "2", "--commit", COMMIT, "--path", str(root),
                                     "--signing-mode", "self-signed", "--signing-report", str(report)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertFalse((root / "release-manifest.json").exists())

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

    def test_metadata_is_new_only_and_declares_ad_hoc_preview_boundaries(self):
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
            manifest = json.loads((root / "release-manifest.json").read_text())
            self.assertTrue(manifest["adHocSigned"])
            self.assertFalse(manifest["notarized"])
            self.assertFalse(manifest["developerIDSigned"])
            self.assertEqual(manifest["sourceCommit"], COMMIT)
            with self.assertRaises(FileExistsError):
                metadata.write_manifest(root, "0.1.0-alpha.1", "1", COMMIT)


if __name__ == "__main__":
    unittest.main()
