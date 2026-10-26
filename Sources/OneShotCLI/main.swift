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
        let valueOptions: Set<String> = ["--app", "--window-id", "--output", "--capture", "--image", "--timeout", "--max-nodes", "--max-depth", "--max-text-characters", "--completion-file", "--working-directory", "--permission"]
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

/// Best-effort telemetry never changes whether a screenshot/context capture succeeds.
private final class CaptureTelemetry {
    private let writer: CaptureProgressWriter?
    private var phase: CapturePhase = .startup
    private var phaseStarted: TimeInterval
    private var timings: [CapturePhaseTiming] = []
    var captureID: String?

    init(started: TimeInterval, completionURL: URL?) {
        phaseStarted = started
        writer = completionURL.map { CaptureProgressWriter(destination: CaptureProgressWriter.sidecarURL(completionURL: $0)) }
        publish()
    }

    func begin(_ next: CapturePhase) {
        phase = next; phaseStarted = ProcessInfo.processInfo.systemUptime; publish()
    }

    func finish(_ status: String) {
        timings.append(CapturePhaseTiming(phase: phase,
            durationMilliseconds: max(0, (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1000), status: status))
    }

    var snapshot: CaptureProgress { CaptureProgress(captureID: captureID, phase: phase, timings: timings) }
    func completed() { phase = .completed; publish() }
    func failed() {
        if phase != .completed && phase != .failed {
            finish("failed"); phase = .failed; publish()
        }
    }
    private func publish() { try? writer?.write(snapshot) }
}

@MainActor
private final class AuthorizationDelegate: NSObject, NSApplicationDelegate {
    let permissions: [CapturePermissionKind]
    let store: SnapshotStore?
    private let startedAt = Date()
    private(set) var failure: Error?

    init(permissions: [CapturePermissionKind], store: SnapshotStore?) {
        self.permissions = permissions; self.store = store
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Consent is requested only after AppKit has completed normal launch.
        DispatchQueue.main.async { [self] in performRequests() }
    }

    private func performRequests() {
        do {
            try store?.write(RequestStart(schemaVersion: 1, processID: getpid(),
                startedAt: startedAt, permissions: permissions,
                phase: "appkit_did_finish_launching_before_request"), named: "authorization-started.json")
            NSApp.activate(ignoringOtherApps: true)
            var attempts: [CaptureAuthorizationAttempt] = []
            for permission in permissions {
                let requestedAt = Date()
                let alreadyGranted: Bool
                let granted: Bool
                switch permission {
                case .screenRecording:
                    alreadyGranted = WindowCapture.hasScreenRecordingPermission
                    // This is the only screen consent request. Do not replace it
                    // with a preflight check or a status-inferred AX request.
                    granted = alreadyGranted || CGRequestScreenCaptureAccess()
                case .accessibility:
                    alreadyGranted = AXIsProcessTrusted()
                    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                    granted = alreadyGranted || AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                }
                attempts.append(CaptureAuthorizationAttempt(permission: permission,
                    requestedAt: requestedAt, alreadyGranted: alreadyGranted,
                    requestInvoked: !alreadyGranted, apiReturnedGranted: granted))
                print("\(permission.rawValue): \(granted ? "granted at API return" : "request returned without approval; check System Settings")")
            }
            let report = RequestReport(schemaVersion: 1, processID: getpid(), startedAt: startedAt,
                finishedAt: Date(), attempts: attempts,
                note: "A request API return is not a fresh post-approval check. Run doctor in a new helper after returning from System Settings. Only system permission APIs were called; no TCC database reset or edit was performed.")
            try store?.write(report, named: "authorization.json")
            try OneShotCLI.printJSON(report)
        } catch { failure = error }
        fflush(nil)
        // The system owns consent and Settings UI. Once the request API returns,
        // don't leave an idle helper waiting five minutes for only AX permission.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: true)
            }
        }
    }

    private struct RequestStart: Encodable {
        let schemaVersion: Int
        let processID: Int32
        let startedAt: Date
        let permissions: [CapturePermissionKind]
        let phase: String
    }

    private struct RequestReport: Encodable {
        let schemaVersion: Int
        let processID: Int32
        let startedAt: Date
        let finishedAt: Date
        let attempts: [CaptureAuthorizationAttempt]
        let note: String
    }
}

