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
    @Published private(set) var permissionStatus: CapturePermissionStatus?
    @Published private(set) var permissionCheckError: String?
    @Published var isShowingPermissionGuide = false
    @Published private(set) var authorizationInFlight: CapturePermissionKind?
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
    private var permissionRequestTask: Task<Void, Never>?
    private var permissionRefreshTask: Task<Void, Never>?
    private var hasBegunPermissionOnboarding = false
    private var lastPermissionCheck = Date.distantPast
    private static let guideCompletionKey = "permissionGuideCompleted.v1"
    private var permissionGuideState = PermissionGuideState(previouslyCompleted: false)

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
        permissionGuideState = PermissionGuideState(previouslyCompleted:
            UserDefaults.standard.bool(forKey: Self.guideCompletionKey))
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

    func stop() {
        countdownTask?.cancel(); permissionRequestTask?.cancel(); permissionRefreshTask?.cancel()
        hotKey.unregister(); hud.hide()
    }

    func captureFrontmost() {
        guard !isBusy else { return }
        guard capturePermissionsReady() else { return }
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
        guard capturePermissionsReady() else { return }
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
        panel.message = "选择 OneShot 的内置采集组件，或开发版 OneShot Probe.app；不会重建或更改其系统授权。"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = probeURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProbeCaptureService.validateProbe(at: url)
            probeURL = url
            permissionStatus = nil; lastPermissionReport = nil
            permissionGuideState.invalidate(presentIfMissing: false)
            if !usesEmbeddedCapture { UserDefaults.standard.set(url.path, forKey: "captureProbePath") }
            message = "采集组件已连接。切到目标应用，按 \(GlobalCaptureHotKey.displayString)。"
        } catch { message = error.localizedDescription }
    }

    func checkPermissions() {
        performPermissionCheck(activateEditor: true)
    }

    func beginPermissionOnboarding() {
        guard !hasBegunPermissionOnboarding else { return }
        hasBegunPermissionOnboarding = true
        // The fixed development Probe can predate machine-readable doctor reports.
        // Installed products always contain the matching helper and check on launch.
        guard usesEmbeddedCapture else { return }
        isShowingPermissionGuide = permissionGuideState.isPresented && !model.handoffPresented
        performPermissionCheck(activateEditor: false)
    }

    func refreshPermissionsAfterActivation() {
        guard hasBegunPermissionOnboarding, usesEmbeddedCapture else { return }
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled, !self.isBusy, self.countdown == nil,
                  !self.model.handoffPresented, !self.model.isExportingHandoff,
                  Date().timeIntervalSince(self.lastPermissionCheck) >= 1 else { return }
            self.performPermissionCheck(activateEditor: false)
        }
    }

    func showPermissionGuide() {
        guard !isCapturing, !model.handoffPresented, !model.isExportingHandoff else { return }
        cancelActiveCountdown()
        permissionGuideState.show()
        isShowingPermissionGuide = true
        showEditor()
        if !isBusy { performPermissionCheck(activateEditor: false) }
    }

    func skipPermissionGuide() {
        permissionGuideState.skip()
        isShowingPermissionGuide = false
        message = "可先打开已有采集或项目；开始新采集前需要完成权限设置。"
    }

    func finishPermissionGuide() {
        guard permissionStatus?.allGranted == true, permissionGuideState.finish() else { return }
        UserDefaults.standard.set(true, forKey: Self.guideCompletionKey)
        isShowingPermissionGuide = false
        message = "权限已就绪。切到目标应用，按 \(GlobalCaptureHotKey.displayString) 采集，或使用 3 秒倒计时。"
    }

    private func capturePermissionsReady() -> Bool {
        if authorizationInFlight != nil {
            message = "请先完成系统权限提示，再开始采集。"
            showPermissionGuide()
            return false
        }
        if isShowingPermissionGuide || (usesEmbeddedCapture && permissionStatus?.allGranted != true) {
            showPermissionGuide()
            return false
        }
        return true
    }

    private func cancelActiveCountdown() {
        countdownTask?.cancel(); countdownTask = nil; countdown = nil
    }

    private func performPermissionCheck(activateEditor: Bool) {
        guard !isBusy, countdown == nil else { return }
        isCheckingPermissions = true
        permissionCheckError = nil
        lastPermissionCheck = Date()
        message = "正在检查采集组件的权限，不会弹出系统授权请求…"
        let selectedProbe = probeURL
        Task {
            do {
                let status = try await service.checkPermissions(probeURL: selectedProbe, outputRoot: outputRoot)
                guard selectedProbe == probeURL else { isCheckingPermissions = false; return }
                permissionStatus = status
                let mayPresent = !model.handoffPresented && !model.isExportingHandoff
                permissionGuideState.receive(status, presentIfMissing: usesEmbeddedCapture && mayPresent)
                if mayPresent { isShowingPermissionGuide = permissionGuideState.isPresented }
                lastPermissionReport = status.localizedDescription
                message = status.allGranted
                    ? "采集权限已就绪。切到目标应用，按 \(GlobalCaptureHotKey.displayString) 采集。"
                    : "请在权限引导中分别开启屏幕录制与辅助功能；若未出现系统提示，可打开对应设置。"
            } catch {
                permissionStatus = nil; lastPermissionReport = nil
                permissionCheckError = error.localizedDescription
                let mayPresent = !model.handoffPresented && !model.isExportingHandoff
                permissionGuideState.invalidate(presentIfMissing: usesEmbeddedCapture && mayPresent)
                if mayPresent { isShowingPermissionGuide = permissionGuideState.isPresented }
                message = "未能读取权限状态，请重试检查或重新打开权限引导。"
            }
            isCheckingPermissions = false
            if activateEditor { showEditor() }
        }
    }

    func requestPermission(_ permission: CapturePermissionKind) {
        guard !isBusy, countdown == nil, authorizationInFlight == nil else { return }
        guard permissionStatus?.grant(for: permission) != .granted else { return }
        isLaunchingAuthorization = true
        authorizationInFlight = permission
        permissionCheckError = nil
        message = "正在请求\(permission.displayName)…请在系统提示中操作。"
        let selectedProbe = probeURL
        permissionRequestTask = Task {
            do {
                let directory = try await service.requestAuthorization(permission: permission,
                    probeURL: selectedProbe, outputRoot: outputRoot)
                isLaunchingAuthorization = false
                message = "已请求\(permission.displayName)。如未出现提示，请打开对应的系统设置，然后返回检查。"
                // Receipt completion confirms only that the request ran. It never grants
                // capture; always ask a fresh helper process for the effective TCC status.
                while !Task.isCancelled {
                    if let receipt = try service.authorizationCompletion(in: directory) {
                        authorizationInFlight = nil
                        if receipt.exitCode != 0 {
                            permissionCheckError = receipt.error ?? "系统权限请求未完成，请打开对应设置后重试检查。"
                        }
                        performPermissionCheck(activateEditor: false)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch is CancellationError {
                // Closing the editor does not kill a helper with an active system prompt.
            } catch {
                permissionCheckError = error.localizedDescription
                message = "未能完成权限请求，请打开对应设置后重试检查。"
            }
            isLaunchingAuthorization = false
            authorizationInFlight = nil
        }
    }

    func openPermissionSettings(_ permission: CapturePermissionKind) {
        let opened = NSWorkspace.shared.open(permission.settingsURL)
            || NSWorkspace.shared.open(permission.settingsFallbackURL)
        message = permission == .accessibility
            ? "请在\(permission.settingsPathDescription)中为 \(permissionComponentName) 开启权限，然后返回检查。若开关已开启仍未生效，请查看引导中的修复步骤。"
            : "请在\(permission.settingsPathDescription)中为 OneShot 开启权限，然后返回检查。"
        if !opened { permissionCheckError = "无法打开系统设置，请手动前往\(permission.settingsPathDescription)。" }
    }

    var permissionComponentName: String {
        let bundle = Bundle(url: probeURL)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? probeURL.deletingPathExtension().lastPathComponent
    }

    func revealPermissionComponent() {
        guard FileManager.default.fileExists(atPath: probeURL.path) else {
            message = "找不到采集组件，请从安装位置重新打开 OneShot 后再试。"; return
        }
        NSWorkspace.shared.activateFileViewerSelecting([probeURL])
        message = "已请求 Finder 显示当前采集组件。请在辅助功能设置中添加这个 .app。"
    }

    @discardableResult
    func copyPermissionComponentPath() -> Bool {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(probeURL.path, forType: .string)
        message = copied ? "已复制当前采集组件路径，可在系统设置的添加对话框中按 ⇧⌘G 后粘贴。" : "未能复制路径，请在权限引导中手动选择路径。"
        return copied
    }

    func revealCaptures() {
        guard FileManager.default.fileExists(atPath: outputRoot.path) else {
            message = "首次采集后会在这里保存截图与上下文。"; return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outputRoot.path)
    }
}
