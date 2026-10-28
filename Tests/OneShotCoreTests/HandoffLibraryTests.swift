import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import OneShotCore

struct HandoffLibraryTests {
    @Test func connectionConfigurationsPreservePathsWithoutInvalidTOMLEscapes() throws {
        let executable = URL(fileURLWithPath: "/Applications/OneShot.app/Contents/Helpers/oneshot-mcp")
        let toml = MCPConnectionConfiguration.toml(executable: executable)
        #expect(toml == "[mcp_servers.oneshot]\ncommand = \"/Applications/OneShot.app/Contents/Helpers/oneshot-mcp\"\nargs = [\"--library\"]\n")
        let path = URL(fileURLWithPath: "/tmp/OneShot Test/Library")
        let json = MCPConnectionConfiguration.json(executable: executable, library: path)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let server = try #require((parsed["mcpServers"] as? [String: [String: Any]])?["oneshot"])
        #expect(server["command"] as? String == executable.path)
        #expect(server["args"] as? [String] == ["--library", path.path])
    }
    @Test func versionsAreImmutableAndRevocationIsPerVersion() throws {
        let fixture = AgentHandoffStoreTests(), root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = HandoffLibrary(directory: root.appendingPathComponent("library"))
        #expect(try library.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.directory.path))
        var project = try fixture.fixture(in: root)
        project.document.feedbacks = [FeedbackItem(content: [.text("第一版🙂")])]
        let first = try library.publish(project: project, title: "测试")
        project.document.feedbacks[0].content = [.text("第二版")]
        let second = try library.publish(project: project, title: "测试")
        #expect(first.handoffID == second.handoffID)
        #expect(first.revision == 1 && second.revision == 2)
        #expect(try library.reader(reference: first.reference).document.feedbacks[0].feedback.plainText == "第一版🙂")
        #expect(try library.reader(reference: second.reference).document.feedbacks[0].feedback.plainText == "第二版")
        try library.revoke(reference: first.reference)
        #expect(throws: HandoffReadError.self) { try library.reader(reference: first.reference) }
        #expect(try library.resolve(reference: second.reference).revokedAt == nil)
        let reopened = HandoffLibrary(directory: library.directory)
        #expect(try reopened.list().count == 2)
        #expect(FileManager.default.fileExists(atPath: library.snapshotDirectory(for: first).path))
        #expect(try FileManager.default.attributesOfItem(atPath: library.directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: library.directory.appendingPathComponent("index.json").path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func libraryRejectsLinksPathsAndUnpublishedDirectories() throws {
        let fixture = AgentHandoffStoreTests(), root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = HandoffLibrary(directory: root.appendingPathComponent("library"))
        let project = try fixture.fixture(in: root)
        let published = try library.publish(project: project, title: "测试")
        for reference in ["latest", "../capture", "/etc/passwd", published.handoffID, "OS-000000000000@0", "OS-000000000000@1\n"] {
            #expect(throws: HandoffReadError.self) { try library.reader(reference: reference) }
        }
        let unlisted = root.appendingPathComponent("library/OS-000000000000@1")
        _ = try AgentHandoffStore.export(project: project, to: unlisted)
        #expect(throws: HandoffReadError.self) { try library.reader(reference: "OS-000000000000@1") }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library.directory)
        #expect(throws: HandoffReadError.self) { try HandoffLibrary(directory: link).list() }
        let index = library.directory.appendingPathComponent("index.json")
        let backup = root.appendingPathComponent("index-backup.json")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: backup)
        #expect(throws: HandoffReadError.self) { try library.list() }
    }

    @Test func failedPublicationDoesNotRegisterPartialMaterial() throws {
        let fixture = AgentHandoffStoreTests(), root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try fixture.fixture(in: root)
        project.document.items = [AnnotationItem(kind: .element, targetNodeID: "missing")]
        let library = HandoffLibrary(directory: root.appendingPathComponent("library"))
        #expect(throws: (any Error).self) { try library.publish(project: project, title: "失败") }
        #expect(try library.list().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.directory.path) == [".lock"])
    }

    @Test func connectedServerDiscoversPublicationAndRejectsRevokedCachedReader() throws {
        let fixture = AgentHandoffStoreTests(), root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = HandoffLibrary(directory: root.appendingPathComponent("library"))
        let server = try ready(library)
        var project = try fixture.fixture(in: root)
        let ref = FeedbackControlReference(nodeID: "button-42", label: "保存设置")
        project.document.feedbacks = [FeedbackItem(content: [.text("修改 "), .control(ref), .text(" 的提示🙂")])]
        let entry = try library.publish(project: project, title: "设置")
        let response = try call(server, "read_handoff", ["reference": entry.reference])
        #expect(response["isError"] as? Bool == false)
        let summary = try #require(response["structuredContent"] as? [String: Any])
        let feedbacks = try #require(summary["feedbacks"] as? [[String: Any]])
        #expect(feedbacks[0]["userText"] as? String == "修改 [R1 保存设置] 的提示🙂")
        #expect(feedbacks[0]["contentTruncated"] as? Bool == false)
        let targets = try #require(summary["targets"] as? [[String: Any]])
        #expect(targets.count == 1)
        #expect(targets[0]["id"] as? String == "button-42")
        let bounds = try #require(targets[0]["imageBounds"] as? [String: Double])
        #expect(bounds == ["x": 8, "y": 12, "width": 16, "height": 12])
        let blocks = try #require(response["content"] as? [[String: Any]])
        #expect(blocks.count == 2 && blocks[1]["type"] as? String == "image")
        let target = try call(server, "read_details", ["reference": entry.reference, "kind": "target", "id": "button-42"])
        let page = try #require(target["structuredContent"] as? [String: Any])
        let text = try #require(page["text"] as? String)
        #expect(text.contains("futureField"))
        let crop = try call(server, "read_image", ["reference": entry.reference, "variant": "raw",
            "region": ["x": 8, "y": 12, "width": 16, "height": 12]])
        let image = try #require(crop["structuredContent"] as? [String: Any])
        #expect(image["width"] as? Int == 16 && image["height"] as? Int == 12)
        try library.revoke(reference: entry.reference)
        #expect(try call(server, "read_handoff", ["reference": entry.reference])["isError"] as? Bool == true)
        #expect(try call(server, "read_image", ["reference": entry.reference])["isError"] as? Bool == true)
        let next = try library.publish(project: project, title: "设置")
        #expect(try call(server, "read_handoff", ["reference": next.reference])["isError"] as? Bool == false)
    }

    @Test func largeFeedbackHasLosslessContinuationAndNoDuplicateTargets() throws {
        let fixture = AgentHandoffStoreTests(), root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try fixture.fixture(in: root)
        let ref = FeedbackControlReference(nodeID: "button-42", label: "按钮")
        let second = FeedbackControlReference(nodeID: "button-42", label: "同一个按钮")
        let long = String(repeating: "中文🙂", count: 5_000)
        project.document.feedbacks = [FeedbackItem(content: [.control(ref), .text(long), .control(second)])]
        let library = HandoffLibrary(directory: root.appendingPathComponent("library"))
        let entry = try library.publish(project: project, title: "长反馈")
        let server = try ready(library)
        let result = try call(server, "read_handoff", ["reference": entry.reference])
        let summary = try #require(result["structuredContent"] as? [String: Any])
        let feedbacks = try #require(summary["feedbacks"] as? [[String: Any]])
        #expect(feedbacks[0]["contentTruncated"] as? Bool == true)
        #expect((summary["targets"] as? [[String: Any]])?.count == 1)
        let refs = try #require(feedbacks[0]["references"] as? [[String: Any]])
        #expect(refs.count == 2 && refs[0]["occurrenceId"] as? String != refs[1]["occurrenceId"] as? String)
        var offset = 0, json = ""
        while true {
            let result = try call(server, "read_details", ["reference": entry.reference, "kind": "feedback",
                "id": "1", "offset": offset, "limit": 4096])
            let page = try #require(result["structuredContent"] as? [String: Any])
            json += try #require(page["text"] as? String)
            offset = try #require(page["nextOffset"] as? Int)
            if page["hasMore"] as? Bool == false { break }
        }
        let original = try JSONDecoder().decode(AgentHandoffFeedback.self, from: Data(json.utf8))
        #expect(original.feedback == project.document.feedbacks[0])
    }

    @Test func firstReadPaginatesRowsAndMissingAXDoesNotInventTargets() throws {
        let fixture = AgentHandoffStoreTests(), root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try fixture.fixture(in: root)
        project.document.feedbacks = (1...23).map { FeedbackItem(content: [.text("意见 \($0)")]) }
        let library = HandoffLibrary(directory: root.appendingPathComponent("library"))
        let entry = try library.publish(project: project, title: "无绑定反馈")
        let server = try ready(library)
        let result = try call(server, "read_handoff", ["reference": entry.reference])
        let summary = try #require(result["structuredContent"] as? [String: Any])
        #expect(summary["feedbacksHasMore"] as? Bool == true)
        #expect(summary["feedbacksNextOffset"] as? Int == 20)
        #expect((summary["targets"] as? [[String: Any]])?.isEmpty == true)
        let rest = try call(server, "read_details", ["reference": entry.reference, "kind": "feedbacks", "offset": 20])
        #expect(((rest["structuredContent"] as? [String: Any])?["feedbacks"] as? [[String: Any]])?.count == 3)
    }

    @Test func concurrentPublishersPreserveEveryRevision() throws {
        let fixture = AgentHandoffStoreTests(), root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try fixture.fixture(in: root)
        let library = HandoffLibrary(directory: root.appendingPathComponent("library"))
        _ = try library.publish(project: project, title: "初始")
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do { _ = try HandoffLibrary(directory: library.directory).publish(project: project, title: "并发") }
            catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
        }
        #expect(failures.isEmpty)
        #expect(try library.list().map(\.revision).sorted() == [1, 2, 3, 4, 5])
        #expect(try library.list().first?.revision == 5)
    }

    private func ready(_ library: HandoffLibrary) throws -> OneShotMCPServer {
        let server = OneShotMCPServer(library: library)
        _ = server.handle(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]]))
        _ = server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        return server
    }

    private func call(_ server: OneShotMCPServer, _ name: String, _ args: [String: Any]) throws -> [String: Any] {
        let data = try #require(server.handle(JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2,
            "method": "tools/call", "params": ["name": name, "arguments": args]])))
        let reply = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(reply["result"] as? [String: Any])
    }
}
