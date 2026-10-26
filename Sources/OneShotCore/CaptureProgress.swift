import Darwin
import Foundation

public enum CapturePhase: String, Codable, CaseIterable {
    case startup, screenshot, accessibility, ocr, finalize, completed, failed

    public var displayName: String {
        switch self {
        case .startup: return "正在启动采集组件…"
        case .screenshot: return "正在固定截图…"
        case .accessibility: return "正在读取控件与界面上下文…"
        case .ocr: return "正在识别截图文字…"
        case .finalize: return "正在保存采集结果…"
        case .completed: return "采集已完成，正在载入编辑器…"
        case .failed: return "采集未完成，请查看错误信息。"
        }
    }
}

/// Durations use the process's monotonic clock; wall-clock timestamps are descriptive only.
public struct CapturePhaseTiming: Codable, Equatable {
    public let phase: CapturePhase
    public let durationMilliseconds: Double
    public let status: String

    public init(phase: CapturePhase, durationMilliseconds: Double, status: String) {
        self.phase = phase
        self.durationMilliseconds = durationMilliseconds
        self.status = status
    }
}

public struct CaptureProgress: Codable, Equatable {
    public let schemaVersion: Int
    public let processID: Int32
    public let captureID: String?
    public let phase: CapturePhase
    public let timings: [CapturePhaseTiming]
    public let updatedAt: Date

    public var hasComponentTimings: Bool {
        Set(timings.map(\.phase)).isSuperset(of: [.screenshot, .accessibility, .ocr])
    }

    public init(captureID: String?, phase: CapturePhase, timings: [CapturePhaseTiming], updatedAt: Date = Date()) {
        schemaVersion = 1
        processID = getpid()
        self.captureID = captureID
        self.phase = phase
        self.timings = timings
        self.updatedAt = updatedAt
    }

    public static func decode(_ data: Data) throws -> CaptureProgress {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(CaptureProgress.self, from: data)
        guard value.schemaVersion == 1, value.processID > 0,
              value.timings.count <= CapturePhase.allCases.count,
              Set(value.timings.map(\.phase)).count == value.timings.count,
              value.timings.allSatisfy({ $0.durationMilliseconds.isFinite && $0.durationMilliseconds >= 0
                  && $0.durationMilliseconds <= 3_600_000 && $0.status.utf8.count <= 256 }) else {
            throw AnnotationError.invalidCapture("采集进度记录无效。")
        }
        return value
    }
}

/// Progress is a private sidecar of the runner's receipt, never part of the frozen capture.
/// Legacy Probes don't publish it; launchers can simply display an indeterminate status.
public final class CaptureProgressWriter {
    public static func sidecarURL(completionURL: URL) -> URL {
        completionURL.appendingPathExtension("progress.json")
    }

    private let destination: URL
    private var ownsDestination = false

    public init(destination: URL) { self.destination = destination }

    public func write(_ value: CaptureProgress) throws {
        let data = try SnapshotStore.encoder.encode(value)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".oneshot-progress-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw Self.posixError() }
                offset += written
            }
        }
        if ownsDestination {
            let properties = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
                throw AnnotationError.invalidCapture("采集进度目标已改变。")
            }
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw Self.posixError() }
        } else {
            guard Darwin.link(temporary.path, destination.path) == 0 else { throw Self.posixError() }
            ownsDestination = true
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "无法写入采集进度记录。"])
    }
}

public struct ProbeServiceTimings: Codable {
    public let schemaVersion: Int
    /// LaunchServices callback latency, not the Probe's process-start time.
    public let launchCallbackMilliseconds: Double?
    /// Includes launch and the polling interval (up to 200 ms).
    public let receiptObservedMilliseconds: Double?
    public let verificationMilliseconds: Double?
    public let totalMilliseconds: Double?
    public let phaseTimingsAvailable: Bool

    public init(launchCallbackMilliseconds: Double?, receiptObservedMilliseconds: Double?,
                verificationMilliseconds: Double?, totalMilliseconds: Double?, phaseTimingsAvailable: Bool) {
        schemaVersion = 1
        self.launchCallbackMilliseconds = launchCallbackMilliseconds
        self.receiptObservedMilliseconds = receiptObservedMilliseconds
        self.verificationMilliseconds = verificationMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.phaseTimingsAvailable = phaseTimingsAvailable
    }
}
