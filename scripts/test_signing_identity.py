#!/usr/bin/env python3
"""Exercise identity import and cleanup with a stub; never opens a real keychain."""

import base64
import contextlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parent
FINGERPRINT = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
FIXTURE_PASSWORD = "fixture-p12-password-do-not-log"


def embedded_source(name):
    script = (SCRIPTS / name).read_text()
    match = re.fullmatch(r".*?\npython3 - \"\$@\" <<'PY'\n(.*)\nPY\n", script, re.DOTALL)
    if not match:
        raise AssertionError("Expected the script's single embedded Python entrypoint")
    return compile(match.group(1), str(SCRIPTS / name), "exec")


class SecurityStub:
    def __init__(self, fail_import=False, trusted_fingerprint=FINGERPRINT, delete_addition=None):
        self.calls = []
        self.fail_import = fail_import
        self.trusted_fingerprint = trusted_fingerprint
        self.entries = ["/fixture/login.keychain-db", "/fixture/another keychain-db"]
        self.delete_addition = delete_addition
        self.fail_delete = False
        self.fail_list_read = False
        self.fail_list_write = False

    def __call__(self, arguments, **options):
        self.calls.append(arguments)
        if arguments[0] != "/usr/bin/security":
            raise AssertionError("Unexpected subprocess in keychain tooling")
        command = arguments[1]
        if command not in {"create-keychain", "delete-keychain", "list-keychains", "set-keychain-settings",
                           "unlock-keychain", "import", "set-key-partition-list", "find-identity"}:
            raise AssertionError("Unexpected keychain operation or trust/default-keychain mutation")
        if command == "create-keychain":
            Path(arguments[-1]).write_bytes(b"stub-keychain")
        elif command == "delete-keychain":
            # Leave a stale own entry to exercise explicit cleanup, and simulate
            # another process appending an unrelated keychain during deletion.
            if self.delete_addition and self.delete_addition not in self.entries:
                self.entries.append(self.delete_addition)
            if self.fail_delete:
                return subprocess.CompletedProcess(arguments, 1, b"", b"fixture-delete-failed")
            Path(arguments[-1]).unlink()
        elif command == "list-keychains":
            if "-s" in arguments:
                if self.fail_list_write:
                    return subprocess.CompletedProcess(arguments, 1, b"", b"fixture-list-write-failed")
                self.entries = arguments[arguments.index("-s") + 1:]
            else:
                if self.fail_list_read:
                    return subprocess.CompletedProcess(arguments, 1, b"", b"fixture-list-read-failed")
                return subprocess.CompletedProcess(arguments, 0,
                    ("\n".join(shlex.quote(entry) for entry in self.entries) + "\n").encode(), b"")
        elif command == "import" and self.fail_import:
            return subprocess.CompletedProcess(arguments, 1, b"", FIXTURE_PASSWORD.encode())
        elif command == "find-identity":
            # find-identity without -v may repeat an identity in matching/valid sections.
            if "-v" in arguments:
                output = ('  1) ' + self.trusted_fingerprint + ' "OneShot Test Identity"\n') \
                    if self.trusted_fingerprint else '  0 valid identities found\n'
            else:
                output = ('  1) ' + FINGERPRINT + ' "OneShot Test Identity"' +
                          (' (CSSMERR_TP_NOT_TRUSTED)' if self.trusted_fingerprint != FINGERPRINT else '') + '\n') * 2
            return subprocess.CompletedProcess(arguments, 0, output.encode(), b"")
        return subprocess.CompletedProcess(arguments, 0, b"", b"")


class SigningIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="oneshot-identity-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.directory = self.root / "oneshot-signing-fixture"
        self.environment = {
            "RUNNER_TEMP": str(self.root),
            "ONESHOT_SIGNING_MODE": "developer-id",
            "ONESHOT_SIGNING_CERTIFICATE_BASE64": base64.b64encode(b"fixture-not-a-real-p12").decode(),
            "ONESHOT_SIGNING_CERTIFICATE_PASSWORD": FIXTURE_PASSWORD,
            "ONESHOT_SIGNING_IDENTITY": FINGERPRINT,
        }
        self.addCleanup(self.temporary.cleanup)

    def execute(self, script, arguments, environment=None, stub=None):
        stub = stub or SecurityStub()
        output = io.StringIO()
        result = 0
        with mock.patch.dict(os.environ, environment if environment is not None else self.environment, clear=True), \
             mock.patch.object(sys, "argv", [script, *arguments]), \
             mock.patch("subprocess.run", side_effect=stub), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            try:
                exec(embedded_source(script), {"__name__": "__main__"})
            except SystemExit as error:
                result = error.code
        self.assertNotIn(FIXTURE_PASSWORD, output.getvalue())
        self.assertNotIn(self.environment["ONESHOT_SIGNING_CERTIFICATE_BASE64"], output.getvalue())
        return result, output.getvalue(), stub

    def import_identity(self, **options):
        return self.execute("import-signing-identity.sh", ["--directory", str(self.directory)], **options)

    def test_import_uses_fixed_identity_and_narrow_key_access_without_changing_trust(self):
        env_file = self.root / "github-env"
        env_file.touch()
        result, _, stub = self.execute("import-signing-identity.sh",
            ["--directory", str(self.directory), "--github-env", str(env_file)])
        self.assertEqual(result, 0)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.directory / "identity.p12").exists())
        state = json.loads((self.directory / "signing-environment.json").read_text())
        self.assertEqual(state["ONESHOT_SIGNING_IDENTITY"], FINGERPRINT)
        self.assertEqual(state["ONESHOT_SIGNING_KEYCHAIN"], str(self.directory / "identity.keychain-db"))
        self.assertIn("ONESHOT_SIGNING_IDENTITY=" + FINGERPRINT, env_file.read_text())
        commands = [call[1] for call in stub.calls]
        self.assertEqual(commands, ["create-keychain", "list-keychains", "list-keychains", "set-keychain-settings",
                                    "unlock-keychain", "import", "set-key-partition-list", "find-identity", "find-identity"])
        self.assertEqual(stub.entries, ["/fixture/login.keychain-db", "/fixture/another keychain-db",
                                       str(self.directory / "identity.keychain-db")])
        imported = next(call for call in stub.calls if call[1] == "import")
        self.assertNotIn("-A", imported)
        trusted_apps = [imported[index + 1] for index, part in enumerate(imported[:-1]) if part == "-T"]
        self.assertEqual(trusted_apps, ["/usr/bin/codesign", "/usr/bin/security"])
        self.assertEqual(stub.calls[-1][-1], str(self.directory / "identity.keychain-db"))
        self.assertNotIn("-v", stub.calls[-2])
        self.assertIn("-v", stub.calls[-1])

    def test_untrusted_selected_identity_fails_before_exporting_environment_and_is_cleaned(self):
        for trusted_fingerprint in (None, "0" * 40):
            with self.subTest(trusted_fingerprint=trusted_fingerprint):
                env_file = self.root / "github-env"
                env_file.write_text("")
                result, output, stub = self.execute("import-signing-identity.sh",
                    ["--directory", str(self.directory), "--github-env", str(env_file)],
                    stub=SecurityStub(trusted_fingerprint=trusted_fingerprint))
                self.assertEqual(result, 1)
                self.assertIn("Apple identity is not valid/trusted for code signing; no trust settings changed", output)
                self.assertFalse(self.directory.exists())
                self.assertEqual(env_file.read_text(), "")
                self.assertIn(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning",
                               str(self.directory / "identity.keychain-db")], stub.calls)
                self.assertTrue(any(call[1] == "delete-keychain" for call in stub.calls))
                self.assertEqual(stub.entries, ["/fixture/login.keychain-db", "/fixture/another keychain-db"])

    def test_exact_name_input_is_resolved_to_a_sha1(self):
        environment = dict(self.environment, ONESHOT_SIGNING_IDENTITY="OneShot Test Identity")
        result, _, _ = self.import_identity(environment=environment)
        self.assertEqual(result, 0)
        values = json.loads((self.directory / "signing-environment.json").read_text())
        self.assertEqual(values["ONESHOT_SIGNING_IDENTITY"], FINGERPRINT)

    def test_missing_or_mismatched_identity_has_no_fallback(self):
        for selector in ("", "0" * 40):
            with self.subTest(selector=selector):
                environment = dict(self.environment, ONESHOT_SIGNING_IDENTITY=selector)
                result, _, stub = self.import_identity(environment=environment)
                self.assertEqual(result, 1)
                self.assertFalse(self.directory.exists())
                self.assertFalse(any(call[0].endswith("codesign") for call in stub.calls))
                if selector:
                    self.assertTrue(any(call[1] == "delete-keychain" for call in stub.calls))
                else:
                    self.assertEqual(stub.calls, [])

    def test_import_failure_hides_diagnostics_and_cleans_own_files(self):
        result, _, stub = self.import_identity(stub=SecurityStub(fail_import=True))
        self.assertEqual(result, 1)
        self.assertFalse(self.directory.exists())
        self.assertTrue(any(call[1] == "delete-keychain" for call in stub.calls))

    def test_import_refuses_existing_or_non_runner_directory_without_touching_it(self):
        self.directory.mkdir()
        unrelated = self.directory / "keep.txt"
        unrelated.write_text("keep")
        result, _, stub = self.import_identity()
        self.assertEqual(result, 1)
        self.assertEqual(unrelated.read_text(), "keep")
        self.assertEqual(stub.calls, [])
        outside = self.root.parent / "oneshot-signing-outside-fixture"
        result, _, stub = self.execute("import-signing-identity.sh", ["--directory", str(outside)])
        self.assertEqual(result, 1)
        self.assertFalse(outside.exists())
        self.assertEqual(stub.calls, [])

    def test_invalid_base64_fails_before_creating_a_keychain(self):
        environment = dict(self.environment, ONESHOT_SIGNING_CERTIFICATE_BASE64="not valid base64!")
        result, _, stub = self.import_identity(environment=environment)
        self.assertEqual(result, 1)
        self.assertFalse(self.directory.exists())
        self.assertEqual(stub.calls, [])

    def test_self_signed_identity_does_not_require_global_trust(self):
        environment = dict(self.environment, ONESHOT_SIGNING_MODE="self-signed")
        stub = SecurityStub(trusted_fingerprint=None)
        result, _, _ = self.import_identity(environment=environment, stub=stub)
        self.assertEqual(result, 0)
        self.assertFalse(any(call[1] == "find-identity" and "-v" in call for call in stub.calls))
        self.assertIn(str(self.directory / "identity.keychain-db"), stub.entries)

    def test_failed_import_removes_only_own_lookup_entry_and_keeps_new_entries(self):
        stub = SecurityStub(fail_import=True, delete_addition="/fixture/concurrent.keychain-db")
        result, _, _ = self.import_identity(stub=stub)
        self.assertEqual(result, 1)
        self.assertFalse(self.directory.exists())
        self.assertEqual(stub.entries, ["/fixture/login.keychain-db", "/fixture/another keychain-db",
                                       "/fixture/concurrent.keychain-db"])

    def test_cleanup_deletes_only_marked_keychain_and_is_idempotent(self):
        stub = SecurityStub(delete_addition="/fixture/concurrent.keychain-db")
        result, _, _ = self.import_identity(stub=stub)
        self.assertEqual(result, 0)
        result, _, _ = self.execute("cleanup-signing-identity.sh", ["--directory", str(self.directory)], stub=stub)
        self.assertEqual(result, 0)
        self.assertFalse(self.directory.exists())
        self.assertEqual(stub.entries, ["/fixture/login.keychain-db", "/fixture/another keychain-db",
                                       "/fixture/concurrent.keychain-db"])
        before = len(stub.calls)
        result, _, _ = self.execute("cleanup-signing-identity.sh", ["--directory", str(self.directory)], stub=stub)
        self.assertEqual(result, 0)
        self.assertEqual(len(stub.calls), before)

    def test_cleanup_delete_failure_still_removes_own_lookup_and_preserves_marker(self):
        stub = SecurityStub(delete_addition="/fixture/concurrent.keychain-db")
        self.assertEqual(self.import_identity(stub=stub)[0], 0)
        stub.fail_delete = True
        result, output, _ = self.execute("cleanup-signing-identity.sh", ["--directory", str(self.directory)], stub=stub)
        self.assertEqual(result, 1)
        self.assertIn("lookup entry was removed", output)
        self.assertTrue((self.directory / ".oneshot-signing-state.json").exists())
        self.assertTrue((self.directory / "identity.keychain-db").exists())
        self.assertEqual(stub.entries, ["/fixture/login.keychain-db", "/fixture/another keychain-db",
                                       "/fixture/concurrent.keychain-db"])
        stub.fail_delete = False
        self.assertEqual(self.execute("cleanup-signing-identity.sh", ["--directory", str(self.directory)], stub=stub)[0], 0)
        self.assertFalse(self.directory.exists())

    def test_failed_import_delete_failure_still_removes_own_lookup(self):
        stub = SecurityStub(fail_import=True, delete_addition="/fixture/concurrent.keychain-db")
        stub.fail_delete = True
        result, _, _ = self.import_identity(stub=stub)
        self.assertEqual(result, 1)
        self.assertTrue((self.directory / ".oneshot-signing-state.json").exists())
        self.assertFalse((self.directory / "identity.p12").exists())
        self.assertNotIn(str(self.directory / "identity.keychain-db"), stub.entries)
        self.assertIn("/fixture/concurrent.keychain-db", stub.entries)

    def test_cleanup_lookup_read_or_write_failure_retains_marker_for_retry(self):
        for failure in ("fail_list_read", "fail_list_write"):
            with self.subTest(failure=failure):
                stub = SecurityStub()
                self.assertEqual(self.import_identity(stub=stub)[0], 0)
                setattr(stub, failure, True)
                result, _, _ = self.execute("cleanup-signing-identity.sh", ["--directory", str(self.directory)], stub=stub)
                self.assertEqual(result, 1)
                self.assertTrue((self.directory / ".oneshot-signing-state.json").exists())
                setattr(stub, failure, False)
                self.assertEqual(self.execute("cleanup-signing-identity.sh", ["--directory", str(self.directory)], stub=stub)[0], 0)
                self.assertFalse(self.directory.exists())

    def test_cleanup_refuses_unmarked_linked_or_forged_directories(self):
        self.directory.mkdir(mode=0o700)
        unrelated = self.directory / "keep.txt"
        unrelated.write_text("keep")
        result, _, stub = self.execute("cleanup-signing-identity.sh", ["--directory", str(self.directory)])
        self.assertEqual(result, 1)
        self.assertEqual(stub.calls, [])
        self.assertEqual(unrelated.read_text(), "keep")
        marker = {"schemaVersion": 1, "ownerUID": os.getuid(), "directory": str(self.directory),
                  "keychain": str(self.root / "unrelated.keychain-db")}
        (self.directory / ".oneshot-signing-state.json").write_text(json.dumps(marker))
        result, _, stub = self.execute("cleanup-signing-identity.sh", ["--directory", str(self.directory)])
        self.assertEqual(result, 1)
        self.assertEqual(stub.calls, [])
        self.assertTrue(unrelated.exists())
        linked = self.root / "oneshot-signing-linked"
        linked.symlink_to(self.directory, target_is_directory=True)
        result, _, stub = self.execute("cleanup-signing-identity.sh", ["--directory", str(linked)])
        self.assertEqual(result, 1)
        self.assertEqual(stub.calls, [])
        self.assertTrue(unrelated.exists())

    def test_cleanup_refuses_a_directory_outside_runner_temp(self):
        outside = self.root.parent / "oneshot-signing-outside-fixture"
        result, _, stub = self.execute("cleanup-signing-identity.sh", ["--directory", str(outside)])
        self.assertEqual(result, 1)
        self.assertEqual(stub.calls, [])


if __name__ == "__main__":
    unittest.main()
