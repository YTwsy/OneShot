#!/bin/zsh
# Import an existing identity only into a fresh directory owned by this task.
# Run with zsh; never enable tracing around certificate or keychain operations.
set +x
set -euo pipefail
umask 077

python3 - "$@" <<'PY'
import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description="Import a fixed P12 into a task-owned temporary keychain; never creates a certificate or changes trust settings.")
parser.add_argument("--directory", required=True, help="New absolute oneshot-signing-* directory; must be under RUNNER_TEMP when set")
parser.add_argument("--github-env", help="Existing GITHUB_ENV file to receive the non-secret keychain path and selected certificate SHA1")
args = parser.parse_args()

def fail(message):
    raise ValueError(message)

def security(*arguments):
    # Captured diagnostics can contain identity details. Do not send them to logs.
    result = subprocess.run(["/usr/bin/security", *arguments], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=30)
    if result.returncode:
        fail("A keychain operation failed; verify the P12, its password, and the identity selector.")
    return result.stdout.decode("utf-8", errors="replace")

def remove_search_entry(path):
    # Observe the current list instead of replaying a saved list, so entries
    # added by other processes remain in place.
    entries = shlex.split(security("list-keychains", "-d", "user"))
    remaining = [entry for entry in entries if entry != str(path)]
    if remaining != entries:
        security("list-keychains", "-d", "user", "-s", *remaining)


