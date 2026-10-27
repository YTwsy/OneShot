import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import OneShotCore

struct OneShotMCPServerTests {
    @Test func annotationPreviewsBoundUTF8BytesWithoutChangingFullChineseAndCombiningText() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = try fixture.fixture(in: root)
        let note = "中文说明：e" + String(repeating: "\u{301}", count: 1_000)
        let label = "中文控件：e" + String(repeating: "\u{301}", count: 700)
        let role = String(repeating: "AXButton", count: 50)
        let axURL = source.captureDirectory.appendingPathComponent("accessibility.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: axURL)) as? [String: Any])
        var nodes = try #require(raw["nodes"] as? [[String: Any]])
        var attributes = try #require(nodes[0]["attributes"] as? [String: Any])
        attributes["AXTitle"] = ["status": "ok", "value": ["type": "string", "text": label]]
        attributes["AXRole"] = ["status": "ok", "value": ["type": "string", "text": role]]
        nodes[0]["attributes"] = attributes; raw["nodes"] = nodes
        try JSONSerialization.data(withJSONObject: raw).write(to: axURL)
        source.document.items = [AnnotationItem(kind: .element, start: .init(x: 8, y: 12),
            end: .init(x: 24, y: 24), text: note, targetNodeID: "button-42")]
        let exported = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("handoff"))
        let reader = try ReadonlyHandoffReader(directory: exported.directory)
        let rows = try #require(reader.readAnnotations()["annotations"] as? [[String: Any]])
        let summary = rows[0]
        #expect((summary["userNote"] as? String)?.utf8.count ?? Int.max <= 1_600)
        #expect((summary["targetLabel"] as? String)?.utf8.count ?? Int.max <= 640)
        #expect((summary["targetRole"] as? String)?.utf8.count ?? Int.max <= 256)
        #expect(summary["userNoteTruncated"] as? Bool == true)
        #expect(summary["targetLabelTruncated"] as? Bool == true)
        #expect(summary["targetRoleTruncated"] as? Bool == true)
        #expect((summary["userNote"] as? String)?.hasPrefix("中文说明") == true)
        let page = try reader.readAnnotation(order: 1, limit: 65_536)
        #expect(!page.hasMore)
        let full = try JSONDecoder().decode(AgentHandoffAnnotation.self, from: Data(page.text.utf8))
        #expect(full.annotation.text == note)
        #expect(full.targetLabel == label)
        #expect(full.targetRole == role)
        #expect(full.targetNode?["attributes"]?["AXTitle"]?["value"]?["text"]?.stringValue == label)
    }

    @Test func annotationPagingSwitchesTargetsAndStillRejectsChangedMaterialAfterCaching() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = try fixture.fixture(in: root)
        source.document.items = [AnnotationItem(kind: .element, start: .init(x: 8, y: 12),
            end: .init(x: 24, y: 24), text: "按钮说明", targetNodeID: "button-42"),
            AnnotationItem(kind: .rectangle, start: .init(x: 1, y: 2), end: .init(x: 30, y: 40), text: "方框说明")]
        let exported = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("handoff"))
        let reader = try ReadonlyHandoffReader(directory: exported.directory)
        let first = try reader.readAnnotation(order: 1, limit: 65_536)
        let second = try reader.readAnnotation(order: 2, limit: 65_536)
        let secondEntry = try JSONDecoder().decode(AgentHandoffAnnotation.self, from: Data(second.text.utf8))
        #expect(secondEntry.annotation.text == "方框说明")
        #expect(secondEntry.targetNode == nil)
        #expect(try reader.readAnnotation(order: 1, limit: 65_536).text == first.text)
        let handoffURL = exported.directory.appendingPathComponent("handoff.json")
        var changed = try Data(contentsOf: handoffURL); changed.append(10)
        try changed.write(to: handoffURL)
        #expect(throws: HandoffReadError.self) { try reader.readAnnotation(order: 1, limit: 65_536) }
    }

    @Test func lifecycleAndReadonlyToolsExposeOnlyTheChosenHandoff() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = try fixture.fixture(in: root)
        source.document.items = [AnnotationItem(kind: .element,
            start: .init(x: 8, y: 12), end: .init(x: 24, y: 24),
            text: "这里的提示不清楚\n请解释后果。", number: 8, targetNodeID: "button-42")]
        let exported = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("handoff"))
        let reader = try ReadonlyHandoffReader(directory: exported.directory)
        let server = OneShotMCPServer(reader: reader)
        let tooEarly = try request(server, method: "tools/list")
        #expect((tooEarly["error"] as? [String: Any])?["code"] as? Int == -32002)
        let initialized = try request(server, method: "initialize", params: initialization(version: "2024-11-05"))
        #expect((initialized["result"] as? [String: Any])?["protocolVersion"] as? String == "2024-11-05")
        #expect(server.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])) == nil)
        let tools = try request(server, method: "tools/list")
        let names = try #require(((tools["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String })
        #expect(Set(names) == ["read_brief", "read_annotations", "read_annotation", "read_feedbacks", "read_feedback", "read_context", "read_image"])
        let brief = try call(server, name: "read_brief")
        #expect(try textObject(brief)["text"] as? String == reader.readBrief().text)
        #expect(try textObject(brief)["captureID"] as? String == "capture-test")
        let annotations = try textObject(call(server, name: "read_annotations"))
        let rows = try #require(annotations["annotations"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["targetNodeID"] as? String == "button-42")
        #expect(rows[0]["userNote"] as? String == source.document.items[0].text)
        let image = try call(server, name: "read_image", arguments: ["variant": "raw"])
        let block = try #require((image["content"] as? [[String: Any]])?.first)
        #expect(block["type"] as? String == "image")
        #expect(block["mimeType"] as? String == "image/png")
        let base64 = try #require(block["data"] as? String)
        let imageData = try #require(Data(base64Encoded: base64))
        #expect(try imageData == Data(contentsOf: source.imageURL))
    }

    @Test func utf8PagingReassemblesCompleteChineseContextAndFullBoundNode() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = try fixture.fixture(in: root)
        let complete = "中文🙂长上下文\n" + String(repeating: "第二段 🧭 " , count: 50)
        try Data(complete.utf8).write(to: source.captureDirectory.appendingPathComponent("context.txt"))
        source.document.items = [AnnotationItem(kind: .element, start: .init(x: 8, y: 12), end: .init(x: 24, y: 24),
            text: String(repeating: "说明🙂\n", count: 120), targetNodeID: "button-42")]
        let exported = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("handoff"))
        let reader = try ReadonlyHandoffReader(directory: exported.directory)
        var context = "", next = 0
        repeat {
            let page = try reader.readContext(offset: next, limit: 7)
            context += page.text; next = page.nextOffset
            #expect(page.nextOffset > page.offset || !page.hasMore)
            if !page.hasMore { break }
        } while true
        #expect(context == complete)
        #expect(next == complete.utf8.count)
        #expect(throws: HandoffReadError.self) { try reader.readContext(offset: 1, limit: 7) }
        #expect(throws: HandoffReadError.self) { try reader.readContext(offset: 0, limit: 3) }
        var json = ""; next = 0
        repeat {
            let page = try reader.readAnnotation(order: 1, offset: next, limit: 17)
            json += page.text; next = page.nextOffset
            if !page.hasMore { break }
        } while true
        let full = try JSONDecoder().decode(AgentHandoffAnnotation.self, from: Data(json.utf8))
        #expect(full.annotation.text == source.document.items[0].text)
        #expect(full.targetNode?["id"]?.stringValue == "button-42")
        #expect(full.targetNode?["attributes"]?["AXEnabled"]?["value"]?["boolean"] == .boolean(false))
    }

    @Test func untrustedPathsAndSymlinksCannotExtendTheSelectedMaterial() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture.fixture(in: root)
        let exported = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("handoff"))
        let outside = root.appendingPathComponent("outside.txt")
        try Data("private outside content".utf8).write(to: outside)
        let path = exported.directory.appendingPathComponent("handoff.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var fileIndex = try #require(json["files"] as? [String: String])
        fileIndex["context"] = outside.path; json["files"] = fileIndex
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        let reader = try ReadonlyHandoffReader(directory: exported.directory)
        #expect(try reader.readContext().text.contains("完整冻结上下文"))
        #expect(try !reader.readContext().text.contains("private outside content"))
        let rootLink = root.appendingPathComponent("linked-handoff")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: exported.directory)
        #expect(throws: (any Error).self) { try ReadonlyHandoffReader(directory: rootLink) }
        let capture = exported.directory.appendingPathComponent("source.oneshot/capture")
        let context = capture.appendingPathComponent("context.txt")
        try FileManager.default.removeItem(at: context)
        try FileManager.default.createSymbolicLink(at: context, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try ReadonlyHandoffReader(directory: exported.directory) }
        #expect(throws: HandoffReadError.self) { try reader.readContext() }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "private outside content")
    }

    @Test func protocolErrorsAreBoundedAndNeverInvokeWritesOrArbitraryPaths() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exported = try AgentHandoffStore.export(project: fixture.fixture(in: root), to: root.appendingPathComponent("handoff"))
        let server = OneShotMCPServer(reader: try ReadonlyHandoffReader(directory: exported.directory))
        let malformed = try #require(server.handle(Data("{".utf8)))
        #expect((try JSONSerialization.jsonObject(with: malformed) as? [String: Any])?["error"] != nil)
        let initialized = try request(server, method: "initialize", params: initialization(version: "2099-01-01"))
        #expect((initialized["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        _ = server.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        for (name, args) in [("capture", [:]), ("read_context", ["path": "/etc/passwd"]),
                             ("read_context", ["source": "../outside.txt"]), ("read_image", ["variant": "/etc/passwd"]),
                             ("read_brief", ["offset": true]), ("read_brief", ["offset": 0.5])] as [(String, [String: Any])] {
            let response = try request(server, method: "tools/call", params: ["name": name, "arguments": args])
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
        let unknown = try request(server, method: "resources/read", params: ["uri": "file:///etc/passwd"])
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(server.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "tools/call", "params": ["name": "capture"]])) == nil)
    }

    @Test func staleManifestAndTargetNodeSummariesAreRejected() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = try fixture.fixture(in: root)
        source.document.items = [AnnotationItem(kind: .element, start: .init(x: 8, y: 12),
            end: .init(x: 24, y: 24), text: "这个按钮", targetNodeID: "button-42")]
        let exported = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("handoff"))
        let path = exported.directory.appendingPathComponent("handoff.json")
        let original = try Data(contentsOf: path)
        let base = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var staleManifest = base
        var capture = try #require(staleManifest["capture"] as? [String: Any])
        capture["requestedApp"] = "example.other-app"
        staleManifest["capture"] = capture
        try JSONSerialization.data(withJSONObject: staleManifest).write(to: path)
        #expect(throws: (any Error).self) { try ReadonlyHandoffReader(directory: exported.directory) }
        var staleNode = base
        var entries = try #require(staleNode["annotations"] as? [[String: Any]])
        var node = try #require(entries[0]["targetNode"] as? [String: Any])
        node["id"] = "wrong-button"
        entries[0]["targetNode"] = node
        staleNode["annotations"] = entries
        try JSONSerialization.data(withJSONObject: staleNode).write(to: path)
        #expect(throws: (any Error).self) { try ReadonlyHandoffReader(directory: exported.directory) }
        try original.write(to: path)
        #expect(try ReadonlyHandoffReader(directory: exported.directory).readAnnotations()["totalAnnotations"] as? Int == 1)
    }

    @Test func feedbackMCPReassemblesOrderedMultiControlReferencesAndGlobalFeedback() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try feedbackFixture(in: root)
        let exported = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("feedback-handoff"))
        let reader = try ReadonlyHandoffReader(directory: exported.directory)
        let server = OneShotMCPServer(reader: reader)
        _ = try request(server, method: "initialize", params: initialization(version: "2025-06-18"))
        _ = server.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let index = try textObject(call(server, name: "read_feedbacks", arguments: ["limit": 1]))
        #expect(index["totalFeedbacks"] as? Int == 2)
        #expect(index["nextOffset"] as? Int == 1)
        #expect(index["hasMore"] as? Bool == true)
        let row = try #require((index["feedbacks"] as? [[String: Any]])?.first)
        #expect(row["feedbackID"] as? String == source.document.feedbacks[0].id.uuidString)
        #expect((row["userNote"] as? String)?.utf8.count ?? Int.max <= 1_600)
        #expect(row["userNoteTruncated"] as? Bool == true)
        let references = try #require(row["references"] as? [[String: Any]])
        #expect(references.compactMap { $0["nodeID"] as? String } == ["button-42", "second-button", "button-42"])
        #expect(references.compactMap { $0["reference"] as? String } == ["R1", "R2", "R1"])
        var json = "", next = 0
        repeat {
            let result = try textObject(call(server, name: "read_feedback", arguments: ["order": 1, "offset": next, "limit": 53]))
            json += try #require(result["text"] as? String)
            next = try #require(result["nextOffset"] as? Int)
            if result["hasMore"] as? Bool == false { break }
        } while true
        let full = try JSONDecoder().decode(AgentHandoffFeedback.self, from: Data(json.utf8))
        #expect(full.feedback == source.document.feedbacks[0])
        #expect(full.references.map(\.reference) == source.document.feedbacks[0].controlReferences)
        #expect(full.references.map { $0.targetNode?["id"]?.stringValue } == ["button-42", "second-button", "button-42"])
        #expect(full.references[0].targetNode?["attributes"]?["AXEnabled"]?["value"]?["boolean"] == .boolean(false))
        #expect(try reader.readFeedback(id: full.feedback.id, limit: 65_536).source == "feedback:1")
        let second = try JSONDecoder().decode(AgentHandoffFeedback.self,
            from: Data(reader.readFeedback(order: 2, limit: 65_536).text.utf8))
        #expect(second.feedback == source.document.feedbacks[1])
        #expect(second.references.isEmpty)
        #expect(try reader.readAnnotations()["totalFeedbacks"] as? Int == 2)
    }

    @Test func feedbackReaderRejectsTamperedReferenceAndStaleCachedData() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exported = try AgentHandoffStore.export(project: feedbackFixture(in: root), to: root.appendingPathComponent("feedback-handoff"))
        let path = exported.directory.appendingPathComponent("handoff.json")
        let original = try Data(contentsOf: path)
        let reader = try ReadonlyHandoffReader(directory: exported.directory)
        _ = try reader.readFeedback(order: 1, limit: 65_536)
        _ = try reader.readFeedback(order: 2, limit: 65_536)
        var base = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var feedbacks = try #require(base["feedbacks"] as? [[String: Any]])
        var bindings = try #require(feedbacks[0]["references"] as? [[String: Any]])
        bindings[0]["targetRole"] = "AXWrongRole"
        feedbacks[0]["references"] = bindings; base["feedbacks"] = feedbacks
        try JSONSerialization.data(withJSONObject: base).write(to: path)
        #expect(throws: (any Error).self) { try ReadonlyHandoffReader(directory: exported.directory) }
        #expect(throws: HandoffReadError.self) { try reader.readFeedback(order: 1, limit: 65_536) }
        #expect(throws: HandoffReadError.self) { try reader.readFeedbacks() }
        try original.write(to: path)
        var missingBindings = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        feedbacks = try #require(missingBindings["feedbacks"] as? [[String: Any]])
        feedbacks[0]["references"] = []
        missingBindings["feedbacks"] = feedbacks
        try JSONSerialization.data(withJSONObject: missingBindings).write(to: path)
        #expect(throws: (any Error).self) { try ReadonlyHandoffReader(directory: exported.directory) }
    }

    @Test func feedbackIndexBoundsReferencePreviewsAndFullReadKeepsEveryOccurrence() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = try feedbackFixture(in: root)
        source.document.feedbacks[0].content += (0..<10).map { _ in
            .control(FeedbackControlReference(nodeID: "second-button", label: String(repeating: "中文标签", count: 60)))
        }
        let exported = try AgentHandoffStore.export(project: source, to: root.appendingPathComponent("feedback-handoff"))
        let reader = try ReadonlyHandoffReader(directory: exported.directory)
        let row = try #require((reader.readFeedbacks()["feedbacks"] as? [[String: Any]])?.first)
        #expect(row["referenceCount"] as? Int == 13)
        #expect(row["referencesTruncated"] as? Bool == true)
        #expect((row["references"] as? [[String: Any]])?.count == 8)
        let full = try JSONDecoder().decode(AgentHandoffFeedback.self,
            from: Data(reader.readFeedback(order: 1, limit: 65_536).text.utf8))
        #expect(full.references.count == 13)
        #expect(full.feedback == source.document.feedbacks[0])
    }

    @Test func legacyHandoffWithoutFeedbackRemainsReadableAndFeedbackArgumentsAreBounded() throws {
        let fixture = AgentHandoffStoreTests()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exported = try AgentHandoffStore.export(project: fixture.fixture(in: root), to: root.appendingPathComponent("old-handoff"))
        for relative in ["handoff.json", "source.oneshot/annotations.json"] {
            let path = exported.directory.appendingPathComponent(relative)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            object.removeValue(forKey: "feedbacks")
            try JSONSerialization.data(withJSONObject: object).write(to: path)
        }
        let reader = try ReadonlyHandoffReader(directory: exported.directory)
        #expect(reader.document.feedbacks.isEmpty)
        #expect(try reader.readFeedbacks()["totalFeedbacks"] as? Int == 0)
        #expect(throws: HandoffReadError.self) { try reader.readFeedback(order: 1) }
        let server = OneShotMCPServer(reader: reader)
        _ = try request(server, method: "initialize", params: initialization(version: "2025-06-18"))
        _ = server.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        for (name, args) in [("read_feedback", ["order": true]), ("read_feedback", ["order": 0]),
                             ("read_feedback", ["order": 1, "path": "/etc/passwd"]),
                             ("read_feedbacks", ["offset": -1]), ("read_feedbacks", ["limit": 101])] as [(String, [String: Any])] {
            let response = try request(server, method: "tools/call", params: ["name": name, "arguments": args])
            #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
    }

    private func feedbackFixture(in root: URL) throws -> AnnotationProject {
        var source = try AgentHandoffStoreTests().fixture(in: root)
        let axURL = source.captureDirectory.appendingPathComponent("accessibility.json")
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: axURL)) as? [String: Any])
        var nodes = try #require(raw["nodes"] as? [[String: Any]])
        var second = nodes[0]; second["id"] = "second-button"
        nodes.append(second); raw["nodes"] = nodes
        try JSONSerialization.data(withJSONObject: raw).write(to: axURL)
        source.document.feedbacks = [FeedbackItem(content: [
            .text("希望把 "), .control(FeedbackControlReference(nodeID: "button-42", label: "保存按钮")),
            .text(" 改成 "), .control(FeedbackControlReference(nodeID: "second-button", label: "发布按钮")),
            .text(" 的样式。\n" + String(repeating: "中文🙂细节 ", count: 200)),
            .control(FeedbackControlReference(nodeID: "button-42", label: "保存按钮")),
        ]), FeedbackItem(content: [.text("整体留白需要更舒适。")])]
        return source
    }

    private func initialization(version: String) -> [String: Any] {
        ["protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "OneShot tests", "version": "1"]]
    }

    private func request(_ server: OneShotMCPServer, method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let response = try #require(server.handle(data))
        return try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    private func call(_ server: OneShotMCPServer, name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let response = try request(server, method: "tools/call", params: ["name": name, "arguments": arguments])
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        return result
    }

    private func textObject(_ result: [String: Any]) throws -> [String: Any] {
        let text = try #require(((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
