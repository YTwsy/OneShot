import Foundation
import Testing
@testable import OneShotCore

struct PermissionGuideStateTests {
    private func status(accessibility: Bool, screen: Bool) throws -> CapturePermissionStatus {
        try CapturePermissionStatus.decode(Data("""
        {"accessibility":"\(accessibility ? "granted" : "not_granted")","screenRecording":"\(screen ? "granted" : "not_granted")"}
        """.utf8))
    }

    @Test func welcomeCannotCompleteForUnknownOrEitherMissingPermission() throws {
        var guide = PermissionGuideState(previouslyCompleted: false)
        #expect(guide.isPresented)
        #expect(!guide.canCapture)
        let unknownFinished = guide.finish()
        #expect(!unknownFinished)
        for pair in [(false, false), (true, false), (false, true)] {
            guide.receive(try status(accessibility: pair.0, screen: pair.1), presentIfMissing: true)
            #expect(!guide.canCapture)
            let missingFinished = guide.finish()
            #expect(!missingFinished)
        }
        guide.receive(try status(accessibility: true, screen: true), presentIfMissing: true)
        #expect(guide.canCapture)
        let grantedFinished = guide.finish()
        #expect(grantedFinished)
        #expect(!guide.isPresented)
    }

    @Test func skippingKeepsOfflineEditingAvailableWithoutEnablingCaptureOrReopeningOnRefresh() throws {
        var guide = PermissionGuideState(previouslyCompleted: false)
        guide.skip()
        guide.receive(try status(accessibility: false, screen: false), presentIfMissing: true)
        #expect(!guide.isPresented)
        #expect(!guide.canCapture)
        let skippedFinished = guide.finish()
        #expect(!skippedFinished)
        guide.show()
        #expect(guide.isPresented)
        #expect(!guide.skippedForSession)
    }

    @Test func revokedPermissionsOrNewHelperReopenGuideAfterEarlierCompletion() throws {
        var guide = PermissionGuideState(previouslyCompleted: true)
        #expect(!guide.isPresented)
        guide.receive(try status(accessibility: true, screen: true), presentIfMissing: true)
        #expect(!guide.isPresented)
        guide.receive(try status(accessibility: true, screen: false), presentIfMissing: true)
        #expect(guide.isPresented)
        #expect(!guide.canCapture)
        var nextLaunch = PermissionGuideState(previouslyCompleted: true)
        nextLaunch.receive(try status(accessibility: false, screen: true), presentIfMissing: true)
        #expect(nextLaunch.isPresented)
    }

    @Test func failedRecheckNeverKeepsStaleGrantedState() throws {
        var guide = PermissionGuideState(previouslyCompleted: true)
        guide.receive(try status(accessibility: true, screen: true), presentIfMissing: true)
        #expect(guide.canCapture)
        guide.invalidate(presentIfMissing: true)
        #expect(guide.isPresented)
        #expect(!guide.canCapture)
        let failedCheckFinished = guide.finish()
        #expect(!failedCheckFinished)
    }
}
