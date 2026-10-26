import AppKit
import SwiftUI
import OneShotCore

/// Coordinates capture without activating the editor until the frozen result is ready.
@MainActor
final class CaptureController: ObservableObject {
    struct ReadyCapture: Identifiable {
        let id = UUID()
        let directory: URL
        let applicationName: String
    }

    @Published private(set) var isCapturing = false
    @Published private(set) var countdown: Int?
    @Published private(set) var shortcutRegistered = false
    @Published private(set) var message = "切到目标应用，按 ⌃⌥⌘S 采集。"
    @Published private(set) var lastTimingSummary: String?
    @Published private(set) var isCheckingPermissions = false
    @Published private(set) var isLaunchingAuthorization = false
    @Published private(set) var lastPermissionReport: String?
    @Published private(set) var pending: [ReadyCapture] = []
    @Published private(set) var probeURL: URL
    let outputRoot: URL
    let usesEmbeddedCapture: Bool
    var showEditor: () -> Void = {}
    var hideEditor: () -> Void = {}

    private let model: EditorModel
    private let hotKey = GlobalCaptureHotKey()
    private let service = ProbeCaptureService()
    private let hud = CaptureHUD()
    private var countdownTask: Task<Void, Never>?

    init(model: EditorModel, arguments: [String] = CommandLine.arguments) {
        self.model = model
        func option(_ key: String) -> URL? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1),
                  arguments[index + 1].hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        usesEmbeddedCapture = AppDistribution.usesEmbeddedCapture(applicationBundleIdentifier: Bundle.main.bundleIdentifier)
        probeURL = AppDistribution.captureURL(applicationURL: Bundle.main.bundleURL,
            applicationBundleIdentifier: Bundle.main.bundleIdentifier, explicitURL: option("--probe-app"),
            savedDevelopmentURL: UserDefaults.standard.string(forKey: "captureProbePath").map { URL(fileURLWithPath: $0, isDirectory: true) })
        outputRoot = option("--capture-root") ?? ProbeCaptureService.defaultOutputRoot
    }

    var isBusy: Bool { isCapturing || isCheckingPermissions || isLaunchingAuthorization }

    func enableShortcut() {
        do {
            try hotKey.register { [weak self] in self?.captureFrontmost() }
            shortcutRegistered = true
            message = usesEmbeddedCapture
                ? "首次使用可在采集设置中检查并授予权限。切到目标应用，按 \(GlobalCaptureHotKey.displayString) 采集。"
                : "切到目标应用，按 \(GlobalCaptureHotKey.displayString) 采集。"
            recoverCaptures()
        } catch {
            shortcutRegistered = false
            message = error.localizedDescription
        }
    }

    func stop() { countdownTask?.cancel(); hotKey.unregister(); hud.hide() }

    func captureFrontmost() {
        guard !isBusy else { return }
        countdownTask?.cancel(); countdownTask = nil; countdown = nil
        let triggerClock = DispatchTime.now().uptimeNanoseconds
        isCapturing = true
        lastTimingSummary = nil
        hud.begin()
        let feedbackMilliseconds = Self.elapsed(since: triggerClock)
        do {
            // This synchronous read must precede any window activation or save prompt.
            let selectionClock = DispatchTime.now().uptimeNanoseconds
            let target = try FrontmostCaptureReader.read()
            let selectionMilliseconds = Self.elapsed(since: selectionClock)
            try ProbeCaptureService.validateProbe(at: probeURL)
            recoverCompletedCaptures()
            message = "正在采集 \(target.application.name)…"
            hud.update(message)
            let chosenProbe = probeURL
            let previousDocumentID = model.document?.id
            Task {
                do {
                    let result = try await service.capture(appBundleIdentifier: target.appArgument,
                        window: target.window, triggeredAt: target.selectedAt, probeURL: chosenProbe,
                        outputRoot: outputRoot, selectionBasis: target.selectionBasis,
                        progress: { [weak self] progress in
                            guard let self else { return }
                            self.message = progress.phase.displayName
                            self.hud.update(progress.phase.displayName,
                                detail: progress.phase == .ocr ? "正在识别已保存截图中的文字，控件状态以采集结果为准。" : "目标应用保持前台，采集结束后自动打开编辑器。")
                        })
                    let editorClock = DispatchTime.now().uptimeNanoseconds
                    var disposition = "pending"
                    var editorLoadMilliseconds: Double?
                    if model.isDirty || NSApp.modalWindow != nil || model.document?.id != previousDocumentID {
                        pending.append(ReadyCapture(directory: result.captureDirectory, applicationName: target.application.name))
                        model.remember(result.captureDirectory)
                        message = "\(target.application.name) 已采集并保留，准备好后可打开。"
                    } else {
                        if model.open(result.captureDirectory) {
                            disposition = "opened"
                            message = result.warning ?? "\(target.application.name) 已采集，可以开始标注。"
                        } else {
                            disposition = "open_failed"
                            pending.append(ReadyCapture(directory: result.captureDirectory, applicationName: target.application.name))
                            model.remember(result.captureDirectory)
                            message = "采集文件已保存，编辑器未能打开。可从采集目录重试。"
                        }
                        editorLoadMilliseconds = Self.elapsed(since: editorClock)
                    }
                    isCapturing = false
                    hud.hide()
                    let presentationClock = DispatchTime.now().uptimeNanoseconds
                    showEditor()
                    let presentationMilliseconds = Self.elapsed(since: presentationClock)
                    let record = EditorTimings(feedbackRequestMilliseconds: feedbackMilliseconds,
                        targetSelectionMilliseconds: selectionMilliseconds,
                        editorLoadMilliseconds: editorLoadMilliseconds,
                        presentationRequestMilliseconds: presentationMilliseconds,
                        triggerToPresentationRequestMilliseconds: Self.elapsed(since: triggerClock),
                        disposition: disposition)
                    if let store = try? SnapshotStore(newDirectory: result.runDirectory.appendingPathComponent("editor")) {
                        try? store.write(record, named: "timings.json")
                    }
                    if model.recentError == nil,
                       model.recentCaptures.contains(where: { $0.directory.standardizedFileURL == result.captureDirectory.standardizedFileURL }) {
                        try? service.acknowledgeDelivery(result)
                    }
                    let phases = result.timings.phaseTimingsAvailable ? "分段耗时已记录" : "当前组件未报告截图／AX／OCR 分段耗时"
                    lastTimingSummary = String(format: "本次采集 %.2f 秒 · %@", record.triggerToPresentationRequestMilliseconds / 1000, phases)
                } catch {
                    isCapturing = false
                    hud.hide()
                    message = error.localizedDescription
                    showEditor()
                }
            }
        } catch {
            isCapturing = false
            hud.hide()
            message = error.localizedDescription
            showEditor()
        }
    }

    func recoverCaptures() {
        guard !isBusy else { return }
        recoverCompletedCaptures()
    }

    private func recoverCompletedCaptures() {
        do {
            let results = try service.recoverCompletedRuns(outputRoot: outputRoot)
            for result in results {
                let recorded = model.remember(result.captureDirectory)
                if model.document?.sourceCaptureID != result.manifest.captureID,
                   !pending.contains(where: { $0.directory == result.captureDirectory }) {
                    pending.append(ReadyCapture(directory: result.captureDirectory, applicationName: result.manifest.window.ownerName))
                }
                if recorded { try? service.acknowledgeDelivery(result) }
            }
            if !results.isEmpty { message = "已找回 \(results.count) 份完成的采集，可从待打开或最近采集中继续。" }
        } catch { message = "检查历史采集失败：\(error.localizedDescription)；原始文件已保留。" }
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private struct EditorTimings: Codable {
        let feedbackRequestMilliseconds: Double
        let targetSelectionMilliseconds: Double
        let editorLoadMilliseconds: Double?
        /// Measures the synchronous request, not a compositor-confirmed first frame.
        let presentationRequestMilliseconds: Double
        let triggerToPresentationRequestMilliseconds: Double
        let disposition: String
    }

    func captureAfterCountdown() {
        guard !isBusy, countdown == nil else { return }
        countdown = 3
        message = "3 秒后采集，请切到目标应用。"
        hideEditor()
        countdownTask = Task {
            for remaining in stride(from: 3, through: 1, by: -1) {
                countdown = remaining
                message = "\(remaining) 秒后采集，请切到目标应用。"
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            countdownTask = nil; countdown = nil
            captureFrontmost()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel(); countdownTask = nil; countdown = nil
        message = "已取消倒计时。"
    }

    func openPending(_ capture: ReadyCapture) {
        guard model.confirmUnsaved() else { return }
        if model.open(capture.directory) {
            pending.removeAll { $0.id == capture.id }
            message = "已打开 \(capture.applicationName) 的采集。"
        }
    }

    func chooseProbe() {
        guard !isBusy, countdown == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 OneShot 采集组件"
        panel.message = "选择现有 OneShot Capture.app 或开发版 OneShot Probe.app；不会重建或更改其系统授权。"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = probeURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProbeCaptureService.validateProbe(at: url)
            probeURL = url
            if !usesEmbeddedCapture { UserDefaults.standard.set(url.path, forKey: "captureProbePath") }
            message = "采集组件已连接。切到目标应用，按 \(GlobalCaptureHotKey.displayString)。"
        } catch { message = error.localizedDescription }
    }

    func checkPermissions() {
        guard !isBusy, countdown == nil else { return }
        isCheckingPermissions = true
        message = "正在检查采集组件的权限，不会弹出系统授权请求…"
        let selectedProbe = probeURL
        Task {
            do {
                let status = try await service.checkPermissions(probeURL: selectedProbe, outputRoot: outputRoot)
                lastPermissionReport = status.localizedDescription
                message = status.allGranted
                    ? "采集权限已就绪。切到目标应用，按 \(GlobalCaptureHotKey.displayString) 采集。"
                    : "采集权限尚未齐备。请点击“授权采集组件”，在系统设置中批准 OneShot Capture，再重新检查。"
            } catch { message = error.localizedDescription }
            isCheckingPermissions = false
            showEditor()
        }
    }

    func authorizeCapture() {
        guard !isBusy, countdown == nil else { return }
        isLaunchingAuthorization = true
        message = "正在打开采集组件的系统授权入口…"
        let selectedProbe = probeURL
        Task {
            do {
                _ = try await service.requestAuthorization(probeURL: selectedProbe, outputRoot: outputRoot)
                message = "请在系统设置中为 OneShot Capture 批准辅助功能和屏幕录制；开发版组件显示为 OneShot Probe。完成后点击“检查采集权限”。"
                // Do not activate the editor over the System Settings consent workflow.
            } catch { message = error.localizedDescription; showEditor() }
            isLaunchingAuthorization = false
        }
    }

    func revealCaptures() {
        guard FileManager.default.fileExists(atPath: outputRoot.path) else {
            message = "首次采集后会在这里保存截图与上下文。"; return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outputRoot.path)
    }
}
