import Darwin
import Foundation
import Testing
@testable import OneShotCore

struct HandoffStdioTests {
    @Test func realProcessReadsNewVersionsWithoutEOFOrRestart() throws {
        let fixture = AgentHandoffStoreTests()
        let retained = ProcessInfo.processInfo.environment["ONESHOT_TEST_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }
        let root: URL
        if let retained {
            try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: false)
            root = retained
        } else { root = try fixture.temporaryDirectory() }
        defer { if retained == nil { try? FileManager.default.removeItem(at: root) } }
        var project = try fixture.fixture(in: root)
        project.document.feedbacks = [FeedbackItem(content: [.text("请修改 "),
            .control(FeedbackControlReference(nodeID: "button-42", label: "保存设置")), .text(" 的提示。")])]
        let library = HandoffLibrary(directory: root.appendingPathComponent("library"))
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/oneshot-mcp")
        let client = try LiveMCP(binary: binary, library: library.directory)
        defer { client.close() }
        let hello = try client.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "OneShot persistent stdio test", "version": "1"]])
        #expect(hello["protocolVersion"] as? String == "2025-06-18")
        try client.send(["method": "notifications/initialized"])
        let tools = try client.request("tools/list")
        #expect((tools["tools"] as? [[String: Any]])?.count == 3)
        #expect(!FileManager.default.fileExists(atPath: library.directory.path))
        let first = try library.publish(project: project, title: "MCP 验证材料")
        let result = try client.request("tools/call", ["name": "read_handoff", "arguments": ["reference": first.reference]])
        #expect(result["isError"] as? Bool == false)
        #expect((result["content"] as? [[String: Any]])?.count == 2)
        project.document.feedbacks.append(FeedbackItem(content: [.text("第二条反馈：保留原来的尺寸。")]))
        let second = try library.publish(project: project, title: "MCP 验证材料")
        for (entry, count) in [(first, 1), (second, 2)] {
            let reply = try client.request("tools/call", ["name": "read_handoff", "arguments": ["reference": entry.reference]])
            #expect((reply["structuredContent"] as? [String: Any])?["feedbackCount"] as? Int == count)
        }
        try library.revoke(reference: first.reference)
        let revoked = try client.request("tools/call", ["name": "read_handoff", "arguments": ["reference": first.reference]])
        #expect(revoked["isError"] as? Bool == true)
        let image = try client.request("tools/call", ["name": "read_image",
            "arguments": ["reference": second.reference, "variant": "raw", "resolution": "original"]])
        let blocks = try #require(image["content"] as? [[String: Any]])
        let encoded = try #require(blocks.last?["data"] as? String)
        #expect(try Data(base64Encoded: encoded) == Data(contentsOf: project.imageURL))
        try client.finish()
        try MCPConnectionConfiguration.check(executable: binary, library: library.directory)
        if retained != nil {
            let evidence: [String: Any] = ["result": "passed", "reference": second.reference,
                "project": library.snapshotDirectory(for: second).appendingPathComponent("source.oneshot").path,
                "persistentStdio": true, "versionIsolation": true, "revocation": true, "rawImageByteEquality": true]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("result.json"))
        }
    }
}

private final class LiveMCP {
    let process = Process(), input = Pipe(), output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private let done = DispatchSemaphore(value: 0)

    init(binary: URL, library: URL) throws {
        process.executableURL = binary; process.arguments = ["--library", library.path]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [done] _ in done.signal() }
        try process.run()
    }
    func send(_ fields: [String: Any]) throws {
        var message = fields; message["jsonrpc"] = "2.0"
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10]))
    }
    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextID; nextID += 1
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(5)
        while !buffer.contains(10) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw HandoffReadError.invalidPackage("Persistent MCP response timed out") }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(remaining * 1000)) > 0 else { throw HandoffReadError.unavailable }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw HandoffReadError.unavailable }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 16 * 1_024 * 1_024 else { throw HandoffReadError.invalidRange }
        }
        let newline = buffer.firstIndex(of: 10)!
        let data = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
        let reply = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(reply["id"] as? Int == id)
        return try #require(reply["result"] as? [String: Any])
    }
    func finish() throws {
        try input.fileHandleForWriting.close()
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(!process.isRunning)
        if !process.isRunning { #expect(process.terminationStatus == 0) }
    }
    func close() {
        if process.isRunning {
            process.terminate()
            if done.wait(timeout: .now() + 1) != .success { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
}
