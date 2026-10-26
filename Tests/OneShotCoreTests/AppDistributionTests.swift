import Foundation
import Testing
@testable import OneShotCore

struct AppDistributionTests {
    @Test func installedAppUsesEmbeddedComponentsAfterMovingAndIgnoresDevelopmentPreference() {
        let installed = URL(fileURLWithPath: "/Applications/OneShot.app", isDirectory: true)
        let oldDevelopmentProbe = URL(fileURLWithPath: "/old-checkout/OneShot Probe.app", isDirectory: true)
        let chosen = AppDistribution.captureURL(applicationURL: installed,
            applicationBundleIdentifier: AppDistribution.applicationBundleIdentifier,
            savedDevelopmentURL: oldDevelopmentProbe)
        #expect(chosen.path == "/Applications/OneShot.app/Contents/Helpers/OneShot Capture.app")
        #expect(AppDistribution.mcpExecutableURL(applicationURL: installed).path == "/Applications/OneShot.app/Contents/Helpers/oneshot-mcp")
        let relocated = URL(fileURLWithPath: "/Users/test/Applications/OneShot.app", isDirectory: true)
        #expect(AppDistribution.captureURL(applicationURL: relocated,
            applicationBundleIdentifier: AppDistribution.applicationBundleIdentifier).path
            == "/Users/test/Applications/OneShot.app/Contents/Helpers/OneShot Capture.app")
    }

    @Test func developmentLayoutAndExplicitDebugOverrideRemainAvailable() {
        let development = URL(fileURLWithPath: "/checkout/.build/OneShot Editor.app", isDirectory: true)
        let custom = URL(fileURLWithPath: "/test/Fixture Probe.app", isDirectory: true)
        #expect(AppDistribution.captureURL(applicationURL: development,
            applicationBundleIdentifier: AppDistribution.developmentApplicationBundleIdentifier).path
            == "/checkout/.build/OneShot Probe.app")
        #expect(AppDistribution.captureURL(applicationURL: development,
            applicationBundleIdentifier: AppDistribution.developmentApplicationBundleIdentifier,
            savedDevelopmentURL: custom) == custom)
        #expect(AppDistribution.captureURL(applicationURL: development,
            applicationBundleIdentifier: AppDistribution.applicationBundleIdentifier,
            explicitURL: custom, savedDevelopmentURL: development) == custom)
    }

    @Test func permissionReportUsesOnlyExplicitKnownGrantValues() throws {
        let granted = try CapturePermissionStatus.decode(Data(#"{"accessibility":"granted","screenRecording":"granted","permissionsRequested":"false"}"#.utf8))
        #expect(granted.allGranted)
        let missingScreen = try CapturePermissionStatus.decode(Data(#"{"accessibility":"granted","screenRecording":"not_granted"}"#.utf8))
        #expect(!missingScreen.allGranted)
        #expect(missingScreen.localizedDescription.contains("屏幕录制：未授权"))
        for invalid in [#"{"accessibility":true,"screenRecording":"granted"}"#,
                        #"{"accessibility":"unknown","screenRecording":"granted"}"#,
                        #"{"accessibility":"granted"}"#] {
            #expect(throws: (any Error).self) { try CapturePermissionStatus.decode(Data(invalid.utf8)) }
        }
    }
}
