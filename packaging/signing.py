#!/usr/bin/env python3
"""Inspect release code identity and compare upgrades without changing trust or TCC.

The reports describe signatures and designated requirements. They never assert
that a user's privacy permissions have been granted or inherited.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile


MODES = ("ad-hoc", "self-signed", "apple-development", "developer-id")
COMPONENTS = (
    ("application", "", "io.github.ytwsy.oneshot"),
    ("capture", "Contents/Helpers/OneShot Capture.app", "io.github.ytwsy.oneshot.capture-probe"),
    ("mcp", "Contents/Helpers/oneshot-mcp", "io.github.ytwsy.oneshot.mcp"),
)
CODESIGN = "/usr/bin/codesign"
OPENSSL = "/usr/bin/openssl"


class SigningError(ValueError):
    pass


def _run(arguments, allow_failure=False):
    try:
        process = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, timeout=30,
                                 env=dict(os.environ, LC_ALL="C", LANG="C"))
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SigningError("Unable to run signing validation: " + str(error)) from error
    if process.returncode and not allow_failure:
        diagnostic = (process.stderr or process.stdout).strip()[:2048]
        raise SigningError("Signing validation failed: " + diagnostic)
    return process


def _regular_file(path):
    try:
        if not stat.S_ISREG(path.lstat().st_mode):
            raise SigningError("Expected a regular, non-linked file: " + str(path))
    except OSError as error:
        raise SigningError("Missing signing input: " + str(path)) from error


def _bundle(path):
    if not path.is_absolute() or path.suffix != ".app" or path.is_symlink() or not path.is_dir():
        raise SigningError("Expected an absolute path to a regular .app bundle")
    info = path / "Contents/Info.plist"
    _regular_file(info)
    if info.stat().st_size > 1_048_576:
        raise SigningError("Bundle metadata exceeds the supported size")
    try:
        with info.open("rb") as source:
            metadata = plistlib.load(source)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SigningError("Invalid bundle metadata: " + str(path)) from error
    if not isinstance(metadata, dict):
        raise SigningError("Invalid bundle metadata object")
    return metadata


def component_paths(app):
    app = Path(app)
    main = _bundle(app)
    capture = app / COMPONENTS[1][1]
    capture_metadata = _bundle(capture)
    # Reject linked component directories as well as linked executable files.
    # Otherwise the verification target could silently escape this app bundle.
    for relative in ("Contents", "Contents/MacOS", "Contents/Helpers",
                     "Contents/Helpers/OneShot Capture.app/Contents",
                     "Contents/Helpers/OneShot Capture.app/Contents/MacOS"):
        directory = app / relative
        if directory.is_symlink() or not directory.is_dir():
            raise SigningError("Expected a regular component directory: " + str(directory))
    for metadata, identifier, executable in (
        (main, COMPONENTS[0][2], "oneshot-editor"),
        (capture_metadata, COMPONENTS[1][2], "oneshot"),
    ):
        if metadata.get("CFBundleIdentifier") != identifier or metadata.get("CFBundleExecutable") != executable:
            raise SigningError("The bundle identifier or executable does not match OneShot's component layout")
    for path in (app / "Contents/MacOS/oneshot-editor", capture / "Contents/MacOS/oneshot",
                 app / COMPONENTS[2][1]):
        _regular_file(path)
        if not os.access(path, os.X_OK):
            raise SigningError("Component is not executable: " + str(path))
    return [(role, app / relative if relative else app, identifier)
            for role, relative, identifier in COMPONENTS]


def _one_field(output, name):
    values = [line[len(name) + 1:] for line in output.splitlines() if line.startswith(name + "=")]
    if len(values) != 1 or not values[0].strip():
        raise SigningError("Signing output must contain exactly one " + name)
    return values[0]


def parse_signature(output):
    identifier = _one_field(output, "Identifier")
    cdhash = _one_field(output, "CDHash").lower()
    if not re.fullmatch(r"[0-9a-f]{40}", cdhash):
        raise SigningError("Signing output has an invalid CDHash")
    team = _one_field(output, "TeamIdentifier")
    if team == "not set":
        team = None
    elif not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SigningError("Signing output has an invalid TeamIdentifier")
    flags = re.findall(r"^CodeDirectory .*?\bflags=0x([0-9a-fA-F]+)", output, re.MULTILINE)
    if len(flags) != 1 or not int(flags[0], 16) & 0x10000:
        raise SigningError("Every release component must enable hardened runtime")
    signature_lines = [line for line in output.splitlines() if line.startswith("Signature")]
    ad_hoc = signature_lines == ["Signature=adhoc"]
    if ad_hoc != bool(int(flags[0], 16) & 0x2):
        raise SigningError("Code directory flags disagree with the signature kind")
    if not ad_hoc and (len(signature_lines) != 1 or not re.fullmatch(r"Signature size=[1-9][0-9]*", signature_lines[0])):
        raise SigningError("No certificate signature was reported")
    authorities = [line[len("Authority="):] for line in output.splitlines() if line.startswith("Authority=")]
    if ad_hoc and (authorities or team is not None):
        raise SigningError("An ad-hoc component cannot contain certificate authority or team identity")
    if not ad_hoc and (not authorities or any(not entry.strip() for entry in authorities)):
        raise SigningError("A certificate-signed component must report an authority")
    return {"identifier": identifier, "cdhash": cdhash, "teamIdentifier": team,
            "signatureKind": "ad-hoc" if ad_hoc else "certificate"}, authorities


def parse_requirement(output):
    requirements = []
    for line in output.splitlines():
        line = line.lstrip("# ")
        if line.startswith("designated => "):
            requirements.append(line[len("designated => "):].strip())
    if len(requirements) != 1 or not requirements[0] or "\x00" in requirements[0]:
        raise SigningError("Signing output must contain one nonempty designated requirement")
    return requirements[0]


def _check_requirement(path, requirement, allow_failure=False):
    return _run([CODESIGN, "--verify", "--strict", "-R", "=" + requirement, str(path)], allow_failure)


def _certificate(path, require_self_signed=False):
    # Extraction exposes only public certificates. No private key is extracted,
    # and no keychain or machine trust setting is modified here.
    with tempfile.TemporaryDirectory(prefix="oneshot-cert-check-") as temporary:
        prefix = Path(temporary) / "certificate"
        # The prefix is an optional argument: codesign requires the equals form
        # or it interprets the prefix as another code object to inspect.
        _run([CODESIGN, "--display", "--extract-certificates=" + str(prefix), str(path)])
        leaf = Path(str(prefix) + "0")
        _regular_file(leaf)
        data = leaf.read_bytes()
        if not data or len(data) > 1_048_576:
            raise SigningError("Invalid extracted leaf certificate")
        # Validate that the extracted file is X.509, independently of codesign's
        # human-readable Authority lines.
        _run([OPENSSL, "x509", "-inform", "DER", "-in", str(leaf), "-noout"])
        if require_self_signed:
            subject = _run([OPENSSL, "x509", "-inform", "DER", "-in", str(leaf),
                            "-noout", "-subject", "-nameopt", "RFC2253"]).stdout.strip()
            issuer = _run([OPENSSL, "x509", "-inform", "DER", "-in", str(leaf),
                           "-noout", "-issuer", "-nameopt", "RFC2253"]).stdout.strip()
            if not re.match(r"^subject\s*=\s*", subject) or not re.match(r"^issuer\s*=\s*", issuer):
                raise SigningError("Missing certificate subject or issuer evidence")
            subject = re.sub(r"^subject\s*=\s*", "", subject)
            issuer = re.sub(r"^issuer\s*=\s*", "", issuer)
            if not subject or subject != issuer:
                raise SigningError("self-signed mode requires a genuinely self-issued leaf certificate")
            pem = Path(temporary) / "certificate.pem"
            _run([OPENSSL, "x509", "-inform", "DER", "-in", str(leaf), "-out", str(pem)])
            # Explicitly check the root self-signature instead of treating every
            # non-Apple certificate as self-signed.
            _run([OPENSSL, "verify", "-CAfile", str(pem), "-check_ss_sig", str(pem)])
        fingerprint = hashlib.sha256(data).hexdigest()
        leaf_sha1 = hashlib.sha1(data).hexdigest()
        _check_requirement(path, 'certificate leaf = H"' + leaf_sha1 + '"')
        return fingerprint, leaf_sha1


def _self_signed_requirement(requirement, identifier, leaf_sha1):
    # A certificate alone does not make a broad custom DR safe for upgrades.
    # Support the two orders of the explicitly pinned DR emitted by the builder.
    identity = 'identifier "' + identifier + '"'
    certificate = 'certificate leaf = H"' + leaf_sha1 + '"'
    if requirement not in (identity + " and " + certificate, certificate + " and " + identity):
        raise SigningError("A self-signed designated requirement must pin its identifier and actual leaf certificate")


def _inspect(app, mode=None, expected_team_id=None):
    paths = component_paths(app)
    _run([CODESIGN, "--verify", "--deep", "--strict", str(Path(app))])
    result = []
    for role, path, identifier in paths:
        _run([CODESIGN, "--verify", "--strict", str(path)])
        signature = _run([CODESIGN, "--display", "--verbose=4", str(path)])
        record, authorities = parse_signature(signature.stdout + "\n" + signature.stderr)
        if record["identifier"] != identifier:
            raise SigningError("Unexpected signing identifier for " + role)
        displayed = _run([CODESIGN, "--display", "--requirements", "-", str(path)])
        requirement = parse_requirement(displayed.stdout + "\n" + displayed.stderr)
        _check_requirement(path, requirement)
        record["role"] = role
        record["designatedRequirement"] = requirement
        record["certificateSHA256"] = None
        is_ad_hoc = record["signatureKind"] == "ad-hoc"
        if (mode == "ad-hoc" and not is_ad_hoc) or (mode not in (None, "ad-hoc") and is_ad_hoc):
            raise SigningError("The actual signature kind does not match the selected mode")
        if is_ad_hoc and requirement != 'cdhash H"' + record["cdhash"] + '"':
            raise SigningError("An ad-hoc designated requirement must match its actual code hash")
        if not is_ad_hoc:
            if mode is not None and re.search(r"\bcdhash\b", requirement):
                raise SigningError("A stable certificate-signed release cannot use a code-hash-bound requirement")
            fingerprint, leaf_sha1 = _certificate(path, require_self_signed=mode == "self-signed")
            record["certificateSHA256"] = fingerprint
            if mode == "self-signed":
                _self_signed_requirement(requirement, identifier, leaf_sha1)
        if mode == "self-signed" and record["teamIdentifier"] is not None:
            raise SigningError("A self-signed component must not claim an Apple TeamIdentifier")
        if mode in ("apple-development", "developer-id"):
            team = record["teamIdentifier"]
            if team is None or expected_team_id is not None and team != expected_team_id:
                raise SigningError("The signing team is missing or does not match the expected team")
            base = 'anchor apple generic and certificate leaf[subject.OU] = "' + team + '"'
            if mode == "developer-id":
                channel = (" and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                           " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
            else:
                # The name is only a channel discriminator after verifying the
                # real Apple WWDR chain and team, never a substitute for it.
                if not authorities[0].startswith("Apple Development: "):
                    raise SigningError("Expected an Apple Development leaf certificate")
                channel = " and certificate 1[field.1.2.840.113635.100.6.2.1] exists"
            _check_requirement(path, base + channel)
        result.append(record)
    return result, paths


def verify_app(app, signing_mode, expected_team_id=None):
    if signing_mode not in MODES:
        raise SigningError("Unknown signing mode")
    if expected_team_id is not None:
        if signing_mode not in ("apple-development", "developer-id") or not re.fullmatch(r"[A-Z0-9]{10}", expected_team_id):
            raise SigningError("An expected team ID is valid only for Apple certificate modes and must have 10 uppercase letters or digits")
    components, _ = _inspect(app, signing_mode, expected_team_id)
    if signing_mode != "ad-hoc":
        if len({entry["certificateSHA256"] for entry in components}) != 1:
            raise SigningError("All release components must use the same leaf signing certificate")
        if len({entry["teamIdentifier"] for entry in components}) != 1:
            raise SigningError("All release components must use the same signing team")
    return {"schemaVersion": 1, "signingMode": signing_mode, "components": components}


def compare_apps(previous_app, candidate_app):
    previous, previous_paths = _inspect(previous_app)
    candidate, candidate_paths = _inspect(candidate_app)
    comparisons = []
    for old, new, (_, old_path, _), (_, new_path, _) in zip(previous, candidate, previous_paths, candidate_paths):
        forward = _check_requirement(new_path, old["designatedRequirement"], allow_failure=True)
        reverse = _check_requirement(old_path, new["designatedRequirement"], allow_failure=True)
        comparisons.append({"role": old["role"], "identifier": old["identifier"],
                            "candidateSatisfiesPrevious": forward.returncode == 0,
                            "previousSatisfiesCandidate": reverse.returncode == 0,
                            "previousRequirement": old["designatedRequirement"],
                            "candidateRequirement": new["designatedRequirement"]})
    compatible = all(entry["candidateSatisfiesPrevious"] and entry["previousSatisfiesCandidate"] for entry in comparisons)
    return {"schemaVersion": 1, "identityCompatible": compatible, "components": comparisons,
            "interpretation": "Only code identity compatibility is checked. Privacy permission inheritance requires an actual upgrade and capture test on the user's Mac."}


def _output(report, path, protected_apps):
    if path is None:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return
    output = Path(path).absolute()
    for app in protected_apps:
        root = Path(app).resolve()
        if os.path.commonpath([str(output.resolve()), str(root)]) == str(root):
            raise SigningError("A signing report must be written outside the sealed application bundle")
    with output.open("x", encoding="utf-8") as destination:
        json.dump(report, destination, ensure_ascii=False, indent=2)
        destination.write("\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    verify = commands.add_parser("verify", help="Validate the actual signing mode and every nested component")
    verify.add_argument("--app", required=True, type=Path)
    verify.add_argument("--signing-mode", required=True, choices=MODES)
    verify.add_argument("--expected-team-id")
    verify.add_argument("--output", type=Path)
    compare = commands.add_parser("compare", help="Check both directions of designated-requirement compatibility")
    compare.add_argument("--previous-app", required=True, type=Path)
    compare.add_argument("--candidate-app", required=True, type=Path)
    compare.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "verify":
            report = verify_app(args.app, args.signing_mode, args.expected_team_id)
            apps = [args.app]
        else:
            report = compare_apps(args.previous_app, args.candidate_app)
            apps = [args.previous_app, args.candidate_app]
        _output(report, args.output, apps)
        return 0 if report.get("identityCompatible", True) else 1
    except (SigningError, OSError) as error:
        print("signing verification: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
