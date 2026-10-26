import Foundation
import Testing
@testable import OneShotCore

struct FrontmostCaptureSelectionTests {
    private let app = FrontmostApplication(pid: 42, name: "Target", bundleIdentifier: "example.target")
    private func window(_ id: UInt32, pid: Int32 = 42, visible: Bool = true, layer: Int = 0,
                        alpha: Double = 1, width: Double = 800, bundle: String? = "example.target") -> CaptureWindow {
        CaptureWindow(id: id, pid: pid, ownerName: "Target", title: "", bounds: .init(x: -100, y: 20, width: width, height: 600),
                      isOnScreen: visible, layer: layer, alpha: alpha, bundleIdentifier: bundle)
    }

    @Test func choosesForegroundPIDAndFrontToBackOrderWithoutDependingOnTitles() throws {
        let date = Date(timeIntervalSince1970: 123)
        let target = try FrontmostCaptureSelection.select(application: app,
            windowsFrontToBack: [window(99, pid: 11), window(9), window(2)], at: date)
        #expect(target.window.id == 9)
        #expect(target.window.pid == 42)
        #expect(target.window.title.isEmpty)
        #expect(target.selectedAt == date)
        #expect(target.appArgument == "example.target")
        #expect(target.selectionBasis == "frontmost_application_and_front_to_back_normal_window")
    }

    @Test func skipsOverlaysHiddenTransparentAndInvalidWindowsButNeverOtherApps() throws {
        let windows = [window(1, layer: 8), window(2, visible: false), window(3, alpha: 0),
                       window(4, width: .nan), window(5, width: 0), window(6, alpha: .infinity), window(7)]
        #expect(try FrontmostCaptureSelection.select(application: app, windowsFrontToBack: windows).window.id == 7)
        #expect(throws: FrontmostCaptureSelectionError.noVisibleWindow) {
            try FrontmostCaptureSelection.select(application: app, windowsFrontToBack: [window(8, pid: 8)])
        }
    }

    @Test func noForegroundAndSelfTargetsFailBeforeSelectingAnyWindow() {
        #expect(throws: FrontmostCaptureSelectionError.noApplication) {
            try FrontmostCaptureSelection.select(application: nil, windowsFrontToBack: [window(1)])
        }
        #expect(throws: FrontmostCaptureSelectionError.excludedApplication) {
            try FrontmostCaptureSelection.select(application: app, windowsFrontToBack: [window(1)], excludingPIDs: [42])
        }
        for bundle in AppDistribution.allBundleIdentifiers {
            #expect(throws: FrontmostCaptureSelectionError.excludedApplication) {
                try FrontmostCaptureSelection.select(application: .init(pid: 42, name: "OneShot", bundleIdentifier: bundle),
                                                     windowsFrontToBack: [window(1, bundle: bundle)])
            }
        }
    }

    @Test func identityConflictCannotFallBackToSecondWindowAndMissingBundleCannotFallBackToName() {
        #expect(throws: FrontmostCaptureSelectionError.inconsistentIdentity) {
            try FrontmostCaptureSelection.select(application: app,
                windowsFrontToBack: [window(1, bundle: "example.other"), window(2)])
        }
        let identifiers: [String?] = [nil, "", " \n\t"]
        for bundle in identifiers {
            let unidentified = FrontmostApplication(pid: 42, name: "Target", bundleIdentifier: bundle)
            #expect(throws: FrontmostCaptureSelectionError.missingApplicationIdentifier) {
                try FrontmostCaptureSelection.select(application: unidentified,
                    windowsFrontToBack: [window(1, bundle: bundle)])
            }
        }
    }
}
