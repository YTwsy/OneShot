import AppKit
import ApplicationServices
import Foundation
import OneShotCore

struct Arguments {
    let command: String
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) throws {
        command = raw.first ?? "help"
        let booleanOptions: Set<String> = ["--ocr", "--no-image", "--help", "--enable-electron-ax"]
        let valueOptions: Set<String> = ["--app", "--window-id", "--output", "--capture", "--image", "--timeout", "--max-nodes", "--max-depth", "--max-text-characters", "--completion-file", "--working-directory"]
        var index = 1
        while index < raw.count {
            let key = raw[index]
            if booleanOptions.contains(key) {
                flags.insert(key)
            } else if valueOptions.contains(key), index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                guard values[key] == nil else { throw CLIError("Repeated option: \(key)") }
                index += 1
                values[key] = raw[index]
            } else {
                throw CLIError("Unknown option or missing value: \(key)")
            }
            index += 1
        }
    }

    func required(_ key: String) throws -> String {
        guard let value = values[key], !value.isEmpty else { throw CLIError("Missing required \(key)") }
        return value
    }

    func positiveInteger(_ key: String, default fallback: Int) throws -> Int {
        guard let raw = values[key] else { return fallback }
        guard let number = Int(raw), number > 0 else { throw CLIError("\(key) must be a positive integer") }
        return number
    }
}

struct CLIError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

@main
struct OneShotCLI {
    static func main() async {
        let startedAt = Date()
        let raw = Array(CommandLine.arguments.dropFirst())
        // Resolve the runner's receipt before argument validation, so malformed commands
        // also finish explicitly. The runner always passes an absolute, new destination.
        var completionURL: URL?
        var exitCode: Int32 = 0
        var failureMessage: String?
        do {
            completionURL = try CommandCompletion.requestedURL(in: raw)
            let args = try Arguments(raw)
            if let directory = args.values["--working-directory"], !FileManager.default.changeCurrentDirectoryPath(directory) {
                throw CLIError("Cannot use working directory: \(directory)")
            }
            switch args.flags.contains("--help") ? "help" : args.command {
            case "help", "--help", "-h": print(help)
            case "doctor": try doctor()
            case "authorize": await authorize()
            case "windows":
                let app = try args.required("--app")
                try printJSON(WindowSelection.candidates(from: WindowCapture.listWindows(), app: app))
            case "diagnose":
                let window = try selectedWindow(args)
                try printJSON(AXCollector().inspectApplication(pid: window.pid))
            case "capture": exitCode = try await capture(args)
            case "read":
                let directory = URL(fileURLWithPath: try args.required("--capture"), isDirectory: true)
                print(try SnapshotStore.readContext(from: directory))
            case "ocr":
                let source = URL(fileURLWithPath: try args.required("--image"))
                let result = try ImageOCR.recognize(imageURL: source)
                let store = try newStore(args, id: UUID().uuidString)
                try store.write(result, named: "ocr.json")
                try store.writeText(result.plainText, named: "context.txt")
                try printJSON(["directory": store.directory.path, "source": result.source, "observations": String(result.observations.count)])
            default: throw CLIError("Unknown command '\(args.command)'. Run oneshot help.")
            }
        } catch {
            exitCode = 1
            failureMessage = error.localizedDescription
            FileHandle.standardError.write(Data("oneshot: \(error.localizedDescription)\n".utf8))
        }
        fflush(nil)
        if let completionURL {
            do {
                try CommandCompletion.write(exitCode: exitCode, command: raw.first ?? "help", startedAt: startedAt, error: failureMessage, to: completionURL)
            } catch {
                FileHandle.standardError.write(Data("oneshot: Cannot publish completion receipt: \(error.localizedDescription)\n".utf8))
                exitCode = 1
            }
        }
        exit(exitCode)
    }

