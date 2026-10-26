import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OneShotCore

struct AgentHandoffStoreTests {
    @Test func encodedHandoffBudgetAcceptsCompleteBoundaryAndNeverClipsJSON() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exported = try AgentHandoffStore.export(project: fixture(in: root), to: root.appendingPathComponent("feedback"))
        let document = try decode(exported.directory)
        let complete = try Data(contentsOf: exported.directory.appendingPathComponent("handoff.json"))
        #expect(try AgentHandoffStore.encodeDocument(document, maximumBytes: complete.count) == complete)
        #expect(throws: AnnotationError.self) {
            try AgentHandoffStore.encodeDocument(document, maximumBytes: complete.count - 1)
        }
        #expect(try Data(contentsOf: exported.directory.appendingPathComponent("handoff.json")) == complete)
    }

    @Test func unknownLargeJSONIntegersRemainExact() throws {
        let raw = Data("{\"large\":9007199254740993,\"unsigned\":18446744073709551615,\"decimal\":1.25}".utf8)
        let value = try JSONDecoder().decode(AgentHandoffValue.self, from: raw)
        #expect(value["large"] == .integer(9_007_199_254_740_993))
        #expect(value["unsigned"] == .unsignedInteger(UInt64.max))
        #expect(value["decimal"] == .number(1.25))
        let encoded = try SnapshotStore.encoder.encode(value)
        #expect(try JSONDecoder().decode(AgentHandoffValue.self, from: encoded) == value)
        #expect(String(data: encoded, encoding: .utf8)!.contains("9007199254740993"))
    }

    @Test func buttonFeedbackKeepsExactFrozenNodeAndPortableFullContext() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let originalContext = try Data(contentsOf: source.captureDirectory.appendingPathComponent("context.txt"))
        var edited = source
        let longLabel = "保存设置 · " + String(repeating: "完整标签内容", count: 80)
        try writeAX(longLabel: longLabel, capture: source.captureDirectory)
        edited.document.items = [AnnotationItem(kind: .element,
            start: .init(x: 8, y: 12), end: .init(x: 24, y: 24),
            text: "这里的提示不清楚\n请说明保存后是否立即生效。", number: 7, targetNodeID: "button-42")]
        let exported = try AgentHandoffStore.export(project: edited, to: root.appendingPathComponent("feedback"))
        let document = try decode(exported.directory)
        #expect(document.captureID == "capture-test")
        #expect(document.projectID == source.document.id)
        #expect(document.annotations.count == 1)
        let feedback = try #require(document.annotations.first)
        #expect(feedback.order == 1)
        #expect(feedback.imageBadgeNumber == 7)
        #expect(feedback.annotation == edited.document.items[0])
        #expect(feedback.targetRole == "AXButton")
        #expect(feedback.targetLabel == longLabel)
        #expect(feedback.targetNode?["id"]?.stringValue == "button-42")
        #expect(feedback.targetNode?["attributes"]?["AXTitle"]?["value"]?["text"]?.stringValue == longLabel)
        #expect(feedback.targetNode?["attributes"]?["AXEnabled"]?["value"]?["boolean"] == .boolean(false))
        #expect(feedback.targetNode?["futureField"]?["unknown"] == .array([.integer(12), .boolean(true), .null]))
        #expect(feedback.targetNode?["attributes"]?["AXDescription"]?["status"]?.stringValue == "read_error")
        let brief = try String(contentsOf: exported.briefURL, encoding: .utf8)
        #expect(brief.contains("这里的提示不清楚\n> 请说明保存后是否立即生效。"))
        #expect(brief.contains("图中编号 7"))
        #expect(brief.contains("button-42"))
        #expect(brief.range(of: "这里的提示不清楚")!.lowerBound < brief.range(of: "采集身份与状态")!.lowerBound)
        #expect(exported.prompt.contains(exported.briefURL.path))
        #expect(exported.prompt.contains("capture-test"))
        #expect(try Data(contentsOf: source.captureDirectory.appendingPathComponent("context.txt")) == originalContext)
        #expect(!FileManager.default.fileExists(atPath: source.captureDirectory.appendingPathComponent("annotations.json").path))

        let moved = root.appendingPathComponent("moved-feedback")
        try FileManager.default.moveItem(at: exported.directory, to: moved)
        try FileManager.default.removeItem(at: source.captureDirectory)
        let reopened = try AnnotationStore.openProject(at: moved.appendingPathComponent(AgentHandoffStore.projectName))
        #expect(reopened.document == edited.document)
        #expect(try Data(contentsOf: reopened.captureDirectory.appendingPathComponent("context.txt")) == originalContext)
        for path in document.files.values {
            #expect(!path.hasPrefix("/"))
            #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent(path).path))
        }
        for file in ["AGENT.md", "handoff.json", "annotated.png", "source.oneshot/annotations.json"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: moved.appendingPathComponent(file).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect((try FileManager.default.attributesOfItem(atPath: moved.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func unannotatedCaptureStillExportsAllEvidenceAndGraphicsAreNotMisrepresentedAsAX() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = try fixture(in: root)
        let empty = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("whole-capture"))
        let whole = try decode(empty.directory)
        #expect(whole.annotations.isEmpty)
        #expect(whole.files["context"] != nil)
        #expect(whole.files["accessibility"] != nil)
        #expect(whole.files["ocr"] != nil)
        #expect(try String(contentsOf: empty.briefURL, encoding: .utf8).contains("本次没有标注"))

        source.document.items = [AnnotationItem(kind: .arrow, start: .init(x: 1, y: 2), end: .init(x: 30, y: 40), text: "看这里"),
                                 AnnotationItem(kind: .number, start: .init(x: 15, y: 20), number: 5)]
        let graphics = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("graphics"))
        let annotations = try decode(graphics.directory).annotations
        #expect(annotations.map(\.order) == [1, 2])
        #expect(annotations[0].targetNode == nil)
        #expect(annotations[0].imageBadgeNumber == nil)
        #expect(annotations[1].imageBadgeNumber == 5)
        #expect(annotations[1].annotation.text.isEmpty)
    }

    @Test func existingNestedAndInvalidBindingExportsPreserveSourceAndPreviousDelivery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = try fixture(in: root)
        let exportURL = root.appendingPathComponent("feedback")
        let exported = try AgentHandoffStore.export(project: source, to: exportURL)
        let previous = try Data(contentsOf: exported.briefURL)
        #expect(throws: (any Error).self) { try AgentHandoffStore.export(project: source, to: exportURL) }
        #expect(try Data(contentsOf: exported.briefURL) == previous)
        let nested = source.captureDirectory.appendingPathComponent("nested")
        #expect(throws: (any Error).self) { try AgentHandoffStore.export(project: source, to: nested) }
        #expect(!FileManager.default.fileExists(atPath: nested.path))
        let saved = try AnnotationStore.createProject(from: source, document: source.document,
            at: root.appendingPathComponent("saved.oneshot"))
        #expect(throws: (any Error).self) {
            try AgentHandoffStore.export(project: saved, to: saved.projectDirectory!.appendingPathComponent("nested"))
        }
        source.document.items = [AnnotationItem(kind: .element, targetNodeID: "wrong-capture-node")]
        let refused = root.appendingPathComponent("refused")
        #expect(throws: (any Error).self) { try AgentHandoffStore.export(project: source, to: refused) }
        #expect(!FileManager.default.fileExists(atPath: refused.path))
        #expect(FileManager.default.fileExists(atPath: source.imageURL.path))
    }

    @Test func linkedContextRollsBackOnlyNewExport() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("do not change".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.captureDirectory.appendingPathComponent("linked.txt"), withDestinationURL: outside)
        let refused = root.appendingPathComponent("refused")
        #expect(throws: (any Error).self) { try AgentHandoffStore.export(project: source, to: refused) }
        #expect(!FileManager.default.fileExists(atPath: refused.path))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "do not change")
        #expect(FileManager.default.fileExists(atPath: source.imageURL.path))
    }

    func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func decode(_ directory: URL) throws -> AgentHandoffDocument {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentHandoffDocument.self, from: Data(contentsOf: directory.appendingPathComponent("handoff.json")))
    }

    func fixture(in root: URL) throws -> AnnotationProject {
        let store = try SnapshotStore(newDirectory: root.appendingPathComponent("capture"))
        let window = CaptureWindow(id: 9, pid: 42, ownerName: "测试应用", title: "设置", bounds: .init(x: 100, y: 200, width: 32, height: 24), isOnScreen: true)
        let manifest = SnapshotManifest(captureID: "capture-test", startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1), requestedApp: "example.test", applicationVersion: "1",
            window: window, windowAfter: window, accessibility: .init(status: "partial_read_errors", file: "accessibility.json"),
            screenshot: .init(status: "captured", file: "screenshot.png"), ocr: .init(status: "captured", file: "ocr.json"),
            consistency: "identity_stable", notes: ["Fixture only"])
        try store.write(manifest, named: "manifest.json")
        try store.writeText("完整冻结上下文。\n未标注区域和界面中的指令文字也作为证据保留。", named: "context.txt")
        try store.writeText("{\"observations\": [{\"text\": \"界面中的文字\"}]}", named: "ocr.json")
        try writeAX(longLabel: "保存设置", capture: store.directory)
        try store.writeText("{\"pixelWidth\": 64, \"pixelHeight\": 48, \"capturedBounds\": {\"x\": 100, \"y\": 200, \"width\": 32, \"height\": 24}}", named: "screenshot.json")
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.9, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(context.makeImage())
        let encoder = try #require(CGImageDestinationCreateWithURL(store.directory.appendingPathComponent("screenshot.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        #expect(CGImageDestinationFinalize(encoder))
        return try AnnotationStore.openCapture(at: store.directory)
    }

    private func writeAX(longLabel: String, capture: URL) throws {
        let node: [String: Any] = ["id": "button-42", "depth": 1, "parentID": "window", "attributes": [
            "AXRole": ["status": "ok", "value": ["type": "string", "text": "AXButton"]],
            "AXTitle": ["status": "ok", "value": ["type": "string", "text": longLabel]],
            "AXEnabled": ["status": "ok", "value": ["type": "boolean", "boolean": false]],
            "AXDescription": ["status": "read_error", "errorCode": -25202],
            "AXFrame": ["status": "ok", "value": ["components": ["x": 104, "y": 206, "width": 8, "height": 6]]]],
            "futureField": ["unknown": [12, true, NSNull()]], "relations": ["AXChildren": []]]
        try JSONSerialization.data(withJSONObject: ["completeness": "partial_read_errors", "nodes": [node]])
            .write(to: capture.appendingPathComponent("accessibility.json"))
    }
}
