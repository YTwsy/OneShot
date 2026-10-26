import Testing
@testable import OneShotCore

struct ProbeProcessIdentityTests {
    @Test func helperExitingBeforeLaunchObservationDoesNotInvalidateItsPositiveReceipt() {
        var identity = ProbeProcessIdentity()
        identity.observe(nil)
        identity.observe(-1)
        identity.observe(0)
        #expect(identity.observedProcessID == nil)
        #expect(identity.acceptsReceipt(processID: 1820))
        #expect(!identity.acceptsReceipt(processID: -1))
        #expect(!identity.acceptsReceipt(processID: 0))
    }

    @Test func knownLaunchIdentityStaysPinnedAfterTerminationAndRejectsWrongReceiptProcess() {
        var identity = ProbeProcessIdentity()
        identity.observe(1820)
        identity.observe(-1)
        identity.observe(nil)
        identity.observe(9999)
        #expect(identity.observedProcessID == 1820)
        #expect(identity.acceptsReceipt(processID: 1820))
        #expect(!identity.acceptsReceipt(processID: 9999))
    }
}