    static func doctor() throws {
        let result: [String: String] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "executable": Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
            "accessibility": AXIsProcessTrusted() ? "granted" : "not_granted",
            "screenRecording": WindowCapture.hasScreenRecordingPermission ? "granted" : "not_granted",
            "permissionsRequested": "false",
            "note": "Only checks this process. No capture, prompts, settings changes, or application activation."
        ]
        try printJSON(result)
    }

    @MainActor
    static func authorize() async {
        // This is the only command that asks macOS to display its normal consent UI.
        // User approval in System Settings remains required; no TCC state is edited.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !WindowCapture.hasScreenRecordingPermission { _ = CGRequestScreenCaptureAccess() }
        print("Accessibility: \(trusted ? "granted" : "awaiting approval in System Settings")")
        print("Screen Recording: \(WindowCapture.hasScreenRecordingPermission ? "granted" : "awaiting approval")")
        // Keep the bundled app alive long enough to appear as a stable permission target.
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline && !AXIsProcessTrusted() {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    static func selectedWindow(_ args: Arguments) throws -> CaptureWindow {
        let app = try args.required("--app")
        let windowID: UInt32?
        if let raw = args.values["--window-id"] {
            guard let parsed = UInt32(raw) else { throw CLIError("--window-id must be an unsigned integer") }
            windowID = parsed
        } else { windowID = nil }
        return try WindowSelection.select(from: WindowCapture.listWindows(), app: app, windowID: windowID)
    }

    static func capture(_ args: Arguments) async throws -> Int32 {
        let app = try args.required("--app")
        var window = try selectedWindow(args)
        let timeout: Double
        if let raw = args.values["--timeout"] {
            guard let parsed = Double(raw), parsed.isFinite, parsed > 0, parsed <= 300 else {
                throw CLIError("--timeout must be greater than zero and at most 300 seconds")
            }
            timeout = parsed
        } else { timeout = 20 }
        let options = AXCaptureOptions(
            maxNodes: try args.positiveInteger("--max-nodes", default: 12000),
            maxDepth: try args.positiveInteger("--max-depth", default: 100),
            timeoutSeconds: timeout,
            maxTextCharacters: try args.positiveInteger("--max-text-characters", default: 2_000_000)
        )
        let id = UUID().uuidString
        let start = Date()
        let store = try newStore(args, id: id)
        var accessibilityPreparation: ComponentOutcome?
        if args.flags.contains("--enable-electron-ax") {
            let preparation = ElectronAccessibility.enable(pid: window.pid)
            try store.write(preparation, named: "accessibility-preparation.json")
            accessibilityPreparation = ComponentOutcome(status: preparation.status, file: "accessibility-preparation.json")
            // The opt-in request can change the application's accessibility presentation.
            // Refresh this same explicit window's metadata before taking the snapshot.
            window = try WindowSelection.select(from: WindowCapture.listWindows(), app: app, windowID: window.id)
        }
        var screenshot = ComponentOutcome(status: "not_requested")
        var accessibility = ComponentOutcome(status: "not_attempted")
        var ocr = ComponentOutcome(status: "not_requested")
        var context = "OneShot capture \(id)\nApp: \(window.ownerName)\nWindow: \(window.title)\nWindow ID: \(window.id) | PID: \(window.pid)\n\n"

        if !args.flags.contains("--no-image") {
            do {
                let imageResult = try await WindowCapture.capture(window: window, to: store.directory.appendingPathComponent("screenshot.png"))
                try store.write(imageResult, named: "screenshot.json")
                screenshot = ComponentOutcome(status: "captured", file: "screenshot.png")
            } catch {
                screenshot = ComponentOutcome(status: "failed", error: error.localizedDescription)
            }
        }
        do {
            let result = try AXCollector(options: options).capture(pid: window.pid, windowTitle: window.title.isEmpty ? nil : window.title, windowBounds: window.cgRect)
            try store.write(result, named: "accessibility.json")
            context += "[Accessibility — frozen capture]\n" + result.readableText + "\n"
            accessibility = ComponentOutcome(status: result.completeness, file: "accessibility.json")
        } catch {
            if let diagnostic = (error as? AXCaptureError)?.applicationDiagnostic {
                try store.write(diagnostic, named: "accessibility-diagnostic.json")
            }
            accessibility = ComponentOutcome(status: "failed", error: error.localizedDescription)
            context += "[Accessibility failed]\n\(error.localizedDescription)\n"
        }
        // Capture identity is checked before optional OCR, which only reads the frozen PNG.
        let after = WindowCapture.listWindows().first { $0.id == window.id && $0.pid == window.pid }
        let identityStable = after.map { $0.title == window.title && $0.bounds == window.bounds } ?? false
        if args.flags.contains("--ocr") {
            if screenshot.status == "captured" {
                do {
                    let result = try ImageOCR.recognize(imageURL: store.directory.appendingPathComponent("screenshot.png"))
                    try store.write(result, named: "ocr.json")
                    context += "\n[OCR — frozen image only, not AX state]\n" + result.plainText + "\n"
                    ocr = ComponentOutcome(status: "captured", file: "ocr.json")
                } catch { ocr = ComponentOutcome(status: "failed", error: error.localizedDescription) }
            } else { ocr = ComponentOutcome(status: "unavailable", error: "No captured screenshot is available") }
        }
        let bundleURL = NSRunningApplication(processIdentifier: window.pid)?.bundleURL
        let version = bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let manifest = SnapshotManifest(
            captureID: id, startedAt: start, finishedAt: Date(), requestedApp: app,
            applicationVersion: version, window: window, windowAfter: after,
            accessibility: accessibility, screenshot: screenshot, ocr: ocr,
            consistency: identityStable ? "window_identity_stable_content_not_atomic" : "window_changed_or_disappeared",
            notes: [
                "Screenshot and AX are independent reads with their own timestamps; unchanged window identity does not prove atomic or unchanged content.",
                args.flags.contains("--enable-electron-ax")
                    ? "Explicit Electron accessibility preparation was requested before capture; see accessibility-preparation.json. No clicks, scrolling, or focus changes were performed."
                    : "No clicks, scrolling, focus changes, or application setting changes were performed.",
                "AX collection preserves exposed off-screen content; a completed traversal does not prove the app exposed its whole document.",
                "Read captured files offline; this snapshot is never refreshed in place."
            ], accessibilityPreparation: accessibilityPreparation
        )
        try store.writeText(context, named: "context.txt")
        try store.write(manifest, named: "manifest.json")
        print("Capture saved: \(store.directory.path)")
        try printJSON(manifest)
        return accessibility.status == "failed" && screenshot.status != "captured" ? 2 : 0
    }

    static func newStore(_ args: Arguments, id: String) throws -> SnapshotStore {
        let path = args.values["--output"] ?? "Captures/\(id)"
        return try SnapshotStore(newDirectory: URL(fileURLWithPath: path, isDirectory: true))
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        print(String(decoding: try SnapshotStore.encoder.encode(value), as: UTF8.self))
    }

    static let help = """
    OneShot — macOS window context capture probe (macOS 14+)

    oneshot doctor
    oneshot authorize   (explicitly opens standard macOS consent; approval remains manual)
    oneshot windows --app <exact bundle identifier or app name>
    oneshot diagnose --app <app> [--window-id <id>]   (read-only AX window diagnostics)
    oneshot capture --app <bundle identifier or app name> [--window-id <id>]
                    [--output <NEW directory>] [--ocr] [--no-image]
                    [--timeout <seconds>] [--max-nodes <count>] [--max-depth <count>]
                    [--max-text-characters <count>]
                    [--enable-electron-ax] (explicit runtime AXManualAccessibility request)
    oneshot read --capture <existing capture directory>
    oneshot ocr --image <existing image> [--output <NEW directory>]

    A capture saves manifest.json, accessibility.json, context.txt and, when available,
    screenshot.png/screenshot.json and ocr.json. Failures are explicit in the manifest.
    Window selection is explicit and ambiguous matches are rejected. This probe never
    changes focus or scrolls. Electron accessibility is passive unless explicitly enabled
    with --enable-electron-ax; that request and its result are saved. Only 'authorize' requests
    OS permissions; capture and doctor never display consent prompts.
    A successful capture directory is immutable to the CLI. 'read' is entirely offline.
    """
}