directory = None
keychain = None
created = False
try:
    requested = Path(args.directory)
    if not requested.is_absolute() or any(character in args.directory for character in "\r\n\0"):
        fail("--directory must be an absolute path without line breaks.")
    if not re.fullmatch(r"oneshot-signing-[A-Za-z0-9._-]+", requested.name):
        fail("The new directory name must begin with oneshot-signing-.")
    directory = requested.parent.resolve(strict=True) / requested.name
    if directory.exists() or directory.is_symlink():
        fail("The signing directory already exists; select a fresh task-owned directory.")
    runner_temp = os.environ.get("RUNNER_TEMP")
    if runner_temp and not directory.is_relative_to(Path(runner_temp).resolve(strict=True)):
        fail("In CI the signing directory must be inside RUNNER_TEMP.")
    env_path = None
    if args.github_env:
        env_path = Path(args.github_env)
        if not env_path.is_absolute() or env_path.is_symlink() or not env_path.is_file():
            fail("--github-env must name an existing, regular absolute file.")
    mode = os.environ.get("ONESHOT_SIGNING_MODE", "developer-id")
    if mode not in ("self-signed", "apple-development", "developer-id"):
        fail("ONESHOT_SIGNING_MODE must select a reusable certificate mode.")
    selector = os.environ.get("ONESHOT_SIGNING_IDENTITY", "")
    if not selector.strip() or selector != selector.strip() or any(character in selector for character in "\r\n\0"):
        fail("ONESHOT_SIGNING_IDENTITY must select the fixed certificate by SHA1 or exact name.")
    encoded = os.environ.get("ONESHOT_SIGNING_CERTIFICATE_BASE64", "")
    if not encoded or len(encoded) > 4_194_304:
        fail("ONESHOT_SIGNING_CERTIFICATE_BASE64 is missing or exceeds the supported size.")
    if "ONESHOT_SIGNING_CERTIFICATE_PASSWORD" not in os.environ:
        fail("ONESHOT_SIGNING_CERTIFICATE_PASSWORD must be configured, even for an empty P12 password.")
    try:
        certificate = base64.b64decode("".join(encoded.split()), validate=True)
    except (ValueError, binascii.Error):
        fail("ONESHOT_SIGNING_CERTIFICATE_BASE64 is not valid base64.")
    if not certificate or len(certificate) > 3_145_728:
        fail("The P12 is empty or exceeds the supported size.")

    directory.mkdir(mode=0o700)
    created = True
    keychain = directory / "identity.keychain-db"
    marker = {"schemaVersion": 1, "ownerUID": os.getuid(), "directory": str(directory),
              "keychain": str(keychain)}
    (directory / ".oneshot-signing-state.json").write_text(json.dumps(marker) + "\n")
    p12 = directory / "identity.p12"
    p12.write_bytes(certificate)
    password = secrets.token_urlsafe(48)
    security("create-keychain", "-p", password, str(keychain))
    # --keychain selects an identity, but codesign still requires its keychain
    # in the user's search list. This is lookup configuration, not trust.
    entries = shlex.split(security("list-keychains", "-d", "user"))
    if str(keychain) not in entries:
        security("list-keychains", "-d", "user", "-s", *entries, str(keychain))
    security("set-keychain-settings", "-lut", "21600", str(keychain))
    security("unlock-keychain", "-p", password, str(keychain))
    security("import", str(p12), "-k", str(keychain), "-P",
             os.environ["ONESHOT_SIGNING_CERTIFICATE_PASSWORD"],
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    security("set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, str(keychain))
    p12.unlink()
    # Self-signed root identities can sign a pinned DR without system trust.
    # Select them from all identities; release verification checks the actual
    # self-signature and exact leaf pin. Apple modes also require valid trust.
    output = security("find-identity", "-p", "codesigning", str(keychain))
    identities = {}
    for line in output.splitlines():
        match = re.match(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"(?:\s+.*)?$', line)
        if match:
            identities[match.group(1).upper()] = match.group(2)
    matches = [fingerprint for fingerprint, name in identities.items()
               if fingerprint == selector.upper() or name == selector]
    if len(matches) != 1:
        fail("The configured selector must match exactly one code-signing identity in the supplied P12.")
    selected = matches[0]
    if mode != "self-signed":
        valid_output = security("find-identity", "-v", "-p", "codesigning", str(keychain))
        valid_identities = {match.group(1).upper() for line in valid_output.splitlines()
                            if (match := re.match(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"', line))}
        if selected not in valid_identities:
            fail("The selected Apple identity is not valid/trusted for code signing; no trust settings changed. "
                 "Check the Apple certificate chain/setup before importing.")
    values = {"ONESHOT_SIGNING_KEYCHAIN": str(keychain), "ONESHOT_SIGNING_IDENTITY": selected}
    (directory / "signing-environment.json").write_text(json.dumps(values, indent=2) + "\n")
    if env_path:
        with env_path.open("a") as output_file:
            for name, value in values.items():
                output_file.write(name + "=" + value + "\n")
    print("Imported the selected signing identity into the task-owned temporary keychain.")
    print("Non-secret signing environment: " + str(directory / "signing-environment.json"))
except (OSError, ValueError, subprocess.SubprocessError) as error:
    if created:
        # This directory was created in this process, never an existing user keychain.
        removed = True
        if keychain and keychain.exists():
            try:
                removed = subprocess.run(["/usr/bin/security", "delete-keychain", str(keychain)],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         timeout=30).returncode == 0
            except (OSError, subprocess.SubprocessError):
                removed = False
        # Removing lookup access is independent of deleting the keychain.
        # Even if deletion fails, stop exposing this task's identity in searches.
        try:
            remove_search_entry(keychain)
        except (OSError, ValueError, subprocess.SubprocessError):
            removed = False
        if removed:
            try:
                shutil.rmtree(directory)
            except OSError:
                removed = False
        if not removed:
            # Leave the ownership marker for the workflow's always() cleanup step.
            p12 = directory / "identity.p12"
            if p12.is_file() and not p12.is_symlink():
                p12.unlink()
            print("Temporary keychain cleanup needs retry with cleanup-signing-identity.sh.", file=sys.stderr)
    # ValueError messages above are fixed text; never print subprocess output or environment values.
    print("Signing identity import failed: " + (str(error) if isinstance(error, ValueError) else "local keychain operation unavailable"), file=sys.stderr)
    sys.exit(1)
PY
