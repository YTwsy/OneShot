#!/usr/bin/env python3
"""Exercise signature evidence, pinned identity and bidirectional upgrade checks."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


module_path = Path(__file__).resolve().parents[1] / "packaging/signing.py"
spec = importlib.util.spec_from_file_location("oneshot_signing", module_path)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
TEAM = "ABCDE12345"
LEAF = b"test-public-certificate-DER"


def create_app(root, name="OneShot.app"):
    app = root / name
    capture = app / "Contents/Helpers/OneShot Capture.app"
    for bundle, identifier, executable in (
        (app, signing.COMPONENTS[0][2], "oneshot-editor"),
        (capture, signing.COMPONENTS[1][2], "oneshot"),
    ):
        (bundle / "Contents/MacOS").mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": executable}))
        binary = bundle / "Contents/MacOS" / executable
        binary.write_bytes(b"test executable")
        binary.chmod(0o755)
    mcp = app / signing.COMPONENTS[2][1]
    mcp.write_bytes(b"test mcp executable")
    mcp.chmod(0o755)
    return app


class SigningTools:
    """A codesign/openssl subprocess fixture, including extracted public files."""

    def __init__(self, app, mode="ad-hoc", generation=1):
        self.calls = []
        self.entries = {}
        self.subject = "subject=CN=OneShot Local Signing"
        self.issuer = "issuer=CN=OneShot Local Signing"
        self.bad_self_signature = False
        self.reject_apple_chain = False
        self.add(app, mode, generation)

    def add(self, app, mode="ad-hoc", generation=1):
        for index, (role, relative, identifier) in enumerate(signing.COMPONENTS, 1):
            path = app / relative if relative else app
            cdhash = hashlib.sha1((role + str(generation)).encode()).hexdigest()
            leaf_hash = hashlib.sha1(LEAF).hexdigest()
            requirement = ('cdhash H"' + cdhash + '"' if mode == "ad-hoc" else
                           'identifier "' + identifier + '" and certificate leaf = H"' + leaf_hash + '"')
            team = TEAM if mode in ("apple-development", "developer-id") else None
            authority = {"self-signed": "OneShot Local Signing",
                         "apple-development": "Apple Development: Example (ABCDE12345)",
                         "developer-id": "Developer ID Application: Example (ABCDE12345)"}.get(mode)
            self.entries[str(path)] = {"role": role, "identifier": identifier, "cdhash": cdhash,
                                       "team": team, "authority": authority,
                                       "requirement": requirement, "leaf": LEAF,
                                       "mode": mode, "index": index}

    @staticmethod
    def signature(entry):
        certificate = entry["mode"] != "ad-hoc"
        return ("Identifier=" + entry["identifier"] + "\n"
                "CodeDirectory v=20500 size=400 flags=" + ("0x10000(runtime)" if certificate else "0x10002(adhoc,runtime)") + " hashes=4\n"
                "CDHash=" + entry["cdhash"] + "\n" +
                ("Signature size=4200\nAuthority=" + entry["authority"] + "\n" if certificate else "Signature=adhoc\n") +
                "TeamIdentifier=" + (entry["team"] or "not set") + "\n")

    def __call__(self, arguments, **options):
        self.calls.append(arguments)
        self.assert_safe_options(options)
        result = lambda stdout="", stderr="", code=0: subprocess.CompletedProcess(arguments, code, stdout, stderr)
        if arguments[0] == signing.CODESIGN:
            entry = self.entries[arguments[-1]]
            extraction = [argument for argument in arguments if argument.startswith("--extract-certificates=")]
            if extraction:
                prefix = extraction[0].split("=", 1)[1]
                Path(prefix + "0").write_bytes(entry["leaf"])
                return result()
            if "--verbose=4" in arguments:
                # Both streams are deliberately used, with no newline separating
                # stdout's last field from stderr's first field.
                return result("Executable=" + arguments[-1], self.signature(entry))
            if "--requirements" in arguments:
                return result(stderr=("# " if entry["mode"] == "ad-hoc" else "") +
                              "designated => " + entry["requirement"] + "\n")
            if "-R" in arguments:
                requirement = arguments[arguments.index("-R") + 1]
                if not requirement.startswith("="):
                    raise AssertionError("Requirements must be passed as literal expressions")
                expression = requirement[1:]
                if "anchor apple generic" in expression:
                    return result(code=1 if self.reject_apple_chain else 0)
                if expression.startswith("cdhash ") and expression != entry["requirement"]:
                    return result(code=1)
                return result()
            return result()
        if arguments[0] == signing.OPENSSL:
            if arguments[1] == "verify":
                return result(code=1 if self.bad_self_signature else 0)
            if "-subject" in arguments:
                return result(self.subject + "\n")
            if "-issuer" in arguments:
                return result(self.issuer + "\n")
            if "-out" in arguments:
                Path(arguments[arguments.index("-out") + 1]).write_text("test public PEM")
            return result()
        raise AssertionError("Unexpected signing tool")

    @staticmethod
    def assert_safe_options(options):
        if options.get("shell") or options.get("timeout") != 30 or not options.get("text"):
            raise AssertionError("Signing tools must use bounded literal subprocess arguments")


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = create_app(self.root)

    def verify(self, fake, mode="ad-hoc", expected_team=None):
        with mock.patch.object(signing.subprocess, "run", side_effect=fake):
            return signing.verify_app(self.app, mode, expected_team)

    def test_ad_hoc_verifies_each_component_and_preserves_only_public_identity(self):
        fake = SigningTools(self.app)
        report = self.verify(fake)
        self.assertEqual(set(report), {"schemaVersion", "signingMode", "components"})
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual([item["role"] for item in report["components"]], ["application", "capture", "mcp"])
        for item in report["components"]:
            self.assertEqual(set(item), {"role", "identifier", "cdhash", "designatedRequirement",
                                         "teamIdentifier", "certificateSHA256", "signatureKind"})
            self.assertEqual(item["signatureKind"], "ad-hoc")
            self.assertIsNone(item["certificateSHA256"])
            self.assertIsNone(item["teamIdentifier"])
        self.assertIn([signing.CODESIGN, "--verify", "--deep", "--strict", str(self.app)], fake.calls)
        self.assertEqual(len([call for call in fake.calls if "-R" in call]), 3)
        self.assertFalse(any(call[0] == signing.OPENSSL for call in fake.calls))

    def test_rejects_ambiguous_or_missing_signature_evidence(self):
        valid = SigningTools.signature(next(iter(SigningTools(self.app).entries.values())))
        invalid = [valid.replace("CDHash=", "CDHash=" + "a" * 24),
                   valid.replace("CDHash=", "CDHash=invalid"),
                   valid + "Identifier=other.app\n", valid.replace("TeamIdentifier=not set", "TeamIdentifier=" + TEAM),
                   valid.replace("0x10002", "0x2"), valid.replace("Signature=adhoc\n", ""),
                   valid.replace("TeamIdentifier=not set\n", ""), valid + "Authority=Fake CA\n",
                   valid + "Signature size=4000\n", valid + "Signature=adhoc\n"]
        for output in invalid:
            with self.subTest(output=output), self.assertRaises(signing.SigningError):
                signing.parse_signature(output)

    def test_requirements_accept_implicit_ad_hoc_but_reject_missing_or_duplicates(self):
        self.assertEqual(signing.parse_requirement('# designated => cdhash H"' + "a" * 40 + '"\n'),
                         'cdhash H"' + "a" * 40 + '"')
        for output in ("", "designated => \n", "designated => true\ndesignated => true\n", "designated => a\x00b"):
            with self.subTest(output=output), self.assertRaises(signing.SigningError):
                signing.parse_requirement(output)

    def test_modes_cannot_disguise_ad_hoc_or_certificate_signatures(self):
        for actual, requested in (("ad-hoc", "self-signed"), ("self-signed", "ad-hoc"), ("ad-hoc", "developer-id")):
            with self.subTest(actual=actual, requested=requested), self.assertRaises(signing.SigningError):
                self.verify(SigningTools(self.app, actual), requested)
        with self.assertRaises(signing.SigningError):
            signing.verify_app(self.app, "unsigned")

    def test_self_signed_identity_requires_real_self_signature_and_exact_leaf_pin(self):
        fake = SigningTools(self.app, "self-signed")
        report = self.verify(fake, "self-signed")
        for item in report["components"]:
            self.assertEqual(item["certificateSHA256"], hashlib.sha256(LEAF).hexdigest())
            self.assertIsNone(item["teamIdentifier"])
        self.assertEqual(len([call for call in fake.calls if "-check_ss_sig" in call]), 3)
        for mutate in (lambda f: setattr(f, "issuer", "issuer=CN=Some Other CA"),
                       lambda f: (setattr(f, "subject", "missing"), setattr(f, "issuer", "missing")),
                       lambda f: setattr(f, "bad_self_signature", True),
                       lambda f: f.entries[str(self.app)].update(requirement="true"),
                       lambda f: f.entries[str(self.app)].update(team=TEAM),
                       lambda f: f.entries[str(self.app)].update(requirement='identifier "wrong.app" and certificate leaf = H"' + hashlib.sha1(LEAF).hexdigest() + '"'),
                       lambda f: f.entries[str(self.app)].update(requirement='identifier "io.github.ytwsy.oneshot" and certificate leaf = H"' + "f" * 40 + '"')):
            rejected = SigningTools(self.app, "self-signed")
            mutate(rejected)
            with self.subTest(entries=rejected.entries), self.assertRaises(signing.SigningError):
                self.verify(rejected, "self-signed")

    def test_rejects_code_bound_or_mixed_leaf_certificate_releases(self):
        fake = SigningTools(self.app, "self-signed")
        fake.entries[str(self.app)]["requirement"] = 'cdhash H"' + "a" * 40 + '"'
        with self.assertRaises(signing.SigningError):
            self.verify(fake, "self-signed")
        fake = SigningTools(self.app, "developer-id")
        fake.entries[str(self.app / signing.COMPONENTS[2][1])]["leaf"] = b"different leaf certificate"
        with self.assertRaisesRegex(signing.SigningError, "same leaf"):
            self.verify(fake, "developer-id")
        fake = SigningTools(self.app, "developer-id")
        fake.entries[str(self.app)]["team"] = "OTHER12345"
        with self.assertRaisesRegex(signing.SigningError, "same signing team"):
            self.verify(fake, "developer-id")

    def test_ad_hoc_cannot_claim_a_broad_custom_designated_requirement(self):
        fake = SigningTools(self.app)
        fake.entries[str(self.app)]["requirement"] = "true"
        with self.assertRaisesRegex(signing.SigningError, "actual code hash"):
            self.verify(fake)

    def test_developer_id_checks_real_apple_chain_oid_and_expected_team(self):
        fake = SigningTools(self.app, "developer-id")
        self.verify(fake, "developer-id", TEAM)
        channel_checks = [call[call.index("-R") + 1] for call in fake.calls if "-R" in call and "anchor apple generic" in call[call.index("-R") + 1]]
        self.assertEqual(len(channel_checks), 3)
        for check in channel_checks:
            self.assertIn('certificate leaf[subject.OU] = "' + TEAM + '"', check)
            self.assertIn("certificate 1[field.1.2.840.113635.100.6.2.6] exists", check)
            self.assertIn("certificate leaf[field.1.2.840.113635.100.6.1.13] exists", check)
        fake.reject_apple_chain = True
        with self.assertRaises(signing.SigningError):
            self.verify(fake, "developer-id", TEAM)
        with self.assertRaises(signing.SigningError):
            self.verify(SigningTools(self.app, "developer-id"), "developer-id", "OTHER12345")

    def test_apple_development_checks_wwdr_chain_and_not_just_authority_label(self):
        fake = SigningTools(self.app, "apple-development")
        self.verify(fake, "apple-development", TEAM)
        self.assertTrue(any("1.2.840.113635.100.6.2.1" in " ".join(call) for call in fake.calls))
        fake.reject_apple_chain = True
        with self.assertRaises(signing.SigningError):
            self.verify(fake, "apple-development", TEAM)
        fake = SigningTools(self.app, "developer-id")
        with self.assertRaisesRegex(signing.SigningError, "Apple Development"):
            self.verify(fake, "apple-development")

    def test_expected_team_rejects_invalid_or_inapplicable_input_before_tool_execution(self):
        for mode, team in (("ad-hoc", TEAM), ("self-signed", TEAM), ("developer-id", "too-short"), ("developer-id", "abcde12345")):
            with self.subTest(mode=mode, team=team), mock.patch.object(signing.subprocess, "run") as run:
                with self.assertRaises(signing.SigningError):
                    signing.verify_app(self.app, mode, team)
                run.assert_not_called()

    def test_rejects_incorrect_identifiers_or_sealed_bundle_layout(self):
        fake = SigningTools(self.app)
        fake.entries[str(self.app)]["identifier"] = "another.app"
        with self.assertRaises(signing.SigningError):
            self.verify(fake)
        with self.assertRaises(signing.SigningError):
            signing.component_paths(Path("OneShot.app"))
        with self.assertRaises(signing.SigningError):
            signing.component_paths(self.root / "missing.app")
        binary = self.app / signing.COMPONENTS[2][1]
        binary.unlink()
        binary.symlink_to("/bin/sh")
        with self.assertRaises(signing.SigningError):
            signing.component_paths(self.app)

    def test_compare_checks_both_directions_and_ad_hoc_generations_do_not_match(self):
        candidate = create_app(self.root, "Candidate.app")
        fake = SigningTools(self.app)
        fake.add(candidate, generation=2)
        with mock.patch.object(signing.subprocess, "run", side_effect=fake):
            report = signing.compare_apps(self.app, candidate)
        self.assertFalse(report["identityCompatible"])
        self.assertTrue(all(not item["candidateSatisfiesPrevious"] and not item["previousSatisfiesCandidate"] for item in report["components"]))
        self.assertEqual(len([call for call in fake.calls if "-R" in call]), 12)
        self.assertNotIn("permissionContinuity", report)

    def test_compare_stable_leaf_identity_passes_with_different_code_hashes(self):
        candidate = create_app(self.root, "Candidate.app")
        fake = SigningTools(self.app, "self-signed")
        fake.add(candidate, "self-signed", generation=2)
        with mock.patch.object(signing.subprocess, "run", side_effect=fake):
            self.assertTrue(signing.compare_apps(self.app, candidate)["identityCompatible"])

    def test_compare_requires_both_directions_even_when_one_direction_passes(self):
        candidate = create_app(self.root, "Candidate.app")
        fake = SigningTools(self.app, "self-signed")
        fake.add(candidate, "self-signed", generation=2)
        fake.entries[str(candidate)]["requirement"] = "true"

        def run(arguments, **options):
            process = fake(arguments, **options)
            if ("-R" in arguments and arguments[-1] == str(candidate) and
                    arguments[arguments.index("-R") + 1] == "=" + fake.entries[str(self.app)]["requirement"]):
                process.returncode = 1
            return process

        with mock.patch.object(signing.subprocess, "run", side_effect=run):
            report = signing.compare_apps(self.app, candidate)
        self.assertFalse(report["identityCompatible"])
        self.assertFalse(report["components"][0]["candidateSatisfiesPrevious"])
        self.assertTrue(report["components"][0]["previousSatisfiesCandidate"])

    def test_reports_cannot_change_signed_bundles_or_overwrite_an_existing_file(self):
        with self.assertRaises(signing.SigningError):
            signing._output({}, self.app / "report.json", [self.app])
        destination = self.root / "signing-report.json"
        signing._output({"public": True}, destination, [self.app])
        self.assertEqual(json.loads(destination.read_text()), {"public": True})
        with self.assertRaises(FileExistsError):
            signing._output({}, destination, [self.app])

    def test_tool_errors_and_timeouts_fail_closed(self):
        for side_effect in (OSError("tool missing"), subprocess.TimeoutExpired("codesign", 30)):
            with self.subTest(error=side_effect), mock.patch.object(signing.subprocess, "run", side_effect=side_effect):
                with self.assertRaises(signing.SigningError):
                    signing.verify_app(self.app, "ad-hoc")
        with mock.patch.object(signing.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "invalid signature")):
            with self.assertRaisesRegex(signing.SigningError, "invalid signature"):
                signing.verify_app(self.app, "ad-hoc")

    def test_cli_returns_nonzero_for_incompatible_identity_and_emits_valid_json(self):
        candidate = create_app(self.root, "Candidate.app")
        fake = SigningTools(self.app)
        fake.add(candidate, generation=2)
        output = io.StringIO()
        with mock.patch.object(signing.subprocess, "run", side_effect=fake), contextlib.redirect_stdout(output):
            code = signing.main(["compare", "--previous-app", str(self.app), "--candidate-app", str(candidate)])
        self.assertEqual(code, 1)
        self.assertFalse(json.loads(output.getvalue())["identityCompatible"])


if __name__ == "__main__":
    unittest.main()
