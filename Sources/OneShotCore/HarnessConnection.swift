import Darwin
import Foundation

public enum AgentHarness: String, CaseIterable, Identifiable {
    case codex, claudeCode
    public var id: String { rawValue }
    public var title: String { self == .codex ? "Codex" : "Claude Code" }
    public var command: String { self == .codex ? "codex" : "claude" }
    var configName: String { self == .codex ? "config.toml" : ".claude.json" }
    var directoryVariable: String { self == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR" }

    public func configurationURL(home: URL, environment: [String: String]) throws -> URL {
        if let path = environment[directoryVariable], !path.isEmpty {
            guard path.hasPrefix("/") else { throw HarnessConnectionError("\(directoryVariable) 必须是绝对路径。") }
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(configName)
        }
        return home.appendingPathComponent(self == .codex ? ".codex/config.toml" : ".claude.json")
    }
}

public enum HarnessConfigurationState: String {
    case missing, configured, needsUpdate, conflict, unavailable
    public var title: String {
        switch self {
        case .missing: return "未配置"
        case .configured: return "已配置"
        case .needsUpdate: return "配置需要更新"
        case .conflict: return "同名配置需手动处理"
        case .unavailable: return "无法检查"
        }
    }
}

public struct HarnessConnectionStatus {
    public let harness: AgentHarness
    public let cli: URL?
    public let configuration: URL?
    public let state: HarnessConfigurationState
    public let detail: String
    public var canConnect: Bool { cli != nil && (state == .missing || state == .needsUpdate) }
    public var canRemove: Bool { cli != nil && (state == .configured || state == .needsUpdate) }
}

public struct HarnessConnectionError: LocalizedError {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Edits are prepared with the client's CLI in a private temporary configuration.
/// Only a validated result is committed, after checking that the live file has not changed.
public struct HarnessConnectionManager {
    public let executable: URL
    public let library: URL?
    public let home: URL
    public let environment: [String: String]
    public var preferredCLIs: [AgentHarness: URL]
    let runner: (URL, [String], [String: String], URL) throws -> Data

    public init(executable: URL, library: URL? = nil,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                preferredCLIs: [AgentHarness: URL] = [:]) {
        self.executable = executable; self.library = library
        self.home = home; self.environment = environment; self.preferredCLIs = preferredCLIs
        runner = HarnessCLI.run
    }

    // Injectable process boundary lets tests exercise failure and concurrent-edit handling.
    init(executable: URL, library: URL? = nil, home: URL, environment: [String: String],
         preferredCLIs: [AgentHarness: URL], runner: @escaping (URL, [String], [String: String], URL) throws -> Data) {
        self.executable = executable; self.library = library; self.home = home
        self.environment = environment; self.preferredCLIs = preferredCLIs; self.runner = runner
    }

    public func inspect(_ harness: AgentHarness) -> HarnessConnectionStatus {
        let cli = locateCLI(harness)
        var configuration: URL?
        do {
            let url = try harness.configurationURL(home: home, environment: environment)
            configuration = url
            let data = try Self.readConfiguration(url)
            let entry: [String: Any]?
            if harness == .claudeCode { entry = try Self.claudeServers(data)["oneshot"] as? [String: Any] }
            else {
                guard let cli else { throw HarnessConnectionError("未找到 Codex CLI。可选择已安装的程序，或使用手动配置。") }
                entry = try withStaging(harness, data: data) { stage in
                    try codexEntry(cli: cli, stage: stage)
                }
            }
            var state = try configurationState(entry, harness: harness)
            if harness == .codex, entry != nil, !Self.hasSimpleCodexEntry(data) { state = .conflict }
            let detail = cli == nil ? "未找到 \(harness.title) CLI，请选择程序或使用手动配置。"
                : state == .conflict ? "oneshot 已被其他服务或自定义配置占用，请手动处理。"
                : state == .needsUpdate ? "OneShot 路径、材料库参数或启用状态需要更新。"
                : "用户级配置，适用于所有项目；项目或组织策略仍可能覆盖此配置。"
            return .init(harness: harness, cli: cli, configuration: url, state: state, detail: detail)
        } catch {
            return .init(harness: harness, cli: cli, configuration: configuration, state: .unavailable,
                         detail: error.localizedDescription)
        }
    }

    /// Returns the private backup location, if an existing configuration was changed.
    @discardableResult public func connect(_ harness: AgentHarness) throws -> URL? {
        try change(harness, removing: false)
    }
    @discardableResult public func remove(_ harness: AgentHarness) throws -> URL? {
        try change(harness, removing: true)
    }

    private var arguments: [String] { ["--library"] + (library.map { [$0.path] } ?? []) }

