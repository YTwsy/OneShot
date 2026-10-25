import Foundation

/// New captures own new directories. Reading a capture never contacts an application.
public final class SnapshotStore {
    public let directory: URL

    public init(newDirectory: URL) throws {
        let path = newDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // mkdir, rather than an existence check followed by creation, reserves the directory atomically.
        guard mkdir(path.path, S_IRWXU) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Cannot reserve a new capture directory (existing captures are never overwritten): \(path.path)"])
        }
        directory = path
    }

    public func write<T: Encodable>(_ value: T, named name: String) throws {
        try writeData(Self.encoder.encode(value), named: name)
    }

    public func writeText(_ text: String, named name: String) throws {
        try writeData(Data(text.utf8), named: name)
    }

    private func writeData(_ data: Data, named name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw NSError(domain: "OneShot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid snapshot file name"])
        }
        let destination = directory.appendingPathComponent(name)
        try data.write(to: destination, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func readContext(from directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("context.txt"), encoding: .utf8)
    }
}

public struct ComponentOutcome: Codable {
    public let status: String
    public let file: String?
    public let error: String?
    public init(status: String, file: String? = nil, error: String? = nil) {
        self.status = status; self.file = file; self.error = error
    }
}

public struct SnapshotManifest: Codable {
    public let schemaVersion: Int
    public let captureID: String
    public let startedAt: Date
    public let finishedAt: Date
    public let requestedApp: String
    public let applicationVersion: String?
    public let window: CaptureWindow
    public let windowAfter: CaptureWindow?
    public let accessibility: ComponentOutcome
    public let accessibilityPreparation: ComponentOutcome?
    public let screenshot: ComponentOutcome
    public let ocr: ComponentOutcome
    public let consistency: String
    public let notes: [String]

    public init(captureID: String, startedAt: Date, finishedAt: Date, requestedApp: String,
                applicationVersion: String?, window: CaptureWindow, windowAfter: CaptureWindow?,
                accessibility: ComponentOutcome, screenshot: ComponentOutcome, ocr: ComponentOutcome,
                consistency: String, notes: [String], accessibilityPreparation: ComponentOutcome? = nil) {
        schemaVersion = 1
        self.captureID = captureID; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.requestedApp = requestedApp; self.applicationVersion = applicationVersion
        self.window = window; self.windowAfter = windowAfter; self.accessibility = accessibility
        self.accessibilityPreparation = accessibilityPreparation
        self.screenshot = screenshot; self.ocr = ocr; self.consistency = consistency; self.notes = notes
    }
}
