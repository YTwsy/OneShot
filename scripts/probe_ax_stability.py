#!/usr/bin/env python3
"""Sequential window-matching observations using one already-built Probe app.

Exit 0 means the experiment finished, including any recorded CLI capture failures.
It does not mean every window match succeeded or a complete AX tree was captured.
No command is retried. Timeout/unknown completion stops the experiment without
killing the app or launcher; their original files remain in the evidence folder.
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


NOTES = [
    "This experiment tests window matching and at most one captured root node, not AX tree or document completeness.",
    "Every command launches a separate short-lived Probe process through LaunchServices; this is not a single-process lifecycle test.",
    "This script performs no CUA warm-up. Previous accessibility activation, other clients, and application history are unknown.",
    "No TCC changes, focus changes, clicks, scrolling, or Electron accessibility enablement are requested by this script.",
    "Application/window identity and visibility equality describe sampled endpoints only, not continuous stability or atomic content.",
    "The recorded source Git HEAD is contextual metadata, not proof that this executable was built from that commit.",
    "Runner exit 124/125, missing or invalid receipts, and an outer launch deadline stop the experiment. No process is killed or command retried.",
]


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")


def bounded_integer(low, high):
    def parse(value):
        try:
            result = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError("must be an integer")
        if not low <= result <= high:
            raise argparse.ArgumentTypeError(f"must be between {low} and {high}")
        return result
    return parse


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    # All evidence names are new, even when an earlier command failed.
    with path.open("x", encoding="utf-8") as destination:
        json.dump(value, destination, ensure_ascii=False, indent=2, sort_keys=True)
        destination.write("\n")


def read_json(path):
    try:
        with path.open(encoding="utf-8") as source:
            return json.load(source), None
    except (OSError, ValueError) as error:
        return None, str(error)


def source_head(root):
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=root, capture_output=True,
            text=True, timeout=5, check=False,
        )
        return {"value": result.stdout.strip() if result.returncode == 0 else None,
                "exitCode": result.returncode, "error": result.stderr.strip() or None,
                "isBuildProvenance": False}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"value": None, "error": str(error), "isBuildProvenance": False}


def run_command(runner, arguments, directory, root):
    directory.mkdir(mode=0o700)
    stdout = directory / "stdout.log"
    stderr = directory / "stderr.log"
    command = [str(runner), "--wait-seconds", "15", *arguments]
    record = {"argv": command, "startedAt": timestamp(),
              "stdout": str(stdout), "stderr": str(stderr),
              "runnerReturnCode": None, "cliExitCode": None,
              "outerDeadlineSeconds": 25, "stopExperiment": False}
    started = time.monotonic()
    environment = os.environ.copy()
    # run-probe's private receipt and LaunchServices logs stay inside this experiment.
    environment["TMPDIR"] = str(directory)
    try:
        with stdout.open("xb") as out, stderr.open("xb") as err:
            process = subprocess.Popen(command, cwd=root, env=environment,
                                       stdout=out, stderr=err, stdin=subprocess.DEVNULL)
            record["runnerPID"] = process.pid
            try:
                record["runnerReturnCode"] = process.wait(timeout=25)
            except subprocess.TimeoutExpired:
                record.update(stopExperiment=True, stopExitCode=124,
                              error="Outer launch/completion deadline exceeded. Launcher/app may still run; neither was killed.")
    except OSError as error:
        record.update(stopExperiment=True, stopExitCode=125, error=str(error))
    record["finishedAt"] = timestamp()
    record["durationSeconds"] = round(time.monotonic() - started, 3)
    if not record["stopExperiment"]:
        receipts = list(directory.glob("oneshot-run.*/receipt.json"))
        receipt, error = read_json(receipts[0]) if len(receipts) == 1 else (None, "Expected exactly one completion receipt.")
        record["receiptFile"] = str(receipts[0]) if len(receipts) == 1 else None
        if isinstance(receipt, dict):
            record["receipt"] = receipt
        valid = (isinstance(receipt, dict) and receipt.get("schemaVersion") == 1
                 and receipt.get("command") == arguments[0]
                 and type(receipt.get("exitCode")) is int
                 and 0 <= receipt["exitCode"] <= 255)
        if valid:
            record["cliExitCode"] = receipt["exitCode"]
        code = record["runnerReturnCode"]
        if code in (124, 125):
            record.update(stopExperiment=True, stopExitCode=code,
                          error="Runner could not establish a normal completion; no further command will launch.")
        elif not valid or code != receipt["exitCode"]:
            record.update(stopExperiment=True, stopExitCode=125,
                          error=error or "Missing, invalid, or inconsistent CLI completion receipt.")
    write_json(directory / "command.json", record)
    return record


def target_window(command, window_id):
    if command is None:
        return {"status": "not_run", "window": None}
    value, error = read_json(Path(command["stdout"]))
    if command["cliExitCode"] != 0 or not isinstance(value, list):
        return {"status": "unavailable", "window": None, "error": error or "Window listing did not succeed."}
    matches = [entry for entry in value if isinstance(entry, dict) and entry.get("id") == window_id]
    if len(matches) != 1:
        return {"status": "missing_or_ambiguous", "window": None, "matchCount": len(matches)}
    # Keep the actual metadata including PID, title, bounds and isOnScreen.
    return {"status": "found", "window": matches[0]}


def diagnostic_summary(command):
    if command is None:
        return {"status": "not_run"}
    value, error = read_json(Path(command["stdout"]))
    if command["cliExitCode"] != 0 or not isinstance(value, dict):
        return {"status": "unavailable", "error": error or "Diagnostic command did not succeed."}
    return {"status": "recorded", "pid": value.get("pid"),
            "accessibilityTrusted": value.get("accessibilityTrusted"),
            "failureReason": value.get("failureReason"),
            "applicationState": value.get("applicationState"),
            "windowsRead": value.get("windowsRead"),
            "windowEntryCount": value.get("windowEntryCount"),
            "validWindowCount": value.get("validWindowCount"),
            "inspectedCandidateCount": len(value.get("candidates", [])),
            "inspectionAttempts": value.get("inspectionAttempts")}


def capture_summary(directory, command):
    if command is None:
        return {"status": "not_run", "matchedRootCaptured": None}
    manifest, manifest_error = read_json(directory / "manifest.json")
    result, result_error = read_json(directory / "accessibility.json")
    root_id = result.get("rootNodeID") if isinstance(result, dict) else None
    match = result.get("windowMatch") if isinstance(result, dict) else None
    nodes = result.get("nodes", []) if isinstance(result, dict) else []
    has_root = bool(root_id and any(isinstance(node, dict) and node.get("id") == root_id for node in nodes))
    return {"status": "recorded", "cliExitCode": command["cliExitCode"],
            "matchedRootCaptured": bool(match and has_root), "windowMatch": match,
            "rootNodeID": root_id, "nodeCount": len(nodes),
            "completeness": result.get("completeness") if isinstance(result, dict) else None,
            "accessibility": manifest.get("accessibility") if isinstance(manifest, dict) else None,
            "window": manifest.get("window") if isinstance(manifest, dict) else None,
            "windowAfter": manifest.get("windowAfter") if isinstance(manifest, dict) else None,
            "consistency": manifest.get("consistency") if isinstance(manifest, dict) else None,
            "manifestReadError": manifest_error, "accessibilityReadError": result_error}


def round_summary(directory, commands, window_id):
    by_name = {command["step"]: command for command in commands}
    before = target_window(by_name.get("windows-before"), window_id)
    after = target_window(by_name.get("windows-after"), window_id)
    first, last = before["window"], after["window"]
    identity_keys = ("id", "pid", "ownerName", "bundleIdentifier", "title", "bounds")
    comparable = first is not None and last is not None
    return {"windowsBefore": before, "windowsAfter": after,
            "identityBeforeAfterEqual": all(first.get(key) == last.get(key) for key in identity_keys) if comparable else None,
            "visibilityBeforeAfterEqual": first.get("isOnScreen") == last.get("isOnScreen") if comparable else None,
            "diagnoseBefore": diagnostic_summary(by_name.get("diagnose-before")),
            "diagnoseAfter": diagnostic_summary(by_name.get("diagnose-after")),
            "capture": capture_summary(directory / "capture", by_name.get("capture"))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--window-id", required=True, type=bounded_integer(1, 2**32 - 1))
    parser.add_argument("--output", required=True, help="New private evidence directory; existing paths are rejected")
    parser.add_argument("--rounds", type=bounded_integer(1, 10), default=3)
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parent.parent
    runner = root / "scripts/run-probe.sh"
    executable = root / ".build/OneShot Probe.app/Contents/MacOS/oneshot"
    output = Path(args.output).expanduser().absolute()
    try:
        build_hash = sha256(executable)
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
    except OSError as error:
        parser.error(str(error))
    summary = {"schemaVersion": 1, "startedAt": timestamp(), "requestedApp": args.app,
               "windowID": args.window_id, "requestedRounds": args.rounds,
               "executable": str(executable), "executableSHA256Before": build_hash,
               "sourceGitHEAD": source_head(root), "notes": NOTES,
               "rounds": [], "status": "running"}
    exit_code = 0
    try:
        for number in range(1, args.rounds + 1):
            directory = output / f"round-{number}"
            directory.mkdir(mode=0o700)
            current = {"round": number, "commands": []}
            summary["rounds"].append(current)
            common = ["--app", args.app, "--window-id", str(args.window_id)]
            steps = [
                ("windows-before", ["windows", "--app", args.app]),
                ("diagnose-before", ["diagnose", *common]),
                ("capture", ["capture", *common, "--no-image", "--max-nodes", "1",
                             "--max-depth", "1", "--max-text-characters", "256", "--timeout", "5",
                             "--output", str(directory / "capture")]),
                ("diagnose-after", ["diagnose", *common]),
                ("windows-after", ["windows", "--app", args.app]),
            ]
            for index, (name, arguments) in enumerate(steps, 1):
                if sha256(executable) != build_hash:
                    raise RuntimeError("Probe executable changed during the experiment; no further command launched.")
                print(f"Round {number}/{args.rounds}: {name}", flush=True)
                command = run_command(runner, arguments, directory / f"{index}-{name}", root)
                command["step"] = name
                current["commands"].append(command)
                if command["stopExperiment"]:
                    exit_code = command["stopExitCode"]
                    summary["stopReason"] = command["error"]
                    break
            current["observations"] = round_summary(directory, current["commands"], args.window_id)
            write_json(directory / "round.json", current)
            if exit_code:
                break
        summary["status"] = "stopped" if exit_code else "completed"
    except (OSError, RuntimeError, ValueError) as error:
        exit_code = 1
        summary.update(status="stopped", stopReason=str(error))
    except KeyboardInterrupt:
        exit_code = 130
        summary.update(status="interrupted", stopReason="Interrupted; no process was killed and no further command launched.")
    finally:
        summary["finishedAt"] = timestamp()
        summary["experimentExitCode"] = exit_code
        try:
            summary["executableSHA256After"] = sha256(executable)
            summary["executableUnchangedAtEndpoints"] = summary["executableSHA256After"] == build_hash
            if not summary["executableUnchangedAtEndpoints"] and not exit_code:
                exit_code = 1
                summary.update(status="stopped", experimentExitCode=exit_code,
                               stopReason="Probe executable changed; fixed-build observations cannot be assumed.")
        except OSError as error:
            summary["executableHashAfterError"] = str(error)
            summary["executableUnchangedAtEndpoints"] = None
            if not exit_code:
                exit_code = 1
                summary.update(status="stopped", experimentExitCode=exit_code,
                               stopReason="Could not verify the final executable hash.")
        summary["completedRounds"] = sum(len(item["commands"]) == 5 and not any(command["stopExperiment"] for command in item["commands"]) for item in summary["rounds"])
        summary["matchedRootRounds"] = sum(item.get("observations", {}).get("capture", {}).get("matchedRootCaptured") is True for item in summary["rounds"])
        write_json(output / "summary.json", summary)
    print(f"Evidence: {output}\nStatus: {summary['status']}; completed rounds: {summary['completedRounds']}; matched roots: {summary['matchedRootRounds']}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