    private func change(_ harness: AgentHarness, removing: Bool) throws -> URL? {
        guard let cli = locateCLI(harness) else { throw HarnessConnectionError("未找到 \(harness.title) CLI。") }
        let url = try harness.configurationURL(home: home, environment: environment)
        let original = try Self.readConfiguration(url)
        let result = try withStaging(harness, data: original) { stage -> Data? in
            let entry = try harness == .codex ? codexEntry(cli: cli, stage: stage)
                : Self.claudeServers(original)["oneshot"] as? [String: Any]
            let state = try configurationState(entry, harness: harness)
            if harness == .codex, entry != nil, !Self.hasSimpleCodexEntry(original) {
                throw HarnessConnectionError("OneShot 的 Codex 条目含有自定义设置，请使用手动配置，未进行修改。")
            }
            guard state != .conflict else { throw HarnessConnectionError("oneshot 配置包含其他服务或自定义选项，未进行修改。") }
            if (removing && state == .missing) || (!removing && state == .configured) { return nil }
            let env = stagedEnvironment(harness, cli: cli, stage: stage)
            if !removing {
                try MCPConnectionConfiguration.check(executable: executable, library: library ?? HandoffLibrary.defaultDirectory)
            }
            if removing || (harness == .claudeCode && entry != nil) {
                let args = harness == .codex ? ["mcp", "remove", "oneshot"] : ["mcp", "remove", "--scope", "user", "oneshot"]
                _ = try runner(cli, args, env, stage)
            }
            if !removing {
                let args = harness == .codex ? ["mcp", "add", "oneshot", "--", executable.path] + arguments
                    : ["mcp", "add", "--scope", "user", "--transport", "stdio", "oneshot", "--", executable.path] + arguments
                _ = try runner(cli, args, env, stage)
            }
            let staged = try Self.readConfiguration(stage.appendingPathComponent(harness.configName))
            let updated: [String: Any]?
            if harness == .codex { updated = try codexEntry(cli: cli, stage: stage) }
            else { updated = try Self.claudeServers(staged)["oneshot"] as? [String: Any] }
            guard removing ? updated == nil : try configurationState(updated, harness: harness) == .configured else {
                throw HarnessConnectionError("CLI 返回的配置未通过检查，原配置未修改。")
            }
            if harness == .codex { return staged }
            // Claude CLI may migrate unrelated account preferences. Keep only its oneshot change.
            var object = try Self.claudeObject(original)
            var servers = try Self.claudeServers(original)
            servers["oneshot"] = updated
            object["mcpServers"] = servers
            return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
        }
        guard let result else { return nil }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Serialize OneShot writers; detect independent edits before replacing the live file.
        let lock = directory.appendingPathComponent(".oneshot-mcp.lock")
        let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HarnessConnectionError("无法锁定 Agent 配置目录。") }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw HarnessConnectionError("另一项配置操作正在进行，请稍后重试。") }
        guard try Self.readConfiguration(url) == original else {
            throw HarnessConnectionError("配置在操作期间已被其他程序修改，请刷新后重试。")
        }
        var backup: URL?
        if let original {
            let destination = directory.appendingPathComponent("\(url.lastPathComponent).oneshot-backup-\(UUID().uuidString)")
            try Self.privateWrite(original, to: destination)
            backup = destination
        }
        try Self.privateWrite(result, to: url)
        return backup
    }

    private func configurationState(_ entry: [String: Any]?, harness: AgentHarness) throws -> HarnessConfigurationState {
        guard let entry else { return .missing }
        let transport = harness == .codex ? entry["transport"] as? [String: Any] : entry
        guard let transport, (transport["type"] as? String ?? "stdio") == "stdio",
              let command = transport["command"] as? String, command.hasPrefix("/"),
              let args = transport["args"] as? [String] else { return .conflict }
        let knownPath = command == executable.path || command.hasSuffix("/OneShot.app/Contents/Helpers/oneshot-mcp")
            || command.hasSuffix("/OneShot Editor.app/Contents/Helpers/oneshot-mcp")
        guard knownPath, args == ["--library"] || (args.count == 2 && args[0] == "--library" && args[1].hasPrefix("/")) else { return .conflict }
        let allowed = harness == .codex ? Set(["type", "command", "args", "env", "env_vars", "cwd"]) : Set(["type", "command", "args", "env"])
        guard Set(transport.keys).isSubset(of: allowed),
              transport["env"] == nil || transport["env"] is NSNull || (transport["env"] as? [String: String])?.isEmpty == true,
              transport["cwd"] == nil || transport["cwd"] is NSNull,
              transport["env_vars"] == nil || (transport["env_vars"] as? [String])?.isEmpty == true else { return .conflict }
        if harness == .codex {
            // CLI list includes defaults. Refuse to reset explicit advanced policy or timeouts.
            let standard = Set(["name", "enabled", "disabled_reason", "transport", "startup_timeout_sec", "tool_timeout_sec", "auth_status"])
            guard Set(entry.keys).isSubset(of: standard),
                  entry["startup_timeout_sec"] == nil || entry["startup_timeout_sec"] is NSNull,
                  entry["tool_timeout_sec"] == nil || entry["tool_timeout_sec"] is NSNull else { return .conflict }
        }
        return command == executable.path && args == arguments && (entry["enabled"] as? Bool ?? true) ? .configured : .needsUpdate
    }

