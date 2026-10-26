#!/usr/bin/env python3
"""Verify a built OneShot MCP server answers while its stdin remains open.

The selected handoff is read only. No capture, application activation, Agent
configuration, or network access is performed. Requires Python's standard library.
"""

import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time


class LiveClient:
    def __init__(self, binary: Path, handoff: Path, timeout: float):
        self.process = subprocess.Popen(
            [str(binary), "--handoff", str(handoff)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = bytearray()
        self.timeout = timeout
        self.next_id = 1
        self.responses = 0

    def send(self, message: dict) -> None:
        wire = json.dumps(dict(jsonrpc="2.0", **message), ensure_ascii=False).encode() + b"\n"
        self.process.stdin.write(wire)
        self.process.stdin.flush()

    def request(self, method: str, params=None) -> dict:
        request_id = self.next_id
        self.next_id += 1
        self.send(dict(id=request_id, method=method, params=params or {}))
        deadline = time.monotonic() + self.timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError(f"{method} did not answer while client stdin remained open")
            chunk = os.read(self.process.stdout.fileno(), 65_536)
            if not chunk:
                raise RuntimeError(f"MCP stdout closed while waiting for {method}")
            self.buffer.extend(chunk)
            if len(self.buffer) > 16 * 1_024 * 1_024:
                raise RuntimeError("MCP response exceeded the regression client's 16 MiB budget")
        newline = self.buffer.index(10)
        line = bytes(self.buffer[:newline])
        del self.buffer[: newline + 1]
        response = json.loads(line)
        if response.get("jsonrpc") != "2.0" or response.get("id") != request_id:
            raise RuntimeError(f"Unexpected response to {method}: id={response.get('id')!r}")
        if "error" in response:
            raise RuntimeError(f"{method} failed: {response['error']}")
        self.responses += 1
        return response["result"]

    def tool(self, name: str, arguments=None) -> dict:
        result = self.request("tools/call", dict(name=name, arguments=arguments or {}))
        if result.get("isError"):
            raise RuntimeError(f"{name} failed: {result.get('content')}")
        content = result.get("content", [])
        if len(content) != 1 or content[0].get("type") != "text":
            raise RuntimeError(f"{name} returned unexpected content")
        return json.loads(content[0]["text"])

    def finish(self) -> int:
        # All assertions above ran before EOF. Closing stdin only shuts down now.
        self.process.stdin.close()
        code = self.process.wait(timeout=self.timeout)
        stderr = self.process.stderr.read()
        if code or stderr or self.buffer:
            raise RuntimeError(f"Unclean MCP shutdown: exit={code}, stderr={stderr.decode(errors='replace')!r}")
        return len(stderr)

    def close(self) -> None:
        self.selector.close()
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        for stream in [self.process.stdin, self.process.stdout, self.process.stderr]:
            if stream:
                stream.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path, help="Path to a built oneshot-mcp executable")
    parser.add_argument("--handoff", required=True, type=Path, help="One existing export folder to read")
    parser.add_argument("--timeout", type=float, default=10, help="Seconds allowed for each live response")
    args = parser.parse_args()
    if not 0 < args.timeout <= 60:
        parser.error("--timeout must be greater than 0 and at most 60")
    binary = args.binary.absolute()
    handoff = args.handoff.absolute()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("--binary must point to an executable file")
    if not handoff.is_dir():
        parser.error("--handoff must point to an existing export folder")
    client = LiveClient(binary, handoff, args.timeout)
    try:
        initialized = client.request(
            "initialize",
            dict(protocolVersion="2025-06-18", capabilities={}, clientInfo=dict(name="OneShot live stdio regression", version="1")),
        )
        if initialized.get("protocolVersion") != "2025-06-18":
            raise RuntimeError("Unexpected protocol negotiation")
        client.send(dict(method="notifications/initialized"))
        tools = client.request("tools/list")["tools"]
        expected = {"read_brief", "read_annotations", "read_annotation", "read_context", "read_image"}
        if {tool["name"] for tool in tools} != expected:
            raise RuntimeError("Unexpected tool surface")
        brief = client.tool("read_brief", dict(limit=4_096))
        annotations = client.tool("read_annotations")
        manifest = client.tool("read_context", dict(source="manifest", limit=4_096))
        if not brief.get("captureID") or brief["captureID"] != annotations.get("captureID") or brief["captureID"] != manifest.get("captureID"):
            raise RuntimeError("Tool responses disagree on the selected capture")
        if "annotations" not in annotations or not manifest.get("text"):
            raise RuntimeError("Selected capture material was not readable")
        stderr_bytes = client.finish()
        print(json.dumps(dict(
            result="passed", transport="persistent live stdio", initializeBeforeEOF=True,
            allResponsesBeforeEOF=True, responses=client.responses, tools=len(tools),
            captureID=brief["captureID"], totalAnnotations=annotations["totalAnnotations"],
            stderrBytes=stderr_bytes,
        ), ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, TimeoutError, subprocess.TimeoutExpired) as error:
        print(f"MCP live stdio regression failed: {error}", file=sys.stderr)
        return 1
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
