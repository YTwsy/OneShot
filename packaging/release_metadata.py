#!/usr/bin/env python3
"""Versioned metadata and public signing evidence for OneShot preview builds."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys


APP_ID = "io.github.ytwsy.oneshot"
CAPTURE_ID = APP_ID + ".capture-probe"
MCP_ID = APP_ID + ".mcp"
SIGNING_MODES = ("ad-hoc", "self-signed", "apple-development", "developer-id")
COMPONENT_IDENTIFIERS = {"application": APP_ID, "capture": CAPTURE_ID, "mcp": MCP_ID}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate(version: str, build_number: str, commit: str) -> str:
    core = r"(0|[1-9][0-9]*)"
    pattern = rf"{core}\.{core}\.{core}-(alpha|beta|rc)\.{core}"
    match = re.fullmatch(pattern, version)
    if not match or any(int(part) > 65535 for part in match.groups()[:3]):
        raise ValueError("version must be a numeric X.Y.Z followed by -alpha.N, -beta.N or -rc.N; no leading zeros")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", build_number):
        raise ValueError("build number must be a positive integer of at most 4 digits")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("source commit must be a full lowercase 40-character Git commit")
    return version.split("-", 1)[0]


def validate_signing_mode(signing_mode: str) -> str:
    if signing_mode not in SIGNING_MODES:
        raise ValueError("signing mode must be one of: " + ", ".join(SIGNING_MODES))
    return signing_mode


def validate_signing_report(report: dict, signing_mode: str) -> dict:
    """Accept only the public identity fields emitted by the signing verifier.

    This validates the report's structure, not the code signature itself. The
    build must run the signature verifier before passing its report here.
    """
    validate_signing_mode(signing_mode)
    allowed = {"schemaVersion", "signingMode", "components"}
    if not isinstance(report, dict) or set(report) != allowed:
        raise ValueError("signing report must contain only schemaVersion, signingMode and components")
    if type(report["schemaVersion"]) is not int or report["schemaVersion"] != 1:
        raise ValueError("unsupported signing report schema")
    if report["signingMode"] != signing_mode:
        raise ValueError("signing report mode does not match the requested mode")
    components = report["components"]
    if not isinstance(components, list) or len(components) != len(COMPONENT_IDENTIFIERS):
        raise ValueError("signing report must include application, capture and mcp")
    component_fields = {"role", "identifier", "cdhash", "designatedRequirement",
                        "teamIdentifier", "certificateSHA256", "signatureKind"}
    seen = set()
    fingerprints = set()
    teams = set()
    checked = []
    for component in components:
        if not isinstance(component, dict) or set(component) != component_fields:
            raise ValueError("signing component contains missing or unsupported fields")
        role = component["role"]
        if not isinstance(role, str) or role not in COMPONENT_IDENTIFIERS or role in seen:
            raise ValueError("signing report component role is invalid or duplicated")
        seen.add(role)
        if component["identifier"] != COMPONENT_IDENTIFIERS[role]:
            raise ValueError("signing report has an unexpected component identifier")
        cdhash = component["cdhash"]
        if not isinstance(cdhash, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", cdhash):
            raise ValueError("signing report has an invalid code hash")
        requirement = component["designatedRequirement"]
        if not isinstance(requirement, str) or not requirement.strip() or len(requirement.encode("utf-8")) > 16_384:
            raise ValueError("signing report has an invalid designated requirement")
        team = component["teamIdentifier"]
        if team is not None and (not isinstance(team, str) or not re.fullmatch(r"[A-Z0-9]{10}", team)):
            raise ValueError("signing report has an invalid team identifier")
        fingerprint = component["certificateSHA256"]
        if signing_mode == "ad-hoc":
            if component["signatureKind"] != "ad-hoc" or fingerprint is not None or team is not None:
                raise ValueError("ad-hoc signing report cannot declare a certificate or team")
        else:
            if component["signatureKind"] != "certificate" or not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", fingerprint):
                raise ValueError("certificate signing report requires a certificate SHA-256")
            if signing_mode in ("apple-development", "developer-id") and team is None:
                raise ValueError("Apple signing report requires a team identifier")
            fingerprints.add(fingerprint.lower())
            teams.add(team)
        checked.append({"role": role, "identifier": component["identifier"],
                        "cdhash": cdhash.lower(), "designatedRequirement": requirement,
                        "teamIdentifier": team,
                        "certificateSHA256": fingerprint.lower() if fingerprint else None,
                        "signatureKind": component["signatureKind"]})
    if signing_mode != "ad-hoc" and (len(fingerprints) != 1 or len(teams) != 1):
        raise ValueError("all release components must use the same signing identity")
    checked.sort(key=lambda item: list(COMPONENT_IDENTIFIERS).index(item["role"]))
    return {"schemaVersion": 1, "signingMode": signing_mode, "components": checked}


def bundle_metadata(version: str, build_number: str, commit: str, capture: bool = False,
                    signing_mode: str = "ad-hoc") -> dict:
    marketing = validate(version, build_number, commit)
    validate_signing_mode(signing_mode)
    name = "OneShot"
    result = {
        "CFBundleIdentifier": CAPTURE_ID if capture else APP_ID,
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundleExecutable": "oneshot" if capture else "oneshot-editor",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": build_number,
        "CFBundleShortVersionString": marketing,
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "CFBundleIconFile": "OneShot.icns",
        "OneShotReleaseTag": "v" + version,
        "OneShotSourceCommit": commit,
        "OneShotDistributionChannel": "prerelease",
        "OneShotSigningMode": signing_mode,
        "OneShotSigningStatus": signing_mode + "-unnotarized",
        "NSScreenCaptureUsageDescription": "OneShot captures only the application window you select, so you can annotate the screenshot and share its interface context with an Agent.",
    }
    if capture:
        result.update({
            "LSUIElement": True,
        })
    else:
        result["CFBundleDocumentTypes"] = [{
            "CFBundleTypeName": "OneShot Annotation Project",
            "CFBundleTypeExtensions": ["oneshot"],
            "CFBundleTypeRole": "Editor",
            "LSTypeIsPackage": True,
        }]
    return result


def write_bundle_metadata(app: Path, version: str, build_number: str, commit: str,
                          signing_mode: str = "ad-hoc") -> None:
    validate(version, build_number, commit)
    validate_signing_mode(signing_mode)
    for bundle, capture in [(app, False), (app / "Contents/Helpers/OneShot Capture.app", True)]:
        target = bundle / "Contents/Info.plist"
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as output:
            plistlib.dump(bundle_metadata(version, build_number, commit, capture, signing_mode), output, sort_keys=True)


def write_manifest(directory: Path, version: str, build_number: str, commit: str,
                   signing_mode: str = "ad-hoc", signing_report: dict = None) -> None:
    marketing = validate(version, build_number, commit)
    validate_signing_mode(signing_mode)
    if signing_report is None and signing_mode != "ad-hoc":
        raise ValueError("certificate-signed releases require a verified signing report")
    public_report = validate_signing_report(signing_report, signing_mode) if signing_report is not None else None
    files = []
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.name != "release-manifest.json":
            files.append({"file": path.name, "bytes": path.stat().st_size,
                          "sha256": sha256_file(path)})
    result = {
        "schemaVersion": 1, "product": "OneShot", "version": marketing,
        "releaseVersion": version, "tag": "v" + version, "buildNumber": build_number,
        "sourceCommit": commit, "architecture": "arm64", "minimumMacOS": "14.0",
        "prerelease": True, "signingMode": signing_mode,
        "adHocSigned": signing_mode == "ad-hoc", "developerIDSigned": signing_mode == "developer-id",
        "notarized": False, "automaticUpdates": False,
        "permissionContinuity": "not-verified",
        "bundleIdentifiers": {"application": APP_ID, "capture": CAPTURE_ID, "mcp": MCP_ID},
        "files": files,
    }
    if public_report is not None:
        result["signingReport"] = public_report
    with (directory / "release-manifest.json").open("x") as output:
        json.dump(result, output, indent=2, sort_keys=True)
        output.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "bundles", "manifest"])
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--path", type=Path)
    parser.add_argument("--signing-mode", choices=SIGNING_MODES, default="ad-hoc")
    parser.add_argument("--signing-report", type=Path,
                        help="Public identity evidence JSON produced by the signature verifier; manifest only")
    args = parser.parse_args()
    try:
        marketing = validate(args.version, args.build_number, args.commit)
        validate_signing_mode(args.signing_mode)
        if args.signing_report is not None and args.command != "manifest":
            parser.error("--signing-report is only supported by manifest")
        if args.command == "validate":
            print(marketing)
        elif args.path is None:
            parser.error("--path is required for this command")
        elif args.command == "bundles":
            write_bundle_metadata(args.path, args.version, args.build_number, args.commit, args.signing_mode)
        else:
            report = None
            if args.signing_report is not None:
                if args.signing_report.stat().st_size > 256 * 1_024:
                    raise ValueError("signing report exceeds the supported size")
                report = json.loads(args.signing_report.read_text(encoding="utf-8"))
            write_manifest(args.path, args.version, args.build_number, args.commit, args.signing_mode, report)
    except (ValueError, OSError) as error:
        print(f"release metadata: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
