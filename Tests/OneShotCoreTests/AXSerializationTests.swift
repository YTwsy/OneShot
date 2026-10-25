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
}
