import Foundation

/// A completed welcome screen never substitutes for the helper's current TCC status.
public struct PermissionGuideState {
    public private(set) var status: CapturePermissionStatus?
    public private(set) var isPresented: Bool
    public private(set) var skippedForSession = false

    public init(previouslyCompleted: Bool) {
        isPresented = !previouslyCompleted
    }

    public var canCapture: Bool { status?.allGranted == true }

    public mutating func receive(_ status: CapturePermissionStatus, presentIfMissing: Bool) {
        self.status = status
        if !status.allGranted, presentIfMissing, !skippedForSession { isPresented = true }
    }

    public mutating func invalidate(presentIfMissing: Bool) {
        status = nil
        if presentIfMissing, !skippedForSession { isPresented = true }
    }

    public mutating func show() {
        skippedForSession = false
        isPresented = true
    }

    /// Skipping permits offline editing; it never grants permission to capture.
    public mutating func skip() {
        skippedForSession = true
        isPresented = false
    }

    @discardableResult public mutating func finish() -> Bool {
        guard canCapture else { return false }
        isPresented = false
        return true
    }
}
