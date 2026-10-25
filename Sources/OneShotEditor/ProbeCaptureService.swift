import AppKit
import Foundation
import OneShotCore

struct ProbeCaptureResult {
    let captureDirectory: URL
    let runDirectory: URL
    let manifest: SnapshotManifest
    let receipt: CommandCompletionReceipt
    let warning: String?
}

enum ProbeCaptureServiceError: LocalizedError {
    case invalidProbe
    case targetChanged
    case busy(URL)
    case incomplete(URL, String?)
    case resultUnavailable(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidProbe:
            return "未找到可用的 OneShot Probe。请在采集设置中选择已授权的 OneShot Probe.app。"
        case .targetChanged:
            return "触发时的应用或窗口已不可用，请回到目标窗口再试。"
        case .busy(let directory):
            return "上一次采集仍在执行或结果尚未确认，未重复启动。记录：\(directory.path)"
        case .incomplete(let directory, let detail):
            return "等待采集完成超时或已停止等待；采集进程未被终止，也未自动重试。记录：\(directory.path)" + (detail.map { "\n\($0)" } ?? "")
        case .resultUnavailable(let directory, let detail):
            return "\(detail)\n本次记录：\(directory.path)"
        }
    }
}

@MainActor
final class ProbeCaptureService {
    private final class ActiveRun {
        let directory: URL
        let receiptURL: URL
        var application: NSRunningApplication?
        var launchError: String?
        var postLaunchTargetValid: Bool?
        var receiptProcessID: Int32?
        init(directory: URL, receiptURL: URL) { self.directory = directory; self.receiptURL = receiptURL }
    }
    private var activeRun: ActiveRun?

    static func defaultProbeURL(editorBundleURL: URL = Bundle.main.bundleURL) -> URL {
        editorBundleURL.deletingLastPathComponent().appendingPathComponent("OneShot Probe.app", isDirectory: true)
    }

