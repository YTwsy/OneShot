import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OneShotCore

struct ProbeRunRecoveryTests {
    @Test func lateReceiptIsRecoverableUntilPersistentDeliveryIsAcknowledged() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try completedRun(in: root)
        #expect(!FileManager.default.fileExists(atPath: fixture.capture.appendingPathComponent("trigger.json").path))
        let first = try #require(ProbeRunRecovery.recoverCompletedRuns(outputRoot: root).first)
        #expect(first.captureDirectory == fixture.capture)
        #expect(first.manifest.captureID == "recovery-fixture")
        #expect(first.warning?.contains("部分控件信息") == true)
        #expect(first.phaseTimings == nil)
        #expect(first.timings.totalMilliseconds == nil)
        #expect(try Data(contentsOf: fixture.capture.appendingPathComponent("trigger.json"))
            == Data(contentsOf: fixture.run.appendingPathComponent("trigger.json")))
        // Returning a result is not delivery: a failed index write must remain retryable.
        #expect(try ProbeRunRecovery.recoverCompletedRuns(outputRoot: root).count == 1)
        try ProbeRunRecovery.acknowledgeDelivery(captureID: first.manifest.captureID, runDirectory: first.runDirectory)
        #expect(try ProbeRunRecovery.recoverCompletedRuns(outputRoot: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.capture.appendingPathComponent("screenshot.png").path))
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.run.appendingPathComponent("delivered.json").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func corruptAndWrongTargetRunsDoNotHideOtherCompletedCaptures() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try completedRun(in: root)
        let wrong = try completedRun(in: root)
        let manifestURL = wrong.capture.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["requestedApp"] = "another.application"
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        #expect(throws: (any Error).self) { try ProbeRunRecovery.recoverRun(at: wrong.run, root: root) }
        let incomplete = try completedRun(in: root)
        try FileManager.default.removeItem(at: incomplete.run.appendingPathComponent("receipt.json"))
        let results = try ProbeRunRecovery.recoverCompletedRuns(outputRoot: root)
        #expect(results.count == 1)
        #expect(results.first?.captureDirectory == valid.capture)
        #expect(!FileManager.default.fileExists(atPath: wrong.capture.appendingPathComponent("trigger.json").path))
    }

    @Test func serializedPathsAndLinksCannotExpandRecoveryScope() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try completedRun(in: root)
        let triggerURL = fixture.run.appendingPathComponent("trigger.json")
        let original = try Data(contentsOf: triggerURL)
        var trigger = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        trigger["captureDirectory"] = root.deletingLastPathComponent().appendingPathComponent(fixture.capture.lastPathComponent).path
        try JSONSerialization.data(withJSONObject: trigger).write(to: triggerURL)
        #expect(throws: (any Error).self) { try ProbeRunRecovery.recoverRun(at: fixture.run, root: root) }
        try original.write(to: triggerURL)
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: fixture.capture, to: moved)
        try FileManager.default.createSymbolicLink(at: fixture.capture, withDestinationURL: moved)
        #expect(throws: (any Error).self) { try ProbeRunRecovery.recoverRun(at: fixture.run, root: root) }
        #expect(try ProbeRunRecovery.recoverCompletedRuns(outputRoot: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("trigger.json").path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory.resolvingSymlinksInPath().standardizedFileURL
    }

    private func completedRun(in root: URL) throws -> (run: URL, capture: URL) {
        let id = UUID().uuidString
        let run = try SnapshotStore(newDirectory: root.appendingPathComponent(".runs/\(id)", isDirectory: true))
        let capture = try SnapshotStore(newDirectory: root.appendingPathComponent("20261026-120000-\(id)", isDirectory: true))
        let window = CaptureWindow(id: 7, pid: 42, ownerName: "Fixture", title: "Frozen window",
            bounds: .init(x: 0, y: 0, width: 8, height: 8), isOnScreen: true, bundleIdentifier: "example.fixture")
        try run.write(ProbeCaptureTrigger(triggeredAt: Date(timeIntervalSince1970: 0), requestedApp: "example.fixture",
            pid: 42, window: window, selectionBasis: "fixture", probeBundlePath: "/not-opened/Probe.app",
            captureDirectory: capture.directory.path), named: "trigger.json")
        try capture.write(SnapshotManifest(captureID: "recovery-fixture", startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1), requestedApp: "example.fixture", applicationVersion: nil,
            window: window, windowAfter: window, accessibility: .init(status: "partial_read_errors"),
            screenshot: .init(status: "captured", file: "screenshot.png"), ocr: .init(status: "not_requested"),
            consistency: "window_identity_stable_content_not_atomic", notes: []), named: "manifest.json")
        try capture.writeText("Frozen context", named: "context.txt")
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let png = try #require(CGImageDestinationCreateWithURL(capture.directory.appendingPathComponent("screenshot.png") as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(png, image, nil)
        #expect(CGImageDestinationFinalize(png))
        try CommandCompletion.write(exitCode: 0, command: "capture", startedAt: Date(), to: run.directory.appendingPathComponent("receipt.json"))
        return (run.directory, capture.directory)
    }
}
