import Darwin
import Foundation
import Testing
@testable import OneShotCore

struct CaptureCallerIdentityTests {
    @Test func doctorRetainsFlatStringCompatibilityAndPermissionSemantics() throws {
        let identity = CaptureCallerIdentity(bundleIdentifier: "io.github.ytwsy.oneshot.capture-probe",
            bundlePath: "/Applications/OneShot.app/Contents/Helpers/OneShot Capture.app",
            processID: 123, codeSigningIdentifier: "io.github.ytwsy.oneshot.capture-probe",
            codeSigningCDHash: "0001abcdef", codeSigningRequirement: #"cdhash H"0001abcdef""#)
        var report = ["accessibility": "not_granted", "screenRecording": "granted",
                      "permissionsRequested": "false"]
        report.merge(identity.doctorFields) { _, value in value }
        let data = try SnapshotStore.encoder.encode(report)
        let restored = try JSONDecoder().decode([String: String].self, from: data)
        #expect(restored["processID"] == "123")
        #expect(restored["codeSigningCDHash"] == "0001abcdef")
        #expect(restored["codeSigningRequirement"] == #"cdhash H"0001abcdef""#)
        #expect(restored["permissionsRequested"] == "false")
        let permissionStatus = try CapturePermissionStatus.decode(data)
        #expect(permissionStatus.accessibility == .notGranted)
        #expect(permissionStatus.screenRecording == .granted)
        #expect(!permissionStatus.allGranted)
    }

    @Test func callerIdentityKeepsUnknownSigningEvidenceReadable() throws {
        let identity = CaptureCallerIdentity(bundleIdentifier: "unknown", bundlePath: "/tmp/OneShot.app",
            processID: 123, codeSigningIdentifier: "unknown", codeSigningCDHash: "unknown",
            codeSigningRequirement: "unknown")
        let restored = try JSONDecoder().decode(CaptureCallerIdentity.self,
            from: SnapshotStore.encoder.encode(identity))
        #expect(restored == identity)
        #expect(restored.doctorFields.values.allSatisfy { !$0.isEmpty })
    }

    @Test func currentIdentityReportsThisProcessWithoutRequiringASignature() {
        let identity = CaptureCallerIdentity.current()
        #expect(identity.processID == getpid())
        #expect(identity.bundlePath == Bundle.main.bundleURL.path)
        #expect(identity.doctorFields.values.allSatisfy { !$0.isEmpty })
    }
}
