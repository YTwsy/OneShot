import Foundation

public enum ProbeCaptureVerificationError: LocalizedError {
    case invalidReceipt
    case wrongTarget
    case noScreenshot(String?)

    public var errorDescription: String? {
        switch self {
        case .invalidReceipt: return "采集完成回执无效，不能确认本次执行结果。"
        case .wrongTarget: return "采集结果与触发时的应用或窗口不一致，未打开其他目标。"
        case .noScreenshot(let detail): return "本次未取得可编辑的截图。" + (detail.map { " \($0)" } ?? "")
        }
    }
}

public struct VerifiedProbeCapture {
    public let manifest: SnapshotManifest
    public let receipt: CommandCompletionReceipt
    public let warning: String?
}

/// The launch callback is not a completion signal. A private receipt and a matching
/// capture manifest are required before the editor may open the resulting screenshot.
public enum ProbeCaptureVerification {
    public static func receipt(from data: Data) throws -> CommandCompletionReceipt {
        guard data.count <= 65_536 else { throw ProbeCaptureVerificationError.invalidReceipt }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let receipt = try decoder.decode(CommandCompletionReceipt.self, from: data)
        guard receipt.schemaVersion == 1, receipt.command == "capture",
              (0...255).contains(receipt.exitCode), receipt.processID > 0,
              receipt.finishedAt >= receipt.startedAt else {
            throw ProbeCaptureVerificationError.invalidReceipt
        }
        return receipt
    }

    public static func verify(receipt: CommandCompletionReceipt, manifest: SnapshotManifest,
                              requestedApp: String, windowID: UInt32, pid: Int32) throws -> VerifiedProbeCapture {
        guard receipt.schemaVersion == 1, receipt.command == "capture",
              (0...255).contains(receipt.exitCode), receipt.processID > 0,
              receipt.finishedAt >= receipt.startedAt else { throw ProbeCaptureVerificationError.invalidReceipt }
        guard manifest.schemaVersion == 1, manifest.requestedApp == requestedApp,
              manifest.window.id == windowID, manifest.window.pid == pid,
              manifest.window.bundleIdentifier == nil || manifest.window.bundleIdentifier == requestedApp else {
            throw ProbeCaptureVerificationError.wrongTarget
        }
        guard manifest.screenshot.status == "captured", manifest.screenshot.file == "screenshot.png" else {
            throw ProbeCaptureVerificationError.noScreenshot(manifest.screenshot.error ?? receipt.error)
        }
        var warnings: [String] = []
        if receipt.exitCode != 0 { warnings.append("采集退出码为 \(receipt.exitCode)，已保留可用截图") }
        if manifest.accessibility.status == "failed" { warnings.append("控件读取失败，仍可标注截图") }
        else if manifest.accessibility.status.hasPrefix("partial_") { warnings.append("部分控件信息未完整取得") }
        if manifest.ocr.status == "failed" { warnings.append("图片文字识别未完成") }
        if manifest.consistency != "window_identity_stable_content_not_atomic" { warnings.append("采集期间窗口状态发生变化") }
        return VerifiedProbeCapture(manifest: manifest, receipt: receipt,
                                    warning: warnings.isEmpty ? nil : warnings.joined(separator: "；"))
    }
}
