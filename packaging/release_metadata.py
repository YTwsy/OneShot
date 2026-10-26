#!/usr/bin/env python3
"""Versioned metadata for OneShot's ad-hoc, unnotarized preview distribution."""

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


def bundle_metadata(version: str, build_number: str, commit: str, capture: bool = False) -> dict:
    marketing = validate(version, build_number, commit)
    name = "OneShot Capture" if capture else "OneShot"
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
        "OneShotSigningStatus": "ad-hoc-unnotarized",
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


def write_bundle_metadata(app: Path, version: str, build_number: str, commit: str) -> None:
    for bundle, capture in [(app, False), (app / "Contents/Helpers/OneShot Capture.app", True)]:
        target = bundle / "Contents/Info.plist"
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as output:
            plistlib.dump(bundle_metadata(version, build_number, commit, capture), output, sort_keys=True)


def write_manifest(directory: Path, version: str, build_number: str, commit: str) -> None:
    marketing = validate(version, build_number, commit)
    files = []
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.name != "release-manifest.json":
            files.append({"file": path.name, "bytes": path.stat().st_size,
                          "sha256": sha256_file(path)})
    result = {
        "schemaVersion": 1, "product": "OneShot", "version": marketing,
        "releaseVersion": version, "tag": "v" + version, "buildNumber": build_number,
        "sourceCommit": commit, "architecture": "arm64", "minimumMacOS": "14.0",
        "prerelease": True, "adHocSigned": True, "developerIDSigned": False,
        "notarized": False, "automaticUpdates": False,
        "bundleIdentifiers": {"application": APP_ID, "capture": CAPTURE_ID, "mcp": MCP_ID},
        "files": files,
    }
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
    args = parser.parse_args()
    try:
        marketing = validate(args.version, args.build_number, args.commit)
        if args.command == "validate":
            print(marketing)
        elif args.path is None:
            parser.error("--path is required for this command")
        elif args.command == "bundles":
            write_bundle_metadata(args.path, args.version, args.build_number, args.commit)
        else:
            write_manifest(args.path, args.version, args.build_number, args.commit)
    except (ValueError, OSError) as error:
        print(f"release metadata: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
