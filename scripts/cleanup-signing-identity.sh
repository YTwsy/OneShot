#!/bin/zsh
# Remove only the temporary keychain created by import-signing-identity.sh.
set +x
set -euo pipefail
umask 077

python3 - "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import stat
import subprocess
import sys

parser = argparse.ArgumentParser(description="Delete only OneShot's marked task-owned temporary keychain and directory.")
parser.add_argument("--directory", required=True, help="Exact oneshot-signing-* directory passed to the import script")
args = parser.parse_args()

try:
    requested = Path(args.directory)
    if not requested.is_absolute() or any(character in args.directory for character in "\r\n\0"):
        raise ValueError("--directory must be an absolute path without line breaks.")
    if not re.fullmatch(r"oneshot-signing-[A-Za-z0-9._-]+", requested.name):
        raise ValueError("Refusing to remove a directory without the oneshot-signing- prefix.")
    directory = requested.parent.resolve(strict=True) / requested.name
    if directory.is_symlink():
        raise ValueError("Refusing to follow a linked signing directory.")
    runner_temp = os.environ.get("RUNNER_TEMP")
    if runner_temp and not directory.is_relative_to(Path(runner_temp).resolve(strict=True)):
        raise ValueError("In CI cleanup is restricted to RUNNER_TEMP.")
    if not directory.exists():
        print("No task-owned signing keychain remains.")
        sys.exit(0)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("The signing directory is not a private directory owned by this user.")
    state = directory / ".oneshot-signing-state.json"
    state_info = state.lstat()
    if not stat.S_ISREG(state_info.st_mode) or state_info.st_uid != os.getuid() or state_info.st_size > 4096:
        raise ValueError("The signing ownership marker is invalid.")
    marker = json.loads(state.read_text())
    keychain = directory / "identity.keychain-db"
    expected = {"schemaVersion": 1, "ownerUID": os.getuid(), "directory": str(directory), "keychain": str(keychain)}
    if marker != expected or keychain.is_symlink():
        raise ValueError("The signing ownership marker does not match this exact temporary directory.")
    deletion_failed = False
    if keychain.exists():
        try:
            result = subprocess.run(["/usr/bin/security", "delete-keychain", str(keychain)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            deletion_failed = result.returncode != 0
        except (OSError, subprocess.SubprocessError):
            deletion_failed = True
    # delete-keychain normally unregisters itself. Also remove a stale own
    # entry if needed, using the current list so other processes' additions stay.
    result = subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if result.returncode:
        raise ValueError("Unable to inspect the keychain search list; cleanup must be retried.")
    entries = shlex.split(result.stdout.decode("utf-8", errors="replace"))
    remaining = [entry for entry in entries if entry != str(keychain)]
    if remaining != entries:
        result = subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *remaining],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        if result.returncode:
            raise ValueError("Unable to remove the temporary keychain lookup entry; cleanup must be retried.")
    if deletion_failed:
        raise ValueError("Unable to delete the task-owned keychain; its lookup entry was removed, and cleanup must be retried.")
    shutil.rmtree(directory)
    print("Removed the task-owned temporary signing keychain and private directory.")
except (OSError, ValueError, subprocess.SubprocessError) as error:
    print("Signing cleanup failed: " + (str(error) if isinstance(error, ValueError) else "local cleanup operation unavailable"), file=sys.stderr)
    sys.exit(1)
PY