@main
struct OneShotCLI {
    static func main() async {
        let startedAt = Date()
        let started = ProcessInfo.processInfo.systemUptime
        let raw = Array(CommandLine.arguments.dropFirst())
        // Resolve the runner's receipt before argument validation, so malformed commands
        // also finish explicitly. The runner always passes an absolute, new destination.
        var completionURL: URL?
        var exitCode: Int32 = 0
        var failureMessage: String?
        var telemetry: CaptureTelemetry?
        do {
            completionURL = try CommandCompletion.requestedURL(in: raw)
            if raw.first == "capture" { telemetry = CaptureTelemetry(started: started, completionURL: completionURL) }
            let args = try Arguments(raw)
            if let directory = args.values["--working-directory"], !FileManager.default.changeCurrentDirectoryPath(directory) {
                throw CLIError("Cannot use working directory: \(directory)")
            }
            switch args.flags.contains("--help") ? "help" : args.command {
            case "help", "--help", "-h": print(help)
            case "doctor": try doctor(args)
            case "authorize": try authorize(args)
            case "windows":
                let app = try args.required("--app")
                try printJSON(WindowSelection.candidates(from: WindowCapture.listWindows(), app: app))
            case "diagnose":
                let window = try selectedWindow(args)
                try printJSON(AXCollector().inspectApplication(pid: window.pid))
            case "capture": exitCode = try await capture(args, telemetry: telemetry!)
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
            telemetry?.failed()
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

    static func doctor(_ args: Arguments) throws {
        let result: [String: String] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "executable": Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
            "accessibility": AXIsProcessTrusted() ? "granted" : "not_granted",
            "screenRecording": WindowCapture.hasScreenRecordingPermission ? "granted" : "not_granted",
            "permissionsRequested": "false",
            "note": "Only checks this process. No capture, prompts, settings changes, or application activation."
        ]
        if let output = args.values["--output"] {
            let store = try SnapshotStore(newDirectory: URL(fileURLWithPath: output, isDirectory: true))
            try store.write(result, named: "doctor.json")
        }
        try printJSON(result)
    }

    @MainActor
    static func authorize(_ args: Arguments) throws {
        // Only explicit authorize commands enter the AppKit consent lifecycle.
        // System Settings approval remains manual; doctor never calls these APIs.
        let permissions = try CapturePermissionKind.requestedPermissions(option: args.values["--permission"])
        let store = try args.values["--output"].map { try SnapshotStore(newDirectory: URL(fileURLWithPath: $0, isDirectory: true)) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AuthorizationDelegate(permissions: permissions, store: store)
        application.delegate = delegate
        // Running AppKit lets launch registration finish and consent UI receive
        // native events. Task.sleep alone did not provide this application lifecycle.
        application.run()
        application.delegate = nil
        withExtendedLifetime(delegate) {}
        if let error = delegate.failure { throw error }
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

    private static func capture(_ args: Arguments, telemetry: CaptureTelemetry) async throws -> Int32 {
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
        telemetry.captureID = id
        defer {
            if telemetry.snapshot.phase != .completed { telemetry.failed() }
            // Also retain completed phase durations when a later file write fails.
            try? store.write(telemetry.snapshot, named: "timings.json")
        }
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

        telemetry.finish("completed")
        telemetry.begin(.screenshot)
        if !args.flags.contains("--no-image") {
            do {
                let imageResult = try await WindowCapture.capture(window: window, to: store.directory.appendingPathComponent("screenshot.png"))
                try store.write(imageResult, named: "screenshot.json")
                screenshot = ComponentOutcome(status: "captured", file: "screenshot.png")
            } catch {
                screenshot = ComponentOutcome(status: "failed", error: error.localizedDescription)
            }
        }
        telemetry.finish(screenshot.status)
        telemetry.begin(.accessibility)
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
        telemetry.finish(accessibility.status)
        // Capture identity is checked before optional OCR, which only reads the frozen PNG.
        let after = WindowCapture.listWindows().first { $0.id == window.id && $0.pid == window.pid }
        let identityStable = after.map { $0.title == window.title && $0.bounds == window.bounds } ?? false
        telemetry.begin(.ocr)
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
        telemetry.finish(ocr.status)
        telemetry.begin(.finalize)
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
        telemetry.finish("completed")
        telemetry.completed()
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
    oneshot authorize [--permission screen-recording|accessibility] [--output <NEW directory>]
      Explicitly requests the selected macOS consent; approval remains manual.
      Without --permission, requests Screen Recording then Accessibility for CLI compatibility.
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
    screenshot.png/screenshot.json and ocr.json. Monotonic phase timings are in timings.json.
    With --completion-file, a private <completion-file>.progress.json sidecar reports phases.
    Failures are explicit in the manifest; progress is diagnostic, never a completion receipt.
    Window selection is explicit and ambiguous matches are rejected. This probe never
    changes focus or scrolls. Electron accessibility is passive unless explicitly enabled
    with --enable-electron-ax; that request and its result are saved. Only 'authorize' requests
    OS permissions; capture and doctor never display consent prompts.
    A successful capture directory is immutable to the CLI. 'read' is entirely offline.
    """
}
