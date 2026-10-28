import Foundation
import Testing
@testable import OneShotCore

struct HarnessConnectionTests {
    private var binary: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/oneshot-mcp")
    }
    private func temporary() throws -> URL { try AgentHandoffStoreTests().temporaryDirectory() }
    private func config(_ home: URL) -> URL { home.appendingPathComponent(".claude.json") }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
    private func entry(_ command: String, args: [String] = ["--library"]) -> [String: Any] {
        ["type": "stdio", "command": command, "args": args, "env": [:]]
    }
    private func manager(_ home: URL, runner: @escaping (URL, [String], [String: String], URL) throws -> Data) -> HarnessConnectionManager {
        .init(executable: binary, library: home.appendingPathComponent("library"), home: home, environment: [:],
              preferredCLIs: [.claudeCode: URL(fileURLWithPath: "/usr/bin/true")], runner: runner)
    }

    @Test func readsUserScopeAndProtectsConflictsAndMalformedFiles() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let service = manager(root) { _, _, _, _ in Issue.record("CLI should not run"); return Data() }
        #expect(service.inspect(.claudeCode).state == .missing)
        try json(["mcpServers": ["oneshot": ["type": "http", "url": "https://example.test"]]]) .write(to: config(root))
        #expect(service.inspect(.claudeCode).state == .conflict)
        #expect(throws: HarnessConnectionError.self) { try service.connect(.claudeCode) }
        try json(["projects": ["/some/project": ["mcpServers": ["oneshot": entry(binary.path)]]]]) .write(to: config(root))
        #expect(service.inspect(.claudeCode).state == .missing)
        for data in [Data("{invalid".utf8), try json(["mcpServers": []]), try json(["mcpServers": ["oneshot": "bad"]])] {
            try data.write(to: config(root))
            #expect(service.inspect(.claudeCode).state == .unavailable)
            #expect(throws: (any Error).self) { try service.connect(.claudeCode) }
            #expect(try Data(contentsOf: config(root)) == data)
        }
    }

    @Test func simpleCodexCheckRejectsAdvancedPoliciesAndAlternativeSyntax() {
        let simple = "[mcp_servers.oneshot]\ncommand = \"/Applications/OneShot.app/Contents/Helpers/oneshot-mcp\"\nargs = [\"--library\"]\n"
        #expect(HarnessConnectionManager.hasSimpleCodexEntry(Data(("# note\nmodel = \"test\"\n" + simple + "[mcp_servers.other]\ncommand = \"other\"\n").utf8)))
        for value in [simple + "enabled_tools = [\"read_image\"]", simple + "[mcp_servers.oneshot.tools.read_image]\napproval_mode = \"prompt\"",
                      simple + "[mcp_servers.\"oneshot\".env]\nKEY = \"value\"", simple.replacingOccurrences(of: "[mcp_servers.oneshot]", with: "[mcp_servers.\"oneshot\"]"),
                      simple + "command = \"different\"", simple + "env = {}"] {
            #expect(!HarnessConnectionManager.hasSimpleCodexEntry(Data(value.utf8)))
        }
    }

    @Test func claudeStagedUpdateKeepsOtherPreferencesAndCreatesPrivateBackup() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try json(["accountPreference": "keep", "mcpServers": [
            "oneshot": entry("/old/OneShot.app/Contents/Helpers/oneshot-mcp"), "other": ["type": "http", "url": "https://example.test"]]])
        try original.write(to: config(root))
        let service = manager(root) { _, args, env, stage in
            #expect(env["CLAUDE_CONFIG_DIR"] == stage.path)
            #expect(args.contains("user"))
            let value: [String: Any] = args[1] == "remove" ? [:] : ["oneshot": entry(binary.path, args: ["--library", root.appendingPathComponent("library").path])]
            try json(["migrationFromCLI": "must not reach live config", "mcpServers": value]).write(to: stage.appendingPathComponent(".claude.json"))
            return Data()
        }
        #expect(service.inspect(.claudeCode).state == .needsUpdate)
        let backup = try #require(try service.connect(.claudeCode))
        #expect(try Data(contentsOf: backup) == original)
        #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
        let updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config(root))) as? [String: Any])
        #expect(updated["accountPreference"] as? String == "keep")
        #expect(updated["migrationFromCLI"] == nil)
        #expect((updated["mcpServers"] as? [String: Any])?["other"] != nil)
        #expect(service.inspect(.claudeCode).state == .configured)
        #expect(try service.connect(.claudeCode) == nil)
        try service.remove(.claudeCode)
        #expect(service.inspect(.claudeCode).state == .missing)
        let remaining = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config(root))) as? [String: Any])
        #expect((remaining["mcpServers"] as? [String: Any])?["other"] != nil)
        #expect(remaining["accountPreference"] as? String == "keep")
    }

    @Test func failedCLIAndConcurrentEditsNeverOverwriteLiveConfiguration() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try json(["mcpServers": ["oneshot": entry("/old/OneShot.app/Contents/Helpers/oneshot-mcp")]])
        try original.write(to: config(root))
        let failure = manager(root) { _, args, _, stage in
            if args[1] == "add" { throw HarnessConnectionError("simulated failure") }
            try json([:]).write(to: stage.appendingPathComponent(".claude.json")); return Data()
        }
        #expect(throws: HarnessConnectionError.self) { try failure.connect(.claudeCode) }
        #expect(try Data(contentsOf: config(root)) == original)
        let concurrent = try json(["concurrentEdit": true])
        let race = manager(root) { _, args, _, stage in
            if args[1] == "add" {
                try concurrent.write(to: config(root))
                try json(["mcpServers": ["oneshot": entry(binary.path, args: ["--library", root.appendingPathComponent("library").path])]])
                    .write(to: stage.appendingPathComponent(".claude.json"))
            } else { try json([:]).write(to: stage.appendingPathComponent(".claude.json")) }
            return Data()
        }
        #expect(throws: HarnessConnectionError.self) { try race.connect(.claudeCode) }
        #expect(try Data(contentsOf: config(root)) == concurrent)
    }

    @Test func respectsConfigLocationsAndRejectsSymlink() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try AgentHarness.codex.configurationURL(home: root, environment: [:]) == root.appendingPathComponent(".codex/config.toml"))
        #expect(try AgentHarness.claudeCode.configurationURL(home: root, environment: ["CLAUDE_CONFIG_DIR": root.path]) == config(root))
        #expect(throws: HarnessConnectionError.self) { try AgentHarness.codex.configurationURL(home: root, environment: ["CODEX_HOME": "relative"]) }
        let target = root.appendingPathComponent("real.json")
        try json([:]).write(to: target)
        try FileManager.default.createSymbolicLink(at: config(root), withDestinationURL: target)
        #expect(throws: HarnessConnectionError.self) { try HarnessConnectionManager.readConfiguration(config(root)) }
    }

    @Test func realNativeCLIsAddUpdateRemoveWithoutChangingOtherServers() throws {
        // Opt in on a developer machine; no CLI installation or account is required by the regular suite.
        guard ProcessInfo.processInfo.environment["ONESHOT_TEST_HARNESS_CLIS"] == "1" else { return }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let locator = HarnessConnectionManager(executable: binary)
        for harness in AgentHarness.allCases {
            let cli = try #require(locator.locateCLI(harness))
            let home = root.appendingPathComponent(harness.rawValue)
            let path = try harness.configurationURL(home: home, environment: [:])
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = harness == .codex ? Data("# keep me\nmodel = \"test\"\n[mcp_servers.other]\ncommand = \"/usr/bin/true\"\n".utf8)
                : try json(["accountPreference": "keep", "mcpServers": ["other": ["type": "stdio", "command": "/usr/bin/true", "args": []]]])
            try before.write(to: path)
            let service = HarnessConnectionManager(executable: binary, library: root.appendingPathComponent("Library with spaces"), home: home,
                environment: [:], preferredCLIs: [harness: cli])
            #expect(service.inspect(harness).state == .missing)
            let backup = try #require(try service.connect(harness))
            #expect(try Data(contentsOf: backup) == before)
            #expect(service.inspect(harness).state == .configured)
            #expect(try service.connect(harness) == nil)
            // Change the stored app path to exercise the actual native update operation.
            let current = try String(contentsOf: path, encoding: .utf8)
            try current.replacingOccurrences(of: binary.path, with: "/old/OneShot.app/Contents/Helpers/oneshot-mcp").write(to: path, atomically: true, encoding: .utf8)
            #expect(service.inspect(harness).state == .needsUpdate)
            try service.connect(harness)
            #expect(service.inspect(harness).state == .configured)
            try service.remove(harness)
            #expect(service.inspect(harness).state == .missing)
            let final = try String(contentsOf: path, encoding: .utf8)
            #expect(final.contains("other"))
            #expect(final.contains(harness == .codex ? "# keep me" : "accountPreference"))
        }
    }
}
