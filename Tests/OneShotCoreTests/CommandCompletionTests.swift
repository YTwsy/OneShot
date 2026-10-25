import Foundation
import Testing
@testable import OneShotCore

struct CommandCompletionTests {
    @Test func successAndFailureReceiptsCarryActualExitCodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-completion-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for exitCode: Int32 in [0, 1, 2] {
            let file = root.appendingPathComponent("receipt-\(exitCode).json")
            try CommandCompletion.write(exitCode: exitCode, command: "capture", startedAt: Date(),
                                         error: exitCode == 0 ? nil : "capture failed", to: file)
            let receipt = try decoder.decode(CommandCompletionReceipt.self, from: Data(contentsOf: file))
            #expect(receipt.exitCode == exitCode)
            #expect(receipt.command == "capture")
            #expect(receipt.schemaVersion == 1)
            #expect(receipt.processID > 0)
            #expect((receipt.error == nil) == (exitCode == 0))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
    }

    @Test func existingReceiptAndSymlinkAreNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-completion-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("receipt.json")
        try CommandCompletion.write(exitCode: 2, command: "capture", startedAt: Date(), to: receipt)
        let original = try Data(contentsOf: receipt)
        #expect(throws: (any Error).self) {
            try CommandCompletion.write(exitCode: 0, command: "capture", startedAt: Date(), to: receipt)
        }
        #expect(try Data(contentsOf: receipt) == original)
        let symlink = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: receipt)
        #expect(throws: (any Error).self) {
            try CommandCompletion.write(exitCode: 0, command: "doctor", startedAt: Date(), to: symlink)
        }
        #expect(try Data(contentsOf: receipt) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["linked.json", "receipt.json"])
    }

    @Test func receiptTargetIsAvailableEvenWhenOtherArgumentsAreInvalid() throws {
        let destination = try CommandCompletion.requestedURL(in: ["capture", "--unknown", "--completion-file", "/private/tmp/run with spaces/receipt.json"])
        #expect(destination?.path == "/private/tmp/run with spaces/receipt.json")
        #expect(try CommandCompletion.requestedURL(in: ["doctor"]) == nil)
        #expect(throws: (any Error).self) { try CommandCompletion.requestedURL(in: ["doctor", "--completion-file"]) }
        #expect(throws: (any Error).self) { try CommandCompletion.requestedURL(in: ["doctor", "--completion-file", "relative.json"]) }
        #expect(throws: (any Error).self) {
            try CommandCompletion.requestedURL(in: ["doctor", "--completion-file", "/a", "--completion-file", "/b"])
        }
    }
}
