import AppKit
import ApplicationServices
import Testing
@testable import OneShotCore

struct AXWindowMatchingTests {
    private let bounds = CGRect(x: 1512, y: -892, width: 1867, height: 1055)

    @Test func uniqueGeometryAcceptsProviderSpecificTitlesWithoutBrowserRules() {
        let titles = [
            ("YTwsy - Microsoft Edge", "YTwsy"),
            ("【任务认领】测试项目：快速通用交互和浏览器采集验证 · example/repository - Microsoft Edge",
             "【任务认领】测试项目：快速通用… · example/repository"),
            ("Document — Editor", "Document"),
            ("Document (modified)", "Document"),
            ("完全不同的应用显示标题", "Window"),
            ("", "Window")
        ]
        for (actual, expected) in titles {
            let result = AXCollector.assessWindowMatches([window(actual)], title: expected, bounds: bounds)
            #expect(result.uniqueMatchIndex == 0)
            #expect(result.cannotExclude.isEmpty)
        }
    }

    @Test func unavailableOrIncompleteTitlesDoNotInvalidateUniqueGeometry() {
        let candidate = window("Document")
        var failed = candidate
        failed.title = unavailable()
        var truncated = candidate
        truncated.title.value?.truncated = true
        var malformed = candidate
        malformed.title.value = AXSnapshotValue(type: "boolean", boolean: true)
        for entry in [failed, truncated, malformed] {
            #expect(AXCollector.assessWindowMatches([entry], title: "Document", bounds: bounds).uniqueMatchIndex == 0)
        }
        #expect(AXCollector.assessWindowMatches([candidate], title: nil, bounds: bounds).uniqueMatchIndex == 0)
    }

    @Test func overlappingGeometryRemainsAmbiguousRegardlessOfTitles() {
        let exact = window("Document"), different = window("Different title")
        var unknown = window("Unread title")
        unknown.title = unavailable()
        let result = AXCollector.assessWindowMatches([exact, different, unknown], title: "Document", bounds: bounds)
        #expect(result.matches == [0, 1, 2])
        #expect(result.cannotExclude.isEmpty)
        #expect(result.uniqueMatchIndex == nil)
    }

    @Test func unknownGeometryCannotBeExcludedByADifferentKnownTitle() {
        let target = window("Document")
        for field in ["position", "size"] {
            var other = window("Different title")
            if field == "position" { other.position = unavailable() }
            else { other.size = unavailable() }
            let result = AXCollector.assessWindowMatches([target, other], title: "Document", bounds: bounds)
            #expect(result.matches == [0])
            #expect(result.cannotExclude == [1])
            #expect(result.uniqueMatchIndex == nil)
        }
    }

    @Test func knownDifferentGeometryCanExcludeAnOtherwiseUnknownCandidate() {
        let target = window("Document")
        var other = window("Different title")
        other.position = unavailable()
        other.size.value?.components?["width"] = bounds.width + 100
        let result = AXCollector.assessWindowMatches([target, other], title: "Document", bounds: bounds)
        #expect(result.uniqueMatchIndex == 0)
        #expect(result.cannotExclude.isEmpty)
        // Invalid dimensions are unknown, rather than evidence of a different window.
        other.size.value?.components?["width"] = -1
        let invalid = AXCollector.assessWindowMatches([target, other], title: "Document", bounds: bounds)
        #expect(invalid.cannotExclude == [1])
        #expect(invalid.uniqueMatchIndex == nil)
    }

