import Foundation
import Testing
@testable import OneShotCore

struct ProbeCaptureVerificationTests {
    @Test func partialAXCaptureRemainsEditableAndPreservesRealExitCode() throws {
        let outcome = try ProbeCaptureVerification.verify(receipt: receipt(exitCode: 0),
            manifest: manifest(ax: "failed"), requestedApp: "dev.example.app", windowID: 123, pid: 456)
        #expect(outcome.warning?.contains("控件读取失败") == true)
        #expect(outcome.receipt.exitCode == 0)
        let nonzero = try ProbeCaptureVerification.verify(receipt: receipt(exitCode: 2),
            manifest: manifest(ax: "partial_read_errors"), requestedApp: "dev.example.app", windowID: 123, pid: 456)
        #expect(nonzero.warning?.contains("退出码为 2") == true)
        #expect(nonzero.receipt.exitCode == 2)
    }

    @Test func completionReceiptCannotValidateWrongAppProcessOrWindow() throws {
        for (app, windowID, pid) in [("dev.other.app", UInt32(123), Int32(456)),
                                     ("dev.example.app", UInt32(124), Int32(456)),
                                     ("dev.example.app", UInt32(123), Int32(457))] {
            #expect(throws: ProbeCaptureVerificationError.self) {
                try ProbeCaptureVerification.verify(receipt: receipt(), manifest: manifest(),
                    requestedApp: app, windowID: windowID, pid: pid)
            }
        }
        #expect(throws: ProbeCaptureVerificationError.self) {
            try ProbeCaptureVerification.verify(receipt: receipt(), manifest: manifest(owner: "dev.other.app"),
                requestedApp: "dev.example.app", windowID: 123, pid: 456)
        }
    }

    @Test func successfulExitWithoutScreenshotDoesNotOpenEditor() throws {
        #expect(throws: ProbeCaptureVerificationError.self) {
            try ProbeCaptureVerification.verify(receipt: receipt(exitCode: 0), manifest: manifest(image: "failed"),
                requestedApp: "dev.example.app", windowID: 123, pid: 456)
        }
        let result = try ProbeCaptureVerification.verify(receipt: receipt(), manifest: manifest(),
            requestedApp: "dev.example.app", windowID: 123, pid: 456)
        #expect(result.warning == nil)
    }

    @Test func malformedOrUnrelatedReceiptsDoNotReleasePendingCapture() throws {
        for invalid in [receipt(schema: 2), receipt(command: "doctor"), receipt(exitCode: 256),
                        receipt(process: 0), receipt(finishedAt: Date(timeIntervalSince1970: 0))] {
            #expect(throws: ProbeCaptureVerificationError.self) {
                try ProbeCaptureVerification.receipt(from: SnapshotStore.encoder.encode(invalid))
            }
        }
        let read = try ProbeCaptureVerification.receipt(from: SnapshotStore.encoder.encode(receipt(exitCode: 7)))
        #expect(read.exitCode == 7)
    }

    private func receipt(schema: Int = 1, command: String = "capture", exitCode: Int32 = 0,
                         process: Int32 = 789, finishedAt: Date = Date(timeIntervalSince1970: 200)) -> CommandCompletionReceipt {
        CommandCompletionReceipt(schemaVersion: schema, command: command, exitCode: exitCode, processID: process,
            startedAt: Date(timeIntervalSince1970: 100), finishedAt: finishedAt, error: nil)
    }

    private func manifest(ax: String = "completed_requested_reads_application_exposure_unknown", image: String = "captured",
                          owner: String = "dev.example.app") -> SnapshotManifest {
        SnapshotManifest(captureID: UUID().uuidString, startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200), requestedApp: "dev.example.app", applicationVersion: nil,
            window: CaptureWindow(id: 123, pid: 456, ownerName: "Example", title: "Window",
                bounds: CaptureRect(x: 0, y: 0, width: 800, height: 600), isOnScreen: true, bundleIdentifier: owner),
            windowAfter: nil, accessibility: ComponentOutcome(status: ax),
            screenshot: ComponentOutcome(status: image, file: image == "captured" ? "screenshot.png" : nil),
            ocr: ComponentOutcome(status: "captured"), consistency: "window_identity_stable_content_not_atomic", notes: [])
    }
}
