import AppKit
import Darwin
import Foundation
import OneShotCore

struct ProbeCaptureResult {
    let captureDirectory: URL
    let runDirectory: URL
    let manifest: SnapshotManifest
    let receipt: CommandCompletionReceipt
    let warning: String?
    let timings: ProbeServiceTimings
    /// nil means this Probe did not supply phase measurements; no estimate is substituted.
    let phaseTimings: [CapturePhaseTiming]?
}

enum ProbeCaptureServiceError: LocalizedError {
    case invalidProbe
    case targetChanged
    case busy(URL)
    case incomplete(URL, String?)
    case resultUnavailable(URL, String)
    case untrackedProbe

    var errorDescription: String? {
        switch self {
        case .invalidProbe:
            return "未找到可用的 OneShot 采集组件。请检查应用是否完整，或在采集设置中选择已有组件。"
        case .targetChanged:
            return "触发时的应用或窗口已不可用，请回到目标窗口再试。"
        case .busy(let directory):
            return "上一次采集仍在执行或结果尚未确认，未重复启动。记录：\(directory.path)"
        case .incomplete(let directory, let detail):
            return "等待采集完成超时或已停止等待；采集进程未被终止，也未自动重试。记录：\(directory.path)" + (detail.map { "\n\($0)" } ?? "")
        case .resultUnavailable(let directory, let detail):
            return "\(detail)\n本次记录：\(directory.path)"
        case .untrackedProbe:
            return "采集组件仍在运行，暂未启动新的采集。请等待当前操作完成，再从最近采集或采集目录找回结果；不会终止组件或自动重试。"
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
        var launchCallbackMilliseconds: Double?
        var isAwaited = true
        init(directory: URL, receiptURL: URL) { self.directory = directory; self.receiptURL = receiptURL }
    }
    private var activeRun: ActiveRun?
    private final class UtilityRun {
        let command: String
        let directory: URL
        let receiptURL: URL
        var application: NSRunningApplication?
        var launchError: String?
        var launchObserved = false
        init(command: String, directory: URL) {
            self.command = command; self.directory = directory
            receiptURL = directory.appendingPathComponent("receipt.json")
        }
    }
    private var utilityRuns: [UtilityRun] = []

    /// Recover only runner-owned, fully verified captures. Delivery is acknowledged by
    /// the controller after its persistent recent-capture index has been written.
    func recoverCompletedRuns(outputRoot: URL? = nil) throws -> [ProbeCaptureResult] {
        // A run that this instance is actively awaiting must never also be delivered
        // through recovery. Timed-out runs stay here until their receipt/exit is known.
        if let run = activeRun {
            guard !run.isAwaited else { return [] }
            guard FileManager.default.fileExists(atPath: run.receiptURL.path)
                || run.application?.isTerminated == true else { return [] }
            activeRun = nil
        }
        return try ProbeRunRecovery.recoverCompletedRuns(outputRoot: outputRoot ?? Self.defaultOutputRoot).map { run in
            ProbeCaptureResult(captureDirectory: run.captureDirectory, runDirectory: run.runDirectory,
                manifest: run.manifest, receipt: run.receipt, warning: run.warning,
                timings: run.timings, phaseTimings: run.phaseTimings)
        }
    }

    func acknowledgeDelivery(_ result: ProbeCaptureResult) throws {
        try ProbeRunRecovery.acknowledgeDelivery(captureID: result.manifest.captureID, runDirectory: result.runDirectory)
    }

    static func defaultProbeURL(editorBundleURL: URL = Bundle.main.bundleURL) -> URL {
        AppDistribution.captureURL(applicationURL: editorBundleURL,
            applicationBundleIdentifier: Bundle(url: editorBundleURL)?.bundleIdentifier)
    }

    static var defaultOutputRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OneShot/Captures", isDirectory: true)
    }

