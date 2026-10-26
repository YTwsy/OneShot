import Foundation

/// A LaunchServices callback can arrive after a short-lived helper has exited.
/// NSRunningApplication then reports -1, which is unknown rather than a PID mismatch.
/// Pin the first positive observation instead of rereading that mutable object later.
public struct ProbeProcessIdentity {
    public private(set) var observedProcessID: Int32?

    public init() {}

    public mutating func observe(_ processID: Int32?) {
        guard observedProcessID == nil, let processID, processID > 0 else { return }
        observedProcessID = processID
    }

    public func acceptsReceipt(processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        return observedProcessID.map { $0 == processID } ?? true
    }
}
