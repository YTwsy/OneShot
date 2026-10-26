import Darwin
import Foundation

public struct ProbeCaptureTrigger: Codable, Equatable {
    public let schemaVersion: Int
    public let triggeredAt: Date
    public let requestedApp: String
    public let pid: Int32
    public let window: CaptureWindow
    public let selectionBasis: String
    public let probeBundlePath: String
    public let captureDirectory: String

    public init(schemaVersion: Int = 1, triggeredAt: Date, requestedApp: String, pid: Int32,
                window: CaptureWindow, selectionBasis: String, probeBundlePath: String, captureDirectory: String) {
        self.schemaVersion = schemaVersion; self.triggeredAt = triggeredAt
        self.requestedApp = requestedApp; self.pid = pid; self.window = window
        self.selectionBasis = selectionBasis; self.probeBundlePath = probeBundlePath
        self.captureDirectory = captureDirectory
    }
}

public struct RecoveredProbeRun {
    public let captureDirectory: URL
    public let runDirectory: URL
    public let manifest: SnapshotManifest
    public let receipt: CommandCompletionReceipt
    public let warning: String?
    public let timings: ProbeServiceTimings
    public let phaseTimings: [CapturePhaseTiming]?
}

/// Offline recovery is constrained to runner-owned directories under an explicit root.
public enum ProbeRunRecovery {
    public static func recoverCompletedRuns(outputRoot: URL) throws -> [RecoveredProbeRun] {
        let root = outputRoot.resolvingSymlinksInPath().standardizedFileURL
        let runs = root.appendingPathComponent(".runs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: runs.path) else { return [] }
        let properties = try runs.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else {
            throw AnnotationError.invalidCapture("采集运行记录目录无效。")
        }
        let directories = try FileManager.default.contentsOfDirectory(at: runs,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey], options: [.skipsHiddenFiles])
            .compactMap { url -> (URL, Date)? in
                guard UUID(uuidString: url.lastPathComponent) != nil,
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                return (url, values.creationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }.prefix(128)
        var recovered: [RecoveredProbeRun] = []
        for (directory, _) in directories {
            let delivered = directory.appendingPathComponent("delivered.json")
            guard !FileManager.default.fileExists(atPath: delivered.path),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent("receipt.json").path) else { continue }
            // Invalid, failed, and incomplete runs remain on disk for diagnosis. They
            // must not prevent another valid completed run from being recovered.
            if let result = try? Self.recoverRun(at: directory, root: root) { recovered.append(result) }
        }
        return Array(recovered.reversed())
    }

    public static func acknowledgeDelivery(captureID: String, runDirectory: URL) throws {
        let file = runDirectory.appendingPathComponent("delivered.json")
        if FileManager.default.fileExists(atPath: file.path) { return }
        try writePrivate(Delivery(captureID: captureID, deliveredAt: Date()), to: file)
    }

    static func recoverRun(at candidate: URL, root requestedRoot: URL) throws -> RecoveredProbeRun {
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let directory = candidate.standardizedFileURL
        let runs = root.appendingPathComponent(".runs", isDirectory: true)
        guard directory.deletingLastPathComponent() == runs, UUID(uuidString: directory.lastPathComponent) != nil else {
            throw ProbeCaptureVerificationError.wrongTarget
        }
        for folder in [runs, directory] {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ProbeCaptureVerificationError.wrongTarget
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let triggerData = try readRegular(directory.appendingPathComponent("trigger.json"), maximum: 65_536)
        let trigger = try decoder.decode(ProbeCaptureTrigger.self, from: triggerData)
        guard trigger.schemaVersion == 1, trigger.pid == trigger.window.pid,
              trigger.captureDirectory.hasPrefix("/"), !trigger.requestedApp.isEmpty else {
            throw ProbeCaptureVerificationError.wrongTarget
        }
        let captureURL = URL(fileURLWithPath: trigger.captureDirectory, isDirectory: true).standardizedFileURL
        // Never trust a serialized absolute path to grant filesystem access. A run may
        // refer only to its generated capture directly under the explicitly chosen root.
        guard captureURL.deletingLastPathComponent() == root,
              captureURL.lastPathComponent.hasSuffix("-\(directory.lastPathComponent)") else {
            throw ProbeCaptureVerificationError.wrongTarget
        }
        let captureProperties = try captureURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard captureProperties.isDirectory == true, captureProperties.isSymbolicLink != true else {
            throw ProbeCaptureVerificationError.wrongTarget
        }
        let receipt = try ProbeCaptureVerification.receipt(from: readRegular(directory.appendingPathComponent("receipt.json"), maximum: 65_536))
        let manifest = try decoder.decode(SnapshotManifest.self,
            from: readRegular(captureURL.appendingPathComponent("manifest.json"), maximum: 2_097_152))
        let verified = try ProbeCaptureVerification.verify(receipt: receipt, manifest: manifest,
            requestedApp: trigger.requestedApp, windowID: trigger.window.id, pid: trigger.pid)
        _ = try AnnotationStore.openCapture(at: captureURL)
        let copiedTrigger = captureURL.appendingPathComponent("trigger.json")
        if FileManager.default.fileExists(atPath: copiedTrigger.path) {
            guard try decoder.decode(ProbeCaptureTrigger.self, from: readRegular(copiedTrigger, maximum: 65_536)) == trigger else {
                throw ProbeCaptureVerificationError.wrongTarget
            }
        } else { try writePrivate(trigger, to: copiedTrigger) }
        let storedProgress = (try? readRegular(captureURL.appendingPathComponent("timings.json"), maximum: 65_536))
            .flatMap { try? CaptureProgress.decode($0) }
        let phaseTimings = storedProgress.flatMap { progress in
            progress.captureID == manifest.captureID && progress.processID == receipt.processID ? progress.timings : nil
        }
        let storedTimings = (try? readRegular(directory.appendingPathComponent("service-timings.json"), maximum: 65_536))
            .flatMap { try? decoder.decode(ProbeServiceTimings.self, from: $0) }
        let timings = ProbeServiceTimings(launchCallbackMilliseconds: storedTimings?.launchCallbackMilliseconds,
            receiptObservedMilliseconds: storedTimings?.receiptObservedMilliseconds,
            verificationMilliseconds: storedTimings?.verificationMilliseconds,
            totalMilliseconds: storedTimings?.totalMilliseconds,
            phaseTimingsAvailable: storedProgress?.captureID == manifest.captureID
                && storedProgress?.processID == receipt.processID && storedProgress?.hasComponentTimings == true)
        return RecoveredProbeRun(captureDirectory: captureURL, runDirectory: directory, manifest: manifest,
            receipt: receipt, warning: verified.warning, timings: timings, phaseTimings: phaseTimings)
    }

    private static func writePrivate<T: Encodable>(_ value: T, to destination: URL) throws {
        let data = try SnapshotStore.encoder.encode(value)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".oneshot-delivery-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += count
            }
        }
        guard Darwin.link(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    private static func readRegular(_ url: URL, maximum: Int) throws -> Data {
        try AnnotationStore.readRegular(url, maximum: maximum)
    }

    private struct Delivery: Codable {
        let captureID: String
        let deliveredAt: Date
    }
}
