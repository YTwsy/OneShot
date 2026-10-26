import Foundation
import Testing
@testable import OneShotCore

struct CaptureProgressTests {
    @Test func phaseUpdatesAreCompletePrivateJSONAndDoNotTouchReceipt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("receipt.json")
        let sidecar = CaptureProgressWriter.sidecarURL(completionURL: receipt)
        #expect(sidecar.lastPathComponent == "receipt.json.progress.json")
        let writer = CaptureProgressWriter(destination: sidecar)
        try writer.write(CaptureProgress(captureID: "capture-a", phase: .screenshot, timings: []))
        try writer.write(CaptureProgress(captureID: "capture-a", phase: .accessibility,
            timings: [.init(phase: .screenshot, durationMilliseconds: 32.75, status: "captured")]))
        let decoded = try CaptureProgress.decode(Data(contentsOf: sidecar))
        #expect(decoded.phase == .accessibility)
        #expect(decoded.captureID == "capture-a")
        #expect(decoded.timings.first?.durationMilliseconds == 32.75)
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [sidecar.lastPathComponent])
    }

    @Test func progressCannotReplaceExistingFileOrFollowSymlink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.json")
        let original = Data("keep this file".utf8)
        try original.write(to: existing)
        let value = CaptureProgress(captureID: nil, phase: .startup, timings: [])
        #expect(throws: (any Error).self) { try CaptureProgressWriter(destination: existing).write(value) }
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        #expect(throws: (any Error).self) { try CaptureProgressWriter(destination: link).write(value) }
        #expect(try Data(contentsOf: existing) == original)

        let owned = root.appendingPathComponent("owned.json")
        let writer = CaptureProgressWriter(destination: owned)
        try writer.write(value)
        try FileManager.default.removeItem(at: owned)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: existing)
        #expect(throws: (any Error).self) { try writer.write(value) }
        #expect(try Data(contentsOf: existing) == original)
    }

    @Test func invalidDurationsAndRepeatedPhasesCannotDriveProgress() throws {
        let negative = CaptureProgress(captureID: "test", phase: .ocr,
            timings: [.init(phase: .screenshot, durationMilliseconds: -1, status: "captured")])
        #expect(throws: (any Error).self) { try CaptureProgress.decode(SnapshotStore.encoder.encode(negative)) }
        let repeated = CaptureProgress(captureID: "test", phase: .ocr,
            timings: [.init(phase: .screenshot, durationMilliseconds: 1, status: "captured"),
                      .init(phase: .screenshot, durationMilliseconds: 2, status: "captured")])
        #expect(throws: (any Error).self) { try CaptureProgress.decode(SnapshotStore.encoder.encode(repeated)) }
        let tooLong = CaptureProgress(captureID: "test", phase: .ocr,
            timings: [.init(phase: .accessibility, durationMilliseconds: 3_600_001, status: "captured")])
        #expect(throws: (any Error).self) { try CaptureProgress.decode(SnapshotStore.encoder.encode(tooLong)) }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-progress-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return root
    }
}
