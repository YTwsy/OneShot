#!/usr/bin/env python3
"""Offline regression tests; creates no app process and reads no live AX state."""
import json
from pathlib import Path
import tempfile
import unittest

from summarize_capture import inspect_recorded_values, summarize


def captured(value=None, status="ok", **fields):
    return {"status": status, "value": value, **fields}


def fixture_nodes():
    return [{"id": "n1", "attributes": {
        "AXRole": captured({"type": "string", "text": "AXWindow"}),
        "AXSections": captured({"type": "array", "elements": [
            {"type": "unsupported"},
            {"type": "array", "elements": [
                {"type": "unsupported_ax_value"}, {"type": "opaque"},
                {"type": "string", "text": "[unsupported run attribute: ordinary body text]"}]}]}),
        "AXTopLevelUnsupported": captured({"type": "unsupported"}, "unsupported_value_type"),
        "AXAbsent": captured(status="no_value"),
        "AXMarker": captured({"type": "opaque"}, "nonserializable"),
        "AXFailure": captured(status="read_error", errorCode=-25200),
        "AXBusy": captured(status="cannot_complete", errorCode=-25204),
        "AXRich": captured({"type": "attributed_text", "text": "body", "runs": [
            {"attributes": {"AXFont": "[unsupported run attribute: Dictionary]", "AXLink": "https://example.org"}},
            {"attributes": {"AXFont": "[unsupported run attribute: Dictionary]"}}]}),
        "AXLinkedUIElements": captured({"type": "element_references", "elements": [
            {"type": "element_reference", "text": "n2"},
            {"type": "unresolved_element_reference", "text": "not_in_captured_window_tree"},
            {"type": "element_reference", "text": "outside_collected_tree"},
            {"type": "element_reference", "text": "n999"}]}, "partially_resolved"),
    }, "relations": {"AXLinkedUIElements": ["n2", "n999"]}},
        {"id": "n2", "attributes": {"AXRole": captured({"type": "string", "text": "AXButton"})}}]


class SummaryTests(unittest.TestCase):
    def test_nested_limits_and_statuses_are_separate_and_stable(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            manifest = {"captureID": "fixture", "requestedApp": "Fixture", "window": {"id": 1},
                        "accessibility": {}, "screenshot": {}, "ocr": {}, "consistency": {}}
            (directory / "manifest.json").write_text(json.dumps(manifest))
            (directory / "accessibility.json").write_text(json.dumps({"nodes": fixture_nodes()}))
            result = summarize(directory)
            self.assertEqual(result, summarize(directory))
        self.assertEqual(result["nestedUnsupportedValues"]["count"], 2)
        self.assertEqual(result["nestedUnsupportedValues"]["byAttribute"], {"AXSections": 2})
        self.assertEqual(result["richTextRunAttributePlaceholders"]["count"], 2)
        self.assertEqual(result["richTextRunAttributePlaceholders"]["byRunAttribute"], {"AXFont": 2})
        self.assertEqual(result["unresolvedReferenceValues"]["count"], 3)
        self.assertEqual(result["partiallyResolvedAttributes"], {"AXLinkedUIElements": 1})
        self.assertEqual(result["unvisitedReferencedNodes"], ["n999"])
        self.assertEqual(result["attributeStatusCounts"]["no_value"], 1)
        self.assertEqual(result["attributeStatusCounts"]["nonserializable"], 1)
        self.assertEqual(result["valueTypeCounts"]["unsupported"], 1)
        self.assertEqual({error["attribute"] for error in result["attributeReadErrors"]}, {"AXFailure", "AXBusy"})
        self.assertFalse(result["recordedValueInspection"]["countsAreLowerBounds"])

    def test_scan_limits_are_explicit_and_exact_budget_is_not_a_failure(self):
        value = {"type": "array", "elements": [{"type": "unsupported"}, {"type": "unsupported"}]}
        nodes = [{"id": "n1", "attributes": {"AXSections": captured(value)}}]
        limited = inspect_recorded_values(nodes, {"n1"}, max_values=2)
        self.assertEqual(limited["nestedUnsupportedValues"]["count"], 1)
        self.assertEqual(limited["recordedValueInspection"]["limitHits"], ["value_limit"])
        self.assertEqual(inspect_recorded_values(nodes, {"n1"}, max_depth=0)["recordedValueInspection"]["limitHits"], ["depth_limit"])
        exact = inspect_recorded_values(nodes, {"n1"}, max_values=3, max_examples=1)
        self.assertFalse(exact["recordedValueInspection"]["countsAreLowerBounds"])
        self.assertEqual(len(exact["nestedUnsupportedValues"]["examples"]), 1)
        limited_runs = inspect_recorded_values(fixture_nodes(), {"n1", "n2"}, max_run_attributes=1)
        self.assertEqual(limited_runs["richTextRunAttributePlaceholders"]["count"], 1)
        self.assertEqual(limited_runs["recordedValueInspection"]["limitHits"], ["run_attribute_limit"])
        self.assertEqual(inspect_recorded_values(fixture_nodes(), {"n1", "n2"}, max_runs=0)["recordedValueInspection"]["limitHits"], ["run_limit"])


if __name__ == "__main__":
    unittest.main()