    static var defaultOutputRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OneShot/Captures", isDirectory: true)
    }

    static func validateProbe(at url: URL) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension.lowercased() == "app", let bundle = Bundle(url: resolved),
              bundle.bundleIdentifier == "dev.oneshot.capture-probe",
              let executable = bundle.executableURL,
              executable.resolvingSymlinksInPath().path.hasPrefix(resolved.path + "/Contents/MacOS/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProbeCaptureServiceError.invalidProbe
        }
    }

    func capture(appBundleIdentifier: String, window: CaptureWindow, triggeredAt: Date,
                 probeURL: URL, outputRoot: URL? = nil, timeoutSeconds: TimeInterval = 120,
                 selectionBasis: String = "frontmost_application_and_front_to_back_normal_window") async throws -> ProbeCaptureResult {
        try releaseFinishedRunOrReject()
        try Self.validateProbe(at: probeURL)
        guard Self.targetIsAvailable(appBundleIdentifier: appBundleIdentifier, window: window) else {
            throw ProbeCaptureServiceError.targetChanged
        }
        let root = (outputRoot ?? Self.defaultOutputRoot).resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let runsRoot = root.appendingPathComponent(".runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let runID = UUID().uuidString
        let runStore = try SnapshotStore(newDirectory: runsRoot.appendingPathComponent(runID, isDirectory: true))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let captureURL = root.appendingPathComponent("\(formatter.string(from: triggeredAt))-\(runID)", isDirectory: true)
        let trigger = Trigger(schemaVersion: 1, triggeredAt: triggeredAt, requestedApp: appBundleIdentifier,
                              pid: window.pid, window: window, selectionBasis: selectionBasis,
                              probeBundlePath: probeURL.path, captureDirectory: captureURL.path)
        try runStore.write(trigger, named: "trigger.json")
        let run = ActiveRun(directory: runStore.directory, receiptURL: runStore.directory.appendingPathComponent("receipt.json"))
        // Set before LaunchServices: repeated hotkeys must never start overlapping work.
        activeRun = run
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = ["capture", "--app", appBundleIdentifier, "--window-id", String(window.id),
                                   "--output", captureURL.path, "--ocr", "--completion-file", run.receiptURL.path,
                                   "--working-directory", root.path]
        NSWorkspace.shared.openApplication(at: probeURL, configuration: configuration) { application, error in
            Task { @MainActor in
                run.application = application
                run.launchError = error?.localizedDescription
                run.postLaunchTargetValid = Self.targetIsAvailable(appBundleIdentifier: appBundleIdentifier, window: window)
            }
        }
        defer {
            try? runStore.write(LaunchObservation(launchError: run.launchError,
                postLaunchTargetValid: run.postLaunchTargetValid, receiptProcessID: run.receiptProcessID), named: "launch.json")
        }
        let duration = timeoutSeconds.isFinite ? min(300, max(1, timeoutSeconds)) : 120
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(duration * 1000)))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if FileManager.default.fileExists(atPath: run.receiptURL.path) {
                do {
                    let receipt = try ProbeCaptureVerification.receipt(from: Self.readRegular(run.receiptURL, maximum: 65_536))
                    run.receiptProcessID = receipt.processID
                    // A valid receipt establishes process completion even if the launch callback failed.
                    activeRun = nil
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let manifest = try decoder.decode(SnapshotManifest.self,
                        from: Self.readRegular(captureURL.appendingPathComponent("manifest.json"), maximum: 2_097_152))
                    let verified = try ProbeCaptureVerification.verify(receipt: receipt, manifest: manifest,
                        requestedApp: appBundleIdentifier, windowID: window.id, pid: window.pid)
                    _ = try AnnotationStore.openCapture(at: captureURL)
                    // Preserve trigger context with the immutable capture copied into future projects.
                    let triggerData = try SnapshotStore.encoder.encode(trigger)
                    let triggerURL = captureURL.appendingPathComponent("trigger.json")
                    try triggerData.write(to: triggerURL, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: triggerURL.path)
                    return ProbeCaptureResult(captureDirectory: captureURL, runDirectory: run.directory,
                                              manifest: manifest, receipt: receipt, warning: verified.warning)
                } catch {
                    throw ProbeCaptureServiceError.resultUnavailable(run.directory, error.localizedDescription)
                }
            }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
        }
        // Do not clear activeRun: a slow Probe may still be capturing. A later trigger
        // must observe its receipt or termination before another process can be launched.
        throw ProbeCaptureServiceError.incomplete(run.directory, run.launchError)
    }

    private func releaseFinishedRunOrReject() throws {
        guard let run = activeRun else { return }
        if (try? Self.readRegular(run.receiptURL, maximum: 65_536)).flatMap({ try? ProbeCaptureVerification.receipt(from: $0) }) != nil
            || run.application?.isTerminated == true {
            activeRun = nil
        } else { throw ProbeCaptureServiceError.busy(run.directory) }
    }

    private static func targetIsAvailable(appBundleIdentifier: String, window: CaptureWindow) -> Bool {
        guard !appBundleIdentifier.isEmpty, let app = NSRunningApplication(processIdentifier: window.pid),
              !app.isTerminated, app.bundleIdentifier == appBundleIdentifier else { return false }
        return WindowCapture.listWindows().contains { current in
            current.id == window.id && current.pid == window.pid && current.bundleIdentifier == appBundleIdentifier
                && current.isOnScreen && current.layer == 0 && current.alpha > 0
        }
    }

    private static func readRegular(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= maximum else {
            throw ProbeCaptureVerificationError.invalidReceipt
        }
        return try Data(contentsOf: url)
    }

    private struct Trigger: Codable {
        let schemaVersion: Int
        let triggeredAt: Date
        let requestedApp: String
        let pid: Int32
        let window: CaptureWindow
        let selectionBasis: String
        let probeBundlePath: String
        let captureDirectory: String
    }
    private struct LaunchObservation: Codable {
        let launchError: String?
        let postLaunchTargetValid: Bool?
        let receiptProcessID: Int32?
    }
}