    @Test func invalidExpectedGeometryCannotFallBackToTitle() {
        for expected in [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 10),
                         CGRect(x: Double.nan, y: 0, width: 10, height: 10),
                         CGRect(x: 0, y: 0, width: Double.infinity, height: 10)] {
            let result = AXCollector.assessWindowMatches([window("Document")], title: "Document", bounds: expected)
            #expect(result.uniqueMatchIndex == nil)
            #expect(result.cannotExclude == [0])
        }
    }

    @Test func rawGeometryMustBeCompleteFinitePositiveAndNotTruncated() {
        let candidate = window("Document")
        for field in ["x", "y", "width", "height"] {
            var incomplete = candidate
            if field == "x" || field == "y" { incomplete.position.value?.components?.removeValue(forKey: field) }
            else { incomplete.size.value?.components?.removeValue(forKey: field) }
            // A stale derived bounds value cannot replace a missing raw component.
            #expect(incomplete.bounds == bounds)
            let result = AXCollector.assessWindowMatches([incomplete], title: "Document", bounds: bounds)
            #expect(result.uniqueMatchIndex == nil)
            #expect(result.cannotExclude == [0])
        }
        var truncated = candidate
        truncated.size.value?.truncated = true
        var nonfinite = candidate
        nonfinite.position.value?.components?["x"] = .infinity
        var malformed = candidate
        malformed.position.value?.type = "size"
        for invalid in [truncated, nonfinite, malformed] {
            let result = AXCollector.assessWindowMatches([invalid], title: "Document", bounds: bounds)
            #expect(result.uniqueMatchIndex == nil)
            #expect(result.cannotExclude == [0])
        }
        // Zero width must not pass merely because it falls inside the 3-point tolerance.
        let small = CGRect(x: 0, y: 0, width: 1, height: 1)
        var zeroWidth = window("Document", rect: small)
        zeroWidth.size.value?.components?["width"] = 0
        #expect(AXCollector.assessWindowMatches([zeroWidth], title: "Document", bounds: small).uniqueMatchIndex == nil)
    }

    @Test func geometryToleranceAppliesToEveryRequestedComponent() {
        let near = window("Different title", rect: CGRect(x: bounds.minX + 3, y: bounds.minY - 3,
            width: bounds.width + 3, height: bounds.height - 3))
        #expect(AXCollector.assessWindowMatches([near], title: "Document", bounds: bounds).uniqueMatchIndex == 0)
        for field in ["x", "y", "width", "height"] {
            var outside = window("Document")
            if field == "x" || field == "y" { outside.position.value?.components?[field]? += 3.01 }
            else { outside.size.value?.components?[field]? += 3.01 }
            let result = AXCollector.assessWindowMatches([outside], title: "Document", bounds: bounds)
            #expect(result.matches.isEmpty)
            #expect(result.cannotExclude.isEmpty)
        }
    }

    @Test func titleOnlyMatchingRetainsMeaningfulExactMatchingWithoutBounds() {
        let target = window("Document")
        #expect(AXCollector.assessWindowMatches([target], title: "Document", bounds: nil).uniqueMatchIndex == 0)
        #expect(AXCollector.assessWindowMatches([target], title: "Doc…ent", bounds: nil).uniqueMatchIndex == nil)
        #expect(AXCollector.assessWindowMatches([window("Document - Editor")], title: "Document", bounds: nil).uniqueMatchIndex == nil)
        for title in [nil, "", " \n "] {
            #expect(AXCollector.assessWindowMatches([window("")], title: title, bounds: nil).uniqueMatchIndex == nil)
        }
        var unknown = target
        unknown.title = unavailable()
        let ambiguous = AXCollector.assessWindowMatches([target, unknown], title: "Document", bounds: nil)
        #expect(ambiguous.matches == [0])
        #expect(ambiguous.cannotExclude == [1])
        #expect(ambiguous.uniqueMatchIndex == nil)
    }

    private func unavailable() -> AXCapturedAttribute {
        AXCapturedAttribute(status: "cannot_complete", value: nil, settable: nil,
            errorCode: Int(AXError.cannotComplete.rawValue), note: nil)
    }

    private func window(_ title: String, rect: CGRect? = nil) -> AXWindowDiagnostic {
        let rect = rect ?? bounds
        func attribute(_ value: AXSnapshotValue) -> AXCapturedAttribute {
            AXCapturedAttribute(status: "ok", value: value, settable: nil, errorCode: nil, note: nil)
        }
        return AXWindowDiagnostic(index: 0, title: attribute(AXSnapshotValue(type: "string", text: title)),
            position: attribute(AXSnapshotValue(type: "point", components: ["x": rect.origin.x, "y": rect.origin.y])),
            size: attribute(AXSnapshotValue(type: "size", components: ["width": rect.width, "height": rect.height])),
            bounds: rect)
    }
}
