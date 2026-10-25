import AppKit
import ApplicationServices
import Testing
@testable import OneShotCore

struct AXSerializationTests {
    @Test func booleanIntegerFloatAndRangeRemainDifferentTypes() throws {
        let collector = AXCollector()
        let boolean = collector.serializeValue(kCFBooleanTrue, node: "n1", attribute: "AXSelected")
        let integer = collector.serializeValue(NSNumber(value: 1), node: "n1", attribute: "AXValue")
        let float = collector.serializeValue(NSNumber(value: 0.5), node: "n2", attribute: "AXValue")
        var selection = CFRange(location: 3, length: 5)
        let range = collector.serializeValue(try #require(AXValueCreate(.cfRange, &selection)), node: "n3", attribute: "AXSelectedTextRange")
        #expect(boolean.type == "boolean")
        #expect(boolean.boolean == true)
        #expect(integer.type == "integer")
        #expect(float.type == "float")
        #expect(range.type == "range")
        #expect(range.components?["location"] == 3)
        #expect(range.components?["length"] == 5)
    }

    @Test func richChineseTextKeepsUTF16RangesAndSurvivesJSON() throws {
        let collector = AXCollector()
        let text = "节点🧭：完整正文"
        let rich = NSAttributedString(string: text, attributes: [.link: URL(string: "https://example.org/node")!])
        let value = collector.serializeValue(rich, node: "n1", attribute: "AXAttributedStringForTextMarkerRange")
        #expect(value.type == "attributed_text")
        #expect(value.text == text)
        #expect(value.runs?.first?.length == text.utf16.count)
        #expect(value.runs?.first?.attributes[NSAttributedString.Key.link.rawValue] == "https://example.org/node")
        let restored = try JSONDecoder().decode(AXSnapshotValue.self, from: SnapshotStore.encoder.encode(value))
        #expect(restored.text == text)
        #expect(restored.runs?.first?.length == text.utf16.count)
    }

    @Test func perAttributeAndTotalBudgetsAreExplicitWithoutSplittingUnicode() {
        let collector = AXCollector(options: AXCaptureOptions(maxTextCharacters: 4, maxTotalTextCharacters: 6))
        let first = collector.serializeValue("甲乙🧭丁戊" as CFString, node: "n1", attribute: "AXValue")
        let second = collector.serializeValue("后续正文" as CFString, node: "n2", attribute: "AXValue")
        #expect(first.text == "甲乙🧭丁")
        #expect(first.originalCharacterCount == 5)
        #expect(first.truncated == true)
        #expect(second.text == "后续")
        #expect(second.originalCharacterCount == 4)
        #expect(second.truncated == true)
    }

    @Test func knownTextMarkerHandlesAreNonserializableWithoutContentFailure() throws {
        let collector = AXCollector()
        // Data stands in for a provider-owned CF handle; no private AX marker constructors
        // or live application are required to verify persistence policy.
        let opaque = Data([0xAA, 0xBB, 0xCC]) as CFData
        for attribute in ["AXStartTextMarker", "AXEndTextMarker", "AXSelectedTextMarkerRange"] {
            let value = collector.captured(opaque, node: "n1", attribute: attribute)
            #expect(value.status == "nonserializable")
            #expect(value.value?.type == "opaque")
            #expect(value.value?.text == "provider_owned_text_marker")
            let encoded = try SnapshotStore.encoder.encode(value)
            #expect(String(decoding: encoded, as: UTF8.self).contains("CFTypeID") == false)
        }
        #expect(collector.readErrors == false)
        #expect(collector.diagnostics.isEmpty)
        let unknown = collector.captured(opaque, node: "n1", attribute: "AXUnexpectedPayload")
        #expect(unknown.status == "unsupported_value_type")
        #expect(collector.readErrors)
        #expect(collector.diagnostics.last?.code == "unsupported_value_type")
    }

    @Test func knownMarkerAttributeDoesNotHideAnActualAXReadError() throws {
        let collector = AXCollector()
        var error = AXError.cannotComplete
        let errorValue = try #require(AXValueCreate(.axError, &error))
        let attribute = collector.captured(errorValue, node: "n1", attribute: "AXStartTextMarker")
        #expect(attribute.status == "cannot_complete")
        #expect(attribute.errorCode == Int(AXError.cannotComplete.rawValue))
        #expect(collector.readErrors)
    }

    @Test func windowInspectionDistinguishesEmptyInventoryFromFailedMetadataAndRedactsTitles() throws {
        let ok = AXCapturedAttribute(status: "ok", value: nil, settable: nil, errorCode: 0, note: nil)
        var empty = AXApplicationDiagnosticResult(pid: 1, observedAt: Date(), accessibilityTrusted: true,
            attributeNamesRead: ok, availableAttributes: [], windowsRead: ok, windowEntryCount: 0,
            validWindowCount: 0, candidates: [], accessibilityFeatures: [:])
        #expect(AXCollector.shouldRetryWindowInspection(empty))
        #expect(empty.summary.contains("entries=0"))
        #expect(empty.summary.contains("validCandidates=0"))
        let secretTitle = AXCapturedAttribute(status: "ok", value: AXSnapshotValue(type: "string", text: "private-document-name"), settable: nil, errorCode: nil, note: nil)
        let failed = AXCapturedAttribute(status: "cannot_complete", value: nil, settable: nil,
            errorCode: Int(AXError.cannotComplete.rawValue), note: nil)
        empty.windowEntryCount = 1; empty.validWindowCount = 1
        empty.candidates = [AXWindowDiagnostic(index: 0, title: secretTitle, position: failed, size: ok, bounds: nil)]
        #expect(AXCollector.shouldRetryWindowInspection(empty))
        #expect(empty.summary.contains("position=cannot_complete"))
        #expect(empty.summary.contains("private-document-name") == false)
        empty.candidates[0].position = ok
        #expect(AXCollector.shouldRetryWindowInspection(empty) == false)
        empty.windowsRead = AXCapturedAttribute(status: "api_disabled", value: nil, settable: nil,
            errorCode: Int(AXError.apiDisabled.rawValue), note: nil)
        #expect(AXCollector.shouldRetryWindowInspection(empty) == false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(AXApplicationDiagnosticResult.self, from: SnapshotStore.encoder.encode(empty))
        #expect(restored.validWindowCount == 1)
        #expect(restored.windowsRead.status == "api_disabled")
    }

    @Test func overlappingUnknownWindowPreventsUniqueMatch() {
        let target = windowCandidate(title: "Document")
        let failed = AXCapturedAttribute(status: "cannot_complete", value: nil, settable: nil,
            errorCode: Int(AXError.cannotComplete.rawValue), note: nil)
        for unreadAttribute in ["title", "position", "size"] {
            var unknown = target
            switch unreadAttribute {
            case "title": unknown.title = failed
            case "position": unknown.position = failed
            default: unknown.size = failed
            }
            let assessment = AXCollector.assessWindowMatches([target, unknown], title: "Document", bounds: target.bounds)
            #expect(assessment.matches == [0])
            #expect(assessment.cannotExclude == [1])
            #expect(assessment.uniqueMatchIndex == nil)
        }
    }

    @Test func differentKnownTitleExcludesWindowWithUnreadBounds() {
        let target = windowCandidate(title: "Document")
        var other = windowCandidate(title: "Different document")
        other.position.status = "cannot_complete"
        other.size.status = "cannot_complete"
        other.bounds = nil
        let assessment = AXCollector.assessWindowMatches([target, other], title: "Document", bounds: target.bounds)
        #expect(assessment.matches == [0])
        #expect(assessment.cannotExclude.isEmpty)
        #expect(assessment.uniqueMatchIndex == 0)
    }

    @Test func differentKnownBoundsExcludeWindowWithUnreadTitle() {
        let target = windowCandidate(title: "Document")
        var other = windowCandidate(title: "Document", bounds: CGRect(x: 800, y: 20, width: 640, height: 480))
        other.title.status = "cannot_complete"
        // A known different position still excludes the window when size is also unreadable.
        other.size.status = "cannot_complete"
        other.bounds = nil
        let assessment = AXCollector.assessWindowMatches([target, other], title: "Document", bounds: target.bounds)
        #expect(assessment.matches == [0])
        #expect(assessment.cannotExclude.isEmpty)
        #expect(assessment.uniqueMatchIndex == 0)
    }

    private func windowCandidate(title: String, bounds: CGRect = CGRect(x: 10, y: 20, width: 640, height: 480)) -> AXWindowDiagnostic {
        func attribute(_ value: AXSnapshotValue) -> AXCapturedAttribute {
            AXCapturedAttribute(status: "ok", value: value, settable: nil, errorCode: nil, note: nil)
        }
        return AXWindowDiagnostic(index: 0, title: attribute(AXSnapshotValue(type: "string", text: title)),
            position: attribute(AXSnapshotValue(type: "point", components: ["x": bounds.origin.x, "y": bounds.origin.y])),
            size: attribute(AXSnapshotValue(type: "size", components: ["width": bounds.width, "height": bounds.height])),
            bounds: bounds)
    }
}
