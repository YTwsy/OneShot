#!/usr/bin/env python3
"""Inspect only frozen capture files. Metrics are not a claim of semantic completeness."""
import argparse
import collections
import json
from pathlib import Path


def summarize(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "manifest.json").read_text())
    path = directory / "accessibility.json"
    ax = json.loads(path.read_text()) if path.exists() else {}
    roles = collections.Counter()
    types = collections.Counter()
    sources = collections.Counter()
    urls = []
    longest = []
    unique_text = set()
    nodes = ax.get("nodes", [])
    node_ids = {node["id"] for node in nodes}
    unresolved = set()
    for node in nodes:
        attrs = node.get("attributes", {})
        roles[attrs.get("AXRole", {}).get("value", {}).get("text", "unknown")] += 1
        for name, attribute in attrs.items():
            value = attribute.get("value") or {}
            types[value.get("type", attribute.get("status", "unknown"))] += 1
            text = value.get("text")
            if text:
                unique_text.add(text)
                longest.append({"nodeID": node["id"], "attribute": name, "characters": len(text), "truncated": value.get("truncated", False)})
                if name in ("AXURL", "AXDocument") or value.get("type") == "url":
                    urls.append({"nodeID": node["id"], "attribute": name, "value": text})
                if value.get("type") == "attributed_text":
                    sources[name] += 1
        for targets in node.get("relations", {}).values():
            unresolved.update(target for target in targets if target not in node_ids)
    return {
        "captureID": manifest["captureID"],
        "application": manifest["requestedApp"],
        "windowID": manifest["window"]["id"],
        "componentOutcomes": {key: manifest[key] for key in ("accessibility", "screenshot", "ocr")},
        "consistency": manifest["consistency"],
        "axNodes": len(nodes),
        "axCompleteness": ax.get("completeness", "unavailable"),
        "focusedNodeID": ax.get("focusedNodeID"),
        "roleCounts": dict(roles),
        "valueTypeCounts": dict(types),
        "richTextSources": dict(sources),
        "urls": urls,
        "longestTextAttributes": sorted(longest, key=lambda row: row["characters"], reverse=True)[:10],
        "uniqueTextCharacters": sum(map(len, unique_text)),
        "unvisitedReferencedNodes": sorted(unresolved),
        "diagnosticCounts": dict(collections.Counter(d["code"] for d in ax.get("diagnostics", []))),
        "note": "Only describes stored evidence. Text size, node count and completed reads do not prove whole-document completeness.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture_directory")
    args = parser.parse_args()
    print(json.dumps(summarize(args.capture_directory), ensure_ascii=False, indent=2))
