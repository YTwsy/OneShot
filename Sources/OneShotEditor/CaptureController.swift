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
    @Published private(set) var pending: [ReadyCapture] = []
    @Published private(set) var probeURL: URL
    let outputRoot: URL
    var showEditor: () -> Void = {}
    var hideEditor: () -> Void = {}

    private let model: EditorModel
    private let hotKey = GlobalCaptureHotKey()
    private let service = ProbeCaptureService()
    private var countdownTask: Task<Void, Never>?

    init(model: EditorModel, arguments: [String] = CommandLine.arguments) {
        self.model = model
        func option(_ key: String) -> URL? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1),
                  arguments[index + 1].hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        probeURL = option("--probe-app")
            ?? UserDefaults.standard.string(forKey: "captureProbePath").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ProbeCaptureService.defaultProbeURL()
        outputRoot = option("--capture-root") ?? ProbeCaptureService.defaultOutputRoot
    }

    func enableShortcut() {
        do {
            try hotKey.register { [weak self] in self?.captureFrontmost() }
            shortcutRegistered = true
            message = "切到目标应用，按 \(GlobalCaptureHotKey.displayString) 采集。"
        } catch {
            shortcutRegistered = false
            message = error.localizedDescription
        }
    }

    func stop() { countdownTask?.cancel(); hotKey.unregister() }

    func captureFrontmost() {
        guard !isCapturing else { return }
        countdownTask?.cancel(); countdownTask = nil; countdown = nil
        do {
            // This synchronous read must precede any window activation or save prompt.
            let target = try FrontmostCaptureReader.read()
            try ProbeCaptureService.validateProbe(at: probeURL)
            isCapturing = true
            message = "正在采集 \(target.application.name)…"
            let chosenProbe = probeURL
            let previousDocumentID = model.document?.id
            Task {
                do {
                    let result = try await service.capture(appBundleIdentifier: target.appArgument,
                        window: target.window, triggeredAt: target.selectedAt, probeURL: chosenProbe,
                        outputRoot: outputRoot, selectionBasis: target.selectionBasis)
                    isCapturing = false
                    if model.isDirty || NSApp.modalWindow != nil || model.document?.id != previousDocumentID {
                        pending.append(ReadyCapture(directory: result.captureDirectory, applicationName: target.application.name))
                        message = "\(target.application.name) 已采集并保留，准备好后可打开。"
                    } else {
                        if model.open(result.captureDirectory) {
                            message = result.warning ?? "\(target.application.name) 已采集，可以开始标注。"
                        } else {
                            pending.append(ReadyCapture(directory: result.captureDirectory, applicationName: target.application.name))
                            message = "采集文件已保存，编辑器未能打开。可从采集目录重试。"
                        }
                    }
                    showEditor()
                } catch {
                    isCapturing = false
                    message = error.localizedDescription
                    showEditor()
                }
            }
        } catch {
            message = error.localizedDescription
            showEditor()
        }
    }

    func captureAfterCountdown() {
        guard !isCapturing, countdown == nil else { return }
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
        guard !isCapturing, countdown == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择已授权的 OneShot Probe"
        panel.message = "选择现有 OneShot Probe.app；不会重建或更改其系统授权。"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = probeURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProbeCaptureService.validateProbe(at: url)
            probeURL = url
            UserDefaults.standard.set(url.path, forKey: "captureProbePath")
            message = "采集组件已连接。切到目标应用，按 \(GlobalCaptureHotKey.displayString)。"
        } catch { message = error.localizedDescription }
    }

    func revealCaptures() {
        guard FileManager.default.fileExists(atPath: outputRoot.path) else {
            message = "首次采集后会在这里保存截图与上下文。"; return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outputRoot.path)
    }
}
