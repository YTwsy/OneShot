#!/usr/bin/env python3
"""Inspect only frozen capture files. Metrics are not a claim of semantic completeness."""
import argparse
import collections
import json
from pathlib import Path


def inspect_recorded_values(nodes, node_ids, *, max_values=1_000_000,
                            max_run_attributes=1_000_000, max_runs=1_000_000,
                            max_depth=32, max_examples=20):
    """Count stored serialization limits without treating absence/opaque handles as errors.

    Counts describe occurrences, including repeated rich-text representations. Examples omit
    source text. Budgets apply to this value scan, not the separate top-level status counts.
    """
    unsupported = collections.Counter()
    unsupported_types = collections.Counter()
    placeholders = collections.Counter()
    run_attribute_names = collections.Counter()
    references = collections.Counter()
    reference_reasons = collections.Counter()
    examples = {"unsupported": [], "placeholders": [], "references": []}
    visited = 0
    runs_visited = 0
    run_attributes_visited = 0
    limits_hit = set()

    def example(category, node_id, attribute, path, **details):
        if len(examples[category]) < max_examples:
            examples[category].append({"nodeID": node_id, "attribute": attribute,
                                       "valuePath": path, **details})

    def visit(value, node_id, attribute, depth=0, path="value"):
        nonlocal visited, runs_visited, run_attributes_visited
        if visited >= max_values:
            limits_hit.add("value_limit")
            return
        if depth > max_depth:
            limits_hit.add("depth_limit")
            return
        if not isinstance(value, dict):
            return
        visited += 1
        kind = value.get("type")
        if depth > 0 and kind in ("unsupported", "unsupported_ax_value"):
            unsupported[attribute] += 1
            unsupported_types[kind] += 1
            example("unsupported", node_id, attribute, path, type=kind)
        reason = None
        if kind == "unresolved_element_reference":
            reason = "recorded_unresolved"
        elif kind == "element_reference":
            target = value.get("text")
            if target == "outside_collected_tree":
                reason = "outside_collected_tree"
            elif target not in node_ids:
                reason = "missing_captured_node"
        if reason:
            references[attribute] += 1
            reference_reasons[reason] += 1
            example("references", node_id, attribute, path, reason=reason)
        for run_index, run in enumerate(value.get("runs") or []):
            if runs_visited >= max_runs:
                limits_hit.add("run_limit")
                break
            runs_visited += 1
            for name, metadata in (run.get("attributes") or {}).items():
                if run_attributes_visited >= max_run_attributes:
                    limits_hit.add("run_attribute_limit")
                    break
                run_attributes_visited += 1
                if isinstance(metadata, str) and metadata.startswith("[unsupported run attribute:"):
                    placeholders[attribute] += 1
                    run_attribute_names[name] += 1
                    example("placeholders", node_id, attribute,
                            f"{path}.runs[{run_index}].attributes", runAttribute=name)
            if "run_attribute_limit" in limits_hit:
                break
        for index, child in enumerate(value.get("elements") or []):
            visit(child, node_id, attribute, depth + 1, f"{path}.elements[{index}]")
            if visited >= max_values or depth >= max_depth:
                # Reaching a budget exactly is not truncation unless a child was omitted.
                if index + 1 < len(value["elements"]):
                    limits_hit.add("value_limit" if visited >= max_values else "depth_limit")
                break

    for node in nodes:
        for attribute, captured in node.get("attributes", {}).items():
            if captured.get("value") is not None:
                visit(captured["value"], node["id"], attribute)

    def grouped(counter):
        # Stable ordering and bounded output, with an explicit remainder instead of loss.
        ordered = sorted(counter.items(), key=lambda item: (-item[1], item[0]))
        return dict(ordered[:64]), sum(count for _, count in ordered[64:])

    def result(counter, category):
        counts, remainder = grouped(counter)
        return {"count": sum(counter.values()), "byAttribute": counts,
                "otherAttributeCount": remainder, "examples": examples[category]}

    nested = result(unsupported, "unsupported")
    nested["byType"] = dict(sorted(unsupported_types.items()))
    rich = result(placeholders, "placeholders")
    rich["byRunAttribute"], rich["otherRunAttributeCount"] = grouped(run_attribute_names)
    unresolved = result(references, "references")
    unresolved["byReason"] = dict(sorted(reference_reasons.items()))
    return {
        "nestedUnsupportedValues": nested,
        "richTextRunAttributePlaceholders": rich,
        "unresolvedReferenceValues": unresolved,
        "recordedValueInspection": {
            "valuesVisited": visited, "runsVisited": runs_visited,
            "runAttributesVisited": run_attributes_visited,
            "limits": {"values": max_values, "runs": max_runs, "runAttributes": max_run_attributes,
                       "depth": max_depth, "examplesPerCategory": max_examples, "groupsPerCounter": 64},
            "limitHits": sorted(limits_hit), "countsAreLowerBounds": bool(limits_hit),
        },
    }


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
    read_errors = collections.Counter()
    attribute_statuses = collections.Counter()
    partially_resolved = collections.Counter()
    for node in nodes:
        attrs = node.get("attributes", {})
        roles[attrs.get("AXRole", {}).get("value", {}).get("text", "unknown")] += 1
        for name, attribute in attrs.items():
            attribute_statuses[attribute.get("status", "unknown")] += 1
            if attribute.get("status") == "partially_resolved":
                partially_resolved[name] += 1
            if attribute.get("status") in ("read_error", "cannot_complete"):
                read_errors[(name, attribute.get("errorCode"))] += 1
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
    screenshot_path = directory / "screenshot.json"
    screenshot = json.loads(screenshot_path.read_text()) if screenshot_path.exists() else {}
    ocr_path = directory / "ocr.json"
    ocr = json.loads(ocr_path.read_text()) if ocr_path.exists() else {}
    return {
        "captureID": manifest["captureID"],
        "application": manifest["requestedApp"],
        "windowID": manifest["window"]["id"],
        "componentOutcomes": {key: manifest[key] for key in ("accessibility", "screenshot", "ocr")},
        "consistency": manifest["consistency"],
        "axNodes": len(nodes),
        "axCompleteness": ax.get("completeness", "unavailable"),
        "axDurationSeconds": ax.get("durationSeconds"),
        "screenshotPixels": {key: screenshot.get(key) for key in ("pixelWidth", "pixelHeight")},
        "ocrObservations": len(ocr.get("observations", [])),
        "focusRead": ax.get("focusRead"),
        "focusedNodeID": ax.get("focusedNodeID"),
        "roleCounts": dict(roles),
        "valueTypeCounts": dict(types),
        "attributeStatusCounts": dict(sorted(attribute_statuses.items())),
        "partiallyResolvedAttributes": dict(sorted(partially_resolved.items())),
        **inspect_recorded_values(nodes, node_ids),
        "richTextSources": dict(sources),
        "urls": urls,
        "longestTextAttributes": sorted(longest, key=lambda row: row["characters"], reverse=True)[:10],
        "uniqueTextCharacters": sum(map(len, unique_text)),
        "unvisitedReferencedNodes": sorted(unresolved),
        "diagnosticCounts": dict(collections.Counter(d["code"] for d in ax.get("diagnostics", []))),
        "attributeReadErrors": [{"attribute": key[0], "errorCode": key[1], "count": count}
                                for key, count in sorted(read_errors.items())],
        "note": "Only describes stored evidence. Text size, node count and completed reads do not prove whole-document completeness.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture_directory")
    args = parser.parse_args()
    print(json.dumps(summarize(args.capture_directory), ensure_ascii=False, indent=2))