    private func codexEntry(cli: URL, stage: URL) throws -> [String: Any]? {
        let output = try runner(cli, ["mcp", "list", "--json"], stagedEnvironment(.codex, cli: cli, stage: stage), stage)
        guard let entries = try JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
            throw HarnessConnectionError("Codex CLI 返回了无法识别的配置，请升级 CLI 或使用手动配置。")
        }
        return entries.first { $0["name"] as? String == "oneshot" }
    }

    /// Native `mcp add` replaces the entire table. Only auto-manage our simple emitted
    /// form; quoted/dotted keys, multiline values and extra policies stay user-managed.
    static func hasSimpleCodexEntry(_ data: Data?) -> Bool {
        guard let data, let source = String(data: data, encoding: .utf8) else { return false }
        let lines = source.components(separatedBy: .newlines)
        var inside = false, found = false, outside = "", keys = Set<String>()
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if text == "[mcp_servers.oneshot]" {
                if found { return false }
                found = true; inside = true; continue
            }
            if text.hasPrefix("[") { inside = false }
            if !inside { outside += text + "\n"; continue }
            let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, keys.insert(parts[0]).inserted else { return false }
            switch parts[0] {
            case "command":
                guard (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8), options: .fragmentsAllowed)) is String else { return false }
            case "args":
                guard (try? JSONSerialization.jsonObject(with: Data(parts[1].utf8))) is [String] else { return false }
            case "enabled":
                guard parts[1] == "true" || parts[1] == "false" else { return false }
            default: return false
            }
        }
        return found && keys.contains("command") && keys.contains("args") && !outside.contains("oneshot")
    }

    private func withStaging<T>(_ harness: AgentHarness, data: Data?, body: (URL) throws -> T) throws -> T {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        if let data { try Self.privateWrite(data, to: stage.appendingPathComponent(harness.configName)) }
        return try body(stage)
    }

    private func stagedEnvironment(_ harness: AgentHarness, cli: URL, stage: URL) -> [String: String] {
        var env = environment
        env[harness.directoryVariable] = stage.path
        env["PATH"] = ([cli.deletingLastPathComponent().path] + searchDirectories()).joined(separator: ":")
        env["DISABLE_TELEMETRY"] = "1"; env["DISABLE_ERROR_REPORTING"] = "1"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return env
    }

    public func locateCLI(_ harness: AgentHarness) -> URL? {
        let candidates = preferredCLIs[harness].map { [$0] } ?? []
        let bundled = harness == .codex ? [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/MacOS/codex",
        ].map { URL(fileURLWithPath: $0) } : []
        return (candidates + searchDirectories().map { URL(fileURLWithPath: $0).appendingPathComponent(harness.command) } + bundled)
            .first { $0.path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func searchDirectories() -> [String] {
        let versions = home.appendingPathComponent(".nvm/versions/node")
        let nvm = ((try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { versions.appendingPathComponent($0).appendingPathComponent("bin").path }
        return (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            + [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + nvm
    }

    static func readConfiguration(_ url: URL) throws -> Data? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw HarnessConnectionError("无法读取配置：\(url.path)")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 8 * 1_024 * 1_024 else {
            throw HarnessConnectionError("配置不是当前用户的普通文件、是符号链接或超过 8 MiB，请手动配置。")
        }
        return try Data(contentsOf: url)
    }

    private static func privateWrite(_ data: Data, to url: URL) throws {
        // Create with restricted permissions before writing secrets from an existing config.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".oneshot-write-\(UUID().uuidString)")
        let fd = Darwin.open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HarnessConnectionError("无法写入配置目录。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard rename(temp.path, url.path) == 0 else { throw HarnessConnectionError("无法保存 Agent 配置。") }
    }

    private static func claudeObject(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessConnectionError("Claude Code 配置不是 JSON 对象，原文件未修改。")
        }
        return object
    }
    private static func claudeServers(_ data: Data?) throws -> [String: Any] {
        let object = try claudeObject(data)
        guard let value = object["mcpServers"] else { return [:] }
        guard let servers = value as? [String: Any], servers["oneshot"] == nil || servers["oneshot"] is [String: Any] else {
            throw HarnessConnectionError("Claude Code 的 mcpServers 格式无效，原配置未修改。")
        }
        return servers
    }
}

enum HarnessCLI {
    /// File-backed output avoids pipe deadlocks; output is bounded and never shown in the UI.
    static func run(_ executable: URL, _ arguments: [String], _ environment: [String: String], _ directory: URL) throws -> Data {
        let outputURL = directory.appendingPathComponent("cli-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        let process = Process(), done = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 1) != .success { Darwin.kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
            throw HarnessConnectionError("\(executable.lastPathComponent) CLI 响应超时，原配置未修改。")
        }
        guard process.terminationStatus == 0 else {
            throw HarnessConnectionError("\(executable.lastPathComponent) CLI 操作失败（退出码 \(process.terminationStatus)），原配置未修改。请检查 CLI 版本或使用手动配置。")
        }
        let size = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
        guard (size?.intValue ?? Int.max) <= 8 * 1_024 * 1_024 else { throw HarnessConnectionError("CLI 输出超过支持大小。") }
        return try Data(contentsOf: outputURL)
    }
}