    static func validateProbe(at url: URL) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension.lowercased() == "app", let bundle = Bundle(url: resolved),
              let identifier = bundle.bundleIdentifier,
              AppDistribution.captureBundleIdentifiers.contains(identifier),
              let executable = bundle.executableURL,
              executable.resolvingSymlinksInPath().path.hasPrefix(resolved.path + "/Contents/MacOS/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProbeCaptureServiceError.invalidProbe
        }
    }

    func capture(appBundleIdentifier: String, window: CaptureWindow, triggeredAt: Date,
                 probeURL: URL, outputRoot: URL? = nil, timeoutSeconds: TimeInterval = 120,
                 selectionBasis: String = "frontmost_application_and_front_to_back_normal_window",
                 progress: ((CaptureProgress) -> Void)? = nil) async throws -> ProbeCaptureResult {
        let serviceStarted = ProcessInfo.processInfo.systemUptime
        try releaseFinishedRunOrReject()
        try rejectUnfinishedUtility()
        // Bundle identity is observed live rather than inferring liveness from a
        // persisted PID, which can be reused after an editor restart.
        try Self.rejectRunningProbe()
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
        let trigger = ProbeCaptureTrigger(schemaVersion: 1, triggeredAt: triggeredAt, requestedApp: appBundleIdentifier,
                              pid: window.pid, window: window, selectionBasis: selectionBasis,
                              probeBundlePath: probeURL.path, captureDirectory: captureURL.path)
        try runStore.write(trigger, named: "trigger.json")
        let run = ActiveRun(directory: runStore.directory, receiptURL: runStore.directory.appendingPathComponent("receipt.json"))
        var receiptObservedMilliseconds: Double?
        var verificationMilliseconds: Double?
        var latestProgress: CaptureProgress?
        let progressURL = CaptureProgressWriter.sidecarURL(completionURL: run.receiptURL)
        func observeProgress(expectedCaptureID: String? = nil) {
            guard let expectedPID = run.receiptProcessID ?? run.application?.processIdentifier,
                  let data = try? Self.readRegular(progressURL, maximum: 65_536),
                  let value = try? CaptureProgress.decode(data),
                  expectedPID == value.processID,
                  expectedCaptureID.map({ $0 == value.captureID }) ?? true,
                  value != latestProgress else { return }
            latestProgress = value
            progress?(value)
        }
        func currentTimings() -> ProbeServiceTimings {
            ProbeServiceTimings(launchCallbackMilliseconds: run.launchCallbackMilliseconds,
                receiptObservedMilliseconds: receiptObservedMilliseconds,
                verificationMilliseconds: verificationMilliseconds,
                totalMilliseconds: max(0, (ProcessInfo.processInfo.systemUptime - serviceStarted) * 1000),
                phaseTimingsAvailable: latestProgress?.hasComponentTimings == true)
        }
        // Set before LaunchServices: repeated hotkeys must never start overlapping work.
        activeRun = run
        defer { run.isAwaited = false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = ["capture", "--app", appBundleIdentifier, "--window-id", String(window.id),
                                   "--output", captureURL.path, "--ocr", "--completion-file", run.receiptURL.path,
                                   "--working-directory", root.path]
        let launchStarted = ProcessInfo.processInfo.systemUptime
        NSWorkspace.shared.openApplication(at: probeURL, configuration: configuration) { application, error in
            Task { @MainActor in
                run.application = application
                run.launchError = error?.localizedDescription
                run.launchCallbackMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - launchStarted) * 1000)
                run.postLaunchTargetValid = Self.targetIsAvailable(appBundleIdentifier: appBundleIdentifier, window: window)
                try? runStore.write(LaunchObservation(launchError: run.launchError,
                    postLaunchTargetValid: run.postLaunchTargetValid, receiptProcessID: nil,
                    applicationProcessID: application?.processIdentifier), named: "launch-callback.json")
            }
        }
        defer {
            try? runStore.write(LaunchObservation(launchError: run.launchError,
                postLaunchTargetValid: run.postLaunchTargetValid, receiptProcessID: run.receiptProcessID,
                applicationProcessID: run.application?.processIdentifier), named: "launch.json")
            try? runStore.write(currentTimings(), named: "service-timings.json")
        }
        let duration = timeoutSeconds.isFinite ? min(300, max(1, timeoutSeconds)) : 120
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(duration * 1000)))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            // This sidecar is optional: legacy, already-authorized Probes receive the
            // same supported arguments and simply provide no granular measurements.
            observeProgress()
            if FileManager.default.fileExists(atPath: run.receiptURL.path) {
                receiptObservedMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - serviceStarted) * 1000)
                let verificationStarted = ProcessInfo.processInfo.systemUptime
                defer { verificationMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - verificationStarted) * 1000) }
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
                    observeProgress(expectedCaptureID: manifest.captureID)
                    if latestProgress?.processID != receipt.processID || latestProgress?.captureID != manifest.captureID {
                        latestProgress = nil
                    }
                    verificationMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - verificationStarted) * 1000)
                    return ProbeCaptureResult(captureDirectory: captureURL, runDirectory: run.directory,
                        manifest: manifest, receipt: receipt, warning: verified.warning,
                        timings: currentTimings(), phaseTimings: latestProgress?.timings)
                } catch {
                    throw ProbeCaptureServiceError.resultUnavailable(run.directory, error.localizedDescription)
                }
            }
            if let launchError = run.launchError, run.application == nil {
                activeRun = nil
                throw ProbeCaptureServiceError.resultUnavailable(run.directory, "无法启动采集组件：\(launchError)")
            }
            if run.application?.isTerminated == true {
                activeRun = nil
                throw ProbeCaptureServiceError.resultUnavailable(run.directory,
                    "采集组件已退出，但未提供完成回执。请检查本次记录后重新采集。")
            }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
        }
        // Do not clear activeRun: a slow Probe may still be capturing. A later trigger
        // must observe its receipt or termination before another process can be launched.
        throw ProbeCaptureServiceError.incomplete(run.directory, run.launchError)
    }

    /// Queries the selected helper's TCC identity. This command never requests consent.
    func checkPermissions(probeURL: URL, outputRoot: URL? = nil) async throws -> CapturePermissionStatus {
        try releaseFinishedRunOrReject()
        pruneUtilities()
        if let previous = utilityRuns.first(where: { $0.command == "doctor" }) {
            throw ProbeCaptureServiceError.busy(previous.directory)
        }
        let run = try launchUtility(command: "doctor", probeURL: probeURL, outputRoot: outputRoot)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if FileManager.default.fileExists(atPath: run.receiptURL.path) {
                let receipt = try Self.utilityReceipt(run)
                utilityRuns.removeAll { $0 === run }
                guard receipt.exitCode == 0 else {
                    throw ProbeCaptureServiceError.resultUnavailable(run.directory,
                        receipt.error ?? "采集组件未能完成权限检查。")
                }
                let reportURL = run.directory.appendingPathComponent("report/doctor.json")
                guard FileManager.default.fileExists(atPath: reportURL.path) else {
                    throw ProbeCaptureServiceError.resultUnavailable(run.directory,
                        "当前采集组件未提供权限报告。请使用随 OneShot 分发的新版组件；已有开发版授权不会自动更改。")
                }
                return try CapturePermissionStatus.decode(Self.readRegular(reportURL, maximum: 65_536))
            }
            if let error = run.launchError {
                utilityRuns.removeAll { $0 === run }
                throw ProbeCaptureServiceError.resultUnavailable(run.directory, "无法启动权限检查：\(error)")
            }
            if run.application?.isTerminated == true {
                utilityRuns.removeAll { $0 === run }
                throw ProbeCaptureServiceError.resultUnavailable(run.directory, "权限检查组件已退出，但未提供完成回执。")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Preserve unknown in-flight work. Capture stays blocked until its receipt or exit.
        throw ProbeCaptureServiceError.incomplete(run.directory, run.launchError)
    }

    /// Only an explicit user action calls this. Return after launch, while the helper
    /// may continue waiting for System Settings; the editor never waits five minutes.
    func requestAuthorization(probeURL: URL, outputRoot: URL? = nil) async throws -> URL {
        try releaseFinishedRunOrReject()
        try rejectUnfinishedUtility()
        try Self.rejectRunningProbe()
        let run = try launchUtility(command: "authorize", probeURL: probeURL, outputRoot: outputRoot)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let error = run.launchError {
                utilityRuns.removeAll { $0 === run }
                throw ProbeCaptureServiceError.resultUnavailable(run.directory, "无法启动授权入口：\(error)")
            }
            if run.application != nil || FileManager.default.fileExists(atPath: run.receiptURL.path) {
                return run.directory
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProbeCaptureServiceError.incomplete(run.directory, run.launchError)
    }

    private func launchUtility(command: String, probeURL: URL, outputRoot: URL?) throws -> UtilityRun {
        try Self.validateProbe(at: probeURL)
        let root = (outputRoot ?? Self.defaultOutputRoot).resolvingSymlinksInPath().standardizedFileURL
        let runsRoot = root.appendingPathComponent(".runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let store = try SnapshotStore(newDirectory: runsRoot.appendingPathComponent("\(command)-\(UUID().uuidString)", isDirectory: true))
        let run = UtilityRun(command: command, directory: store.directory)
        utilityRuns.append(run)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = [command, "--completion-file", run.receiptURL.path, "--working-directory", root.path]
        if command == "doctor" { configuration.arguments += ["--output", run.directory.appendingPathComponent("report").path] }
        NSWorkspace.shared.openApplication(at: probeURL, configuration: configuration) { application, error in
            Task { @MainActor in
                run.application = application
                run.launchError = error?.localizedDescription
                run.launchObserved = true
                try? store.write(["command": command, "launchError": run.launchError ?? "",
                    "processID": application.map { String($0.processIdentifier) } ?? ""], named: "launch.json")
            }
        }
        return run
    }

    private func pruneUtilities() {
        utilityRuns.removeAll { run in
            (try? Self.utilityReceipt(run)) != nil || run.application?.isTerminated == true
                || (run.launchObserved && run.launchError != nil && run.application == nil)
        }
    }

    private func rejectUnfinishedUtility() throws {
        pruneUtilities()
        if let run = utilityRuns.first { throw ProbeCaptureServiceError.busy(run.directory) }
    }

    private static func utilityReceipt(_ run: UtilityRun) throws -> CommandCompletionReceipt {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(CommandCompletionReceipt.self, from: readRegular(run.receiptURL, maximum: 65_536))
        guard receipt.schemaVersion == 1, receipt.command == run.command,
              receipt.processID > 0, receipt.finishedAt >= receipt.startedAt,
              (0...255).contains(receipt.exitCode),
              run.application.map({ $0.processIdentifier == receipt.processID }) ?? true else {
            throw ProbeCaptureVerificationError.invalidReceipt
        }
        return receipt
    }

    private static func rejectRunningProbe() throws {
        guard AppDistribution.captureBundleIdentifiers.allSatisfy({ identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier).allSatisfy(\.isTerminated)
        }) else { throw ProbeCaptureServiceError.untrackedProbe }
    }

    private func releaseFinishedRunOrReject() throws {
        guard let run = activeRun else { return }
        guard !run.isAwaited else { throw ProbeCaptureServiceError.busy(run.directory) }
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

    private struct LaunchObservation: Codable {
        let launchError: String?
        let postLaunchTargetValid: Bool?
        let receiptProcessID: Int32?
        let applicationProcessID: Int32?
    }

}
