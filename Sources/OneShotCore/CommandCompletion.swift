import Darwin
import Foundation

/// A LaunchServices launcher cannot infer the application's exit code from `open`.
/// This receipt is published only after the CLI has finished and flushed its output.
public struct CommandCompletionReceipt: Codable {
    public let schemaVersion: Int
    public let command: String
    public let exitCode: Int32
    public let processID: Int32
    public let startedAt: Date
    public let finishedAt: Date
    public let error: String?
}

public enum CommandCompletionError: LocalizedError {
    case invalidArgument
    case invalidExitCode

    public var errorDescription: String? {
        switch self {
        case .invalidArgument:
            return "--completion-file must appear once with an absolute file path."
        case .invalidExitCode:
            return "A command completion exit code must be between 0 and 255."
        }
    }
}

public enum CommandCompletion {
    /// Parse before the main argument parser so ordinary argument errors also get a receipt.
    /// An invalid or ambiguous receipt argument cannot safely designate a destination.
    public static func requestedURL(in arguments: [String]) throws -> URL? {
        let indices = arguments.indices.filter { arguments[$0] == "--completion-file" }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, let index = indices.first, index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("/"), arguments[index + 1] != "/" else {
            throw CommandCompletionError.invalidArgument
        }
        return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
    }

    /// The parent directory must already exist. Existing receipts are never overwritten.
    /// A private sibling file is linked to the final name atomically, so a reader sees
    /// either no receipt or its complete JSON; link also provides exclusive publication.
    public static func write(exitCode: Int32, command: String, startedAt: Date,
                             error: String? = nil, to destination: URL) throws {
        guard (0...255).contains(exitCode) else { throw CommandCompletionError.invalidExitCode }
        let receipt = CommandCompletionReceipt(schemaVersion: 1, command: command, exitCode: exitCode,
                                               processID: getpid(), startedAt: startedAt,
                                               finishedAt: Date(), error: error)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(receipt)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".oneshot-receipt-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard link(temporary.path, destination.path) == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "Cannot publish command completion without overwriting: \(destination.path) (errno \(code))."
            ])
        }
    }
}
