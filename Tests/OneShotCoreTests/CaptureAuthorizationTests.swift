import Foundation
import Testing
@testable import OneShotCore

struct CaptureAuthorizationTests {
    @Test func selectedPermissionNeverInvokesTheOtherConsentStep() throws {
        #expect(try CapturePermissionKind.requestedPermissions(option: "screen-recording") == [.screenRecording])
        #expect(try CapturePermissionKind.requestedPermissions(option: "accessibility") == [.accessibility])
        #expect(try CapturePermissionKind.requestedPermissions(option: nil) == [.screenRecording, .accessibility])
        #expect(throws: (any Error).self) { try CapturePermissionKind.requestedPermissions(option: "camera") }
    }

    @Test func permissionGrantAndSettingsInstructionsStaySeparate() throws {
        let data = Data(#"{"accessibility":"granted","screenRecording":"not_granted"}"#.utf8)
        let status = try CapturePermissionStatus.decode(data)
        #expect(status.grant(for: .accessibility) == .granted)
        #expect(status.grant(for: .screenRecording) == .notGranted)
        #expect(!status.allGranted)
        #expect(CapturePermissionKind.screenRecording.settingsURL.absoluteString.contains("Privacy_ScreenCapture"))
        #expect(CapturePermissionKind.accessibility.settingsURL.absoluteString.contains("Privacy_Accessibility"))
        #expect(CapturePermissionKind.screenRecording.settingsPathDescription.contains("隐私与安全性"))
    }

    @Test func requestReportPreservesAnUnapprovedResultWithoutClaimingPermissionGrant() throws {
        let attempt = CaptureAuthorizationAttempt(permission: .screenRecording,
            requestedAt: Date(timeIntervalSince1970: 1_000), alreadyGranted: false,
            requestInvoked: true, apiReturnedGranted: false)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(CaptureAuthorizationAttempt.self,
            from: SnapshotStore.encoder.encode(attempt))
        #expect(restored == attempt)
        #expect(restored.requestInvoked)
        #expect(!restored.apiReturnedGranted)
    }
}
