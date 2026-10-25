#!/usr/bin/env python3
"""Capture one already-frontmost window; refuse rather than activate or retry.

Use a bundle identifier for --app. All evidence is local in a new private folder.
Exit 2 means preflight refusal, unsuccessful capture, or changed foreground state.
Exit 124/125 means completion is unknown; the app/launcher is never killed.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    with path.open("x", encoding="utf-8") as destination:
        json.dump(value, destination, ensure_ascii=False, indent=2, sort_keys=True)
        destination.write("\n")


def read_json(path):
    try:
        with path.open(encoding="utf-8") as source:
            return json.load(source), None
    except (OSError, ValueError) as error:
        return None, str(error)


def execute(argv, directory, cwd, timeout, expect_receipt=None):
    directory.mkdir(mode=0o700)
    stdout, stderr = directory / "stdout.log", directory / "stderr.log"
    result = {"argv": argv, "startedAt": now(), "stdout": str(stdout), "stderr": str(stderr),
              "returnCode": None, "cliExitCode": None, "completionKnown": False,
              "outerDeadlineSeconds": timeout}
    started = time.monotonic()
    environment = os.environ.copy()
    environment["TMPDIR"] = str(directory)
    try:
        with stdout.open("xb") as out, stderr.open("xb") as err:
            process = subprocess.Popen(argv, cwd=cwd, env=environment,
                                       stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            result["processID"] = process.pid
            try:
                result["returnCode"] = process.wait(timeout=timeout)
                result["completionKnown"] = True
            except subprocess.TimeoutExpired:
                result.update(stopExitCode=124, error="Outer deadline exceeded. No process was killed; no further command will run.")
    except OSError as error:
        result.update(stopExitCode=125, error=str(error))
    result["finishedAt"], result["durationSeconds"] = now(), round(time.monotonic() - started, 3)
    if expect_receipt is not None and result["completionKnown"]:
        receipts = list(directory.glob("oneshot-run.*/receipt.json"))
        receipt, error = read_json(receipts[0]) if len(receipts) == 1 else (None, "Expected exactly one CLI completion receipt.")
        result["receiptFile"] = str(receipts[0]) if len(receipts) == 1 else None
        result["receipt"] = receipt
        valid = (isinstance(receipt, dict) and receipt.get("schemaVersion") == 1
                 and receipt.get("command") == expect_receipt
                 and type(receipt.get("exitCode")) is int and 0 <= receipt["exitCode"] <= 255)
        if valid:
            result["cliExitCode"] = receipt["exitCode"]
        if result["returnCode"] in (124, 125) or not valid or result["returnCode"] != receipt["exitCode"]:
            result.update(completionKnown=False,
                          stopExitCode=result["returnCode"] if result["returnCode"] in (124, 125) else 125,
                          error=error or "CLI completion is missing, invalid, or inconsistent; no further command will run.")
    write_json(directory / "command.json", result)
    return result


def frontmost_matches(state, app, pid):
    if not isinstance(state, dict) or not isinstance(state.get("frontmost"), dict):
        return False
    frontmost = state["frontmost"]
    targets = state.get("targets", [])
    return (frontmost.get("bundleIdentifier") == app and frontmost.get("pid") == pid
            and any(isinstance(target, dict) and target.get("bundleIdentifier") == app
                    and target.get("pid") == pid and target.get("isActive") is True
                    and target.get("isHidden") is False and target.get("isTerminated") is False
                    for target in targets))


class Refusal(Exception):
    def __init__(self, reason, code=2):
        super().__init__(reason)
        self.code = code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="Exact target bundle identifier")
    parser.add_argument("--window-id", required=True, type=int)
    parser.add_argument("--output", required=True, help="New evidence directory; never overwrites")
    args = parser.parse_args()
    if not 1 <= args.window_id <= 2**32 - 1:
        parser.error("--window-id must be between 1 and 4294967295")
    os.umask(0o077)
    root = Path(__file__).resolve().parent.parent
    output = Path(args.output).expanduser().absolute()
    executable = root / ".build/OneShot Probe.app/Contents/MacOS/oneshot"
    runner = root / "scripts/run-probe.sh"
    helper = root / "scripts/frontmost-state.swift"
    try:
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
    except OSError as error:
        parser.error(str(error))
    result = {"schemaVersion": 1, "startedAt": now(), "requestedApp": args.app,
              "windowID": args.window_id, "executable": str(executable),
              "status": "preflight", "commands": [],
              "notes": [
                  "No activation, permission request, Electron enablement, CUA warm-up, automatic waiting for the user, or command retry is performed.",
                  "NSWorkspace/NSRunningApplication metadata and window inventory are sequential observations; they do not establish continuous foreground state.",
                  "A foreground gate and stable executable hash do not establish AX completeness or screenshot/AX atomicity.",
                  "This is OneShot evidence. It is not a native Codex AppShot or a CUA reference capture.",
              ]}
    exit_code = 0

    def invoke_probe(name, arguments):
        command = execute([str(runner), "--wait-seconds", "45", *arguments],
                          output / name, root, 60, expect_receipt=arguments[0])
        result["commands"].append(command)
        if not command["completionKnown"]:
            raise Refusal(command["error"], command.get("stopExitCode", 125))
        return command

    def read_frontmost(name):
        command = execute(["/usr/bin/swift", "-module-cache-path", str(root / ".build/swift-module-cache"),
                           str(helper), args.app], output / name, root, 60)
        result["commands"].append(command)
        if not command["completionKnown"]:
            raise Refusal(command["error"], command.get("stopExitCode", 125))
        state, error = read_json(Path(command["stdout"]))
        if command["returnCode"] != 0 or not isinstance(state, dict):
            raise Refusal(error or "Read-only foreground metadata failed; no reliable foreground observation is available.")
        return state

    try:
        build_hash = sha256(executable)
        result["executableSHA256Before"] = build_hash
        # First gate rejects a different foreground app before launching the Probe.
        initial = read_frontmost("1-frontmost-initial")
        result["frontmostInitial"] = initial
        initial_pid = (initial.get("frontmost") or {}).get("pid")
        if not frontmost_matches(initial, args.app, initial_pid):
            raise Refusal("Requested application is not the active, visible foreground application; capture was not started.")
        windows_command = invoke_probe("2-windows", ["windows", "--app", args.app])
        windows, error = read_json(Path(windows_command["stdout"]))
        if windows_command["cliExitCode"] != 0 or not isinstance(windows, list):
            raise Refusal(error or "Window inventory failed; capture was not started.")
        matches = [window for window in windows if isinstance(window, dict) and window.get("id") == args.window_id]
        if len(matches) != 1:
            raise Refusal("Requested window is absent or ambiguous in the target application's inventory; capture was not started.")
        window = matches[0]
        result["windowPreflight"] = window
        if window.get("bundleIdentifier") != args.app or window.get("pid") != initial_pid or window.get("isOnScreen") is not True:
            raise Refusal("Requested window does not belong to the observed foreground process or is not on screen; capture was not started.")
        # The background Probe inventory must not substitute an earlier activation sample.
        before = read_frontmost("3-frontmost-before")
        result["frontmostBefore"] = before
        if not frontmost_matches(before, args.app, window["pid"]):
            raise Refusal("Foreground application/PID changed during preflight; capture was not started.")
        if sha256(executable) != build_hash:
            raise Refusal("Probe executable changed during preflight; capture was not started.")
        result["preflightPassed"] = True
        capture = invoke_probe("4-capture-command", ["capture", "--app", args.app,
                               "--window-id", str(args.window_id), "--ocr", "--output", str(output / "capture")])
        result["captureCLIExitCode"] = capture["cliExitCode"]
        after = read_frontmost("5-frontmost-after")
        result["frontmostAfter"] = after
        result["targetStillFrontmostAfter"] = frontmost_matches(after, args.app, window["pid"])
        manifest, error = read_json(output / "capture/manifest.json")
        result["captureManifest"] = manifest
        result["captureManifestReadError"] = error
        captured_window = manifest.get("window") if isinstance(manifest, dict) else None
        result["captureMatchesPreflightTarget"] = (
            isinstance(captured_window, dict) and captured_window.get("id") == args.window_id
            and captured_window.get("pid") == window["pid"]
            and captured_window.get("bundleIdentifier") == args.app
            and captured_window.get("isOnScreen") is True
        )
        if capture["cliExitCode"] != 0:
            raise Refusal(f"Capture completed with CLI exit {capture['cliExitCode']}; its evidence is retained.")
        if not result["captureMatchesPreflightTarget"]:
            raise Refusal("Capture metadata did not confirm the same on-screen window/PID as preflight; evidence is retained.")
        if not result["targetStillFrontmostAfter"]:
            raise Refusal("Capture completed, but the target application/PID was not still foreground at the final observation.")
        result["status"] = "captured"
    except Refusal as error:
        exit_code = error.code
        result.update(status="stopped" if exit_code in (124, 125) else "refused_or_incomplete", reason=str(error))
    except (OSError, ValueError) as error:
        exit_code = 1
        result.update(status="failed", reason=str(error))
    except KeyboardInterrupt:
        exit_code = 130
        result.update(status="interrupted", reason="Interrupted; no process was killed and no further command launched.")
    finally:
        result["finishedAt"] = now()
        try:
            result["executableSHA256After"] = sha256(executable)
            result["executableUnchangedAtEndpoints"] = result["executableSHA256After"] == result.get("executableSHA256Before")
            if not result["executableUnchangedAtEndpoints"] and exit_code == 0:
                exit_code = 2
                result.update(status="refused_or_incomplete", reason="Probe executable changed; fixed-build capture cannot be assumed.")
        except OSError as error:
            result["executableHashAfterError"] = str(error)
            result["executableUnchangedAtEndpoints"] = None
            if exit_code == 0:
                exit_code = 1
                result.update(status="failed", reason="Final executable hash could not be read.")
        result["exitCode"] = exit_code
        write_json(output / "result.json", result)
    print(f"Evidence: {output}\nStatus: {result['status']}" + (f"\n{result['reason']}" if "reason" in result else ""))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
