#!/usr/bin/env python3
"""Check that invalid signing configuration stops before any release mutation."""

import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ReleasePreflightTests(unittest.TestCase):
    def reject(self, arguments, diagnostic):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("ONESHOT_")}
        process = subprocess.run(
            ["zsh", str(ROOT / "scripts/build-release.sh"), "--version", "0.1.0-alpha.1", *arguments],
            cwd=ROOT, env=environment, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(process.returncode, 64, process.stdout + process.stderr)
        self.assertIn(diagnostic, process.stderr)

    def test_default_requires_reusable_identity_without_ad_hoc_fallback(self):
        self.reject([], "there is no ad-hoc fallback")

    def test_certificate_modes_reject_ad_hoc_selector(self):
        for mode in ("self-signed", "apple-development", "developer-id"):
            with self.subTest(mode=mode):
                self.reject(["--signing-mode", mode, "--signing-identity", "-"],
                            "there is no ad-hoc fallback")

    def test_identity_must_be_an_unambiguous_certificate_fingerprint(self):
        self.reject(["--signing-identity", "Example Signing"], "40-character SHA1")

    def test_ad_hoc_cannot_silently_ignore_certificate_configuration(self):
        self.reject(["--signing-mode", "ad-hoc", "--signing-identity", "a" * 40],
                    "cannot use a certificate identity")
        self.reject(["--signing-mode", "ad-hoc", "--signing-keychain", "/tmp/unused.keychain-db"],
                    "cannot use a signing keychain")

    def test_invalid_team_configuration_fails_before_build(self):
        for mode, team in (("self-signed", "ABCDE12345"), ("developer-id", "lowercase")):
            with self.subTest(mode=mode):
                self.reject(["--signing-mode", mode, "--signing-identity", "a" * 40,
                             "--expected-team-id", team], "valid only for Apple modes")

    def test_unknown_mode_and_missing_keychain_fail_before_build(self):
        self.reject(["--signing-mode", "automatic"], "Unknown signing mode")
        self.reject(["--signing-identity", "a" * 40, "--signing-keychain", "relative.keychain-db"],
                    "existing absolute keychain")


if __name__ == "__main__":
    unittest.main()
