import Darwin
import Foundation

public enum MCPConnectionConfiguration {
    public static func json(executable: URL, library: URL? = nil) -> String {
        let args = ["--library"] + (library.map { [$0.path] } ?? [])
        let value: [String: Any] = ["mcpServers": ["oneshot": ["command": executable.path, "args": args]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    public static func toml(executable: URL, library: URL? = nil) -> String {
        func quoted(_ value: String) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
            return String(decoding: try! encoder.encode(value), as: UTF8.self)
        }
        let args = ["--library"] + (library.map { [$0.path] } ?? [])
        return "[mcp_servers.oneshot]\ncommand = \(quoted(executable.path))\nargs = [\(args.map(quoted).joined(separator: ", "))]\n"
    }

    /// Checks local readiness, not another Agent's connection.
    public static func check(executable: URL, library: URL) throws {
        _ = try HandoffLibrary(directory: library).list()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["--library", library.path]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
        }
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "OneShot connection check", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
        ]
        for message in messages {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10]))
        }
        try input.fileHandleForWriting.close()
        guard done.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 1) != .success { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw HandoffReadError.invalidPackage("本地 MCP 服务检查超时。")
        }
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        let replies = try data.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        guard process.terminationStatus == 0,
              let response = replies.compactMap({ $0 }).first(where: { $0["id"] as? Int == 2 }),
              let result = response["result"] as? [String: Any], let tools = result["tools"] as? [[String: Any]],
              Set(tools.compactMap { $0["name"] as? String }) == Set(["read_handoff", "read_details", "read_image"]) else {
            throw HandoffReadError.invalidPackage("本地 MCP 初始化或工具列表检查失败。")
        }
    }
}
