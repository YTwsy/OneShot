import Foundation

/// Explicit consent actions are distinct from the passive permission report.
public enum CapturePermissionKind: String, Codable, CaseIterable, Identifiable {
    case screenRecording = "screen-recording"
    case accessibility = "accessibility"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .screenRecording: return "屏幕录制"
        case .accessibility: return "辅助功能"
        }
    }

    /// These pane URLs are a convenience, not a public guarantee that a particular
    /// macOS version will navigate to the exact pane. Keep the manual path visible.
    public var settingsURL: URL {
        let pane = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    public var settingsFallbackURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    }

    public var settingsPathDescription: String {
        switch self {
        case .screenRecording:
            return "系统设置 → 隐私与安全性 → 屏幕录制（部分系统显示为“屏幕与系统音频录制”）"
        case .accessibility:
            return "系统设置 → 隐私与安全性 → 辅助功能"
        }
    }

    /// Keep the legacy explicit authorize command working, but the GUI requests
    /// exactly one permission per button. Screen Recording comes first so an AX
    /// request cannot hide or delay the screen permission step.
    public static func requestedPermissions(option: String?) throws -> [Self] {
        guard let option else { return [.screenRecording, .accessibility] }
        guard let permission = Self(rawValue: option) else {
            throw AnnotationError.invalidCapture("未知的授权类型；请使用 screen-recording 或 accessibility。")
        }
        return [permission]
    }
}

public extension CapturePermissionStatus {
    func grant(for permission: CapturePermissionKind) -> CapturePermissionGrant {
        switch permission {
        case .screenRecording: return screenRecording
        case .accessibility: return accessibility
        }
    }
}

/// An API return is not the same as a fresh post-approval status check. The editor
/// must run doctor in a new helper process when the user returns from Settings.
public struct CaptureAuthorizationAttempt: Codable, Equatable {
    public let permission: CapturePermissionKind
    public let requestedAt: Date
    public let alreadyGranted: Bool
    public let requestInvoked: Bool
    public let apiReturnedGranted: Bool

    public init(permission: CapturePermissionKind, requestedAt: Date, alreadyGranted: Bool,
                requestInvoked: Bool, apiReturnedGranted: Bool) {
        self.permission = permission; self.requestedAt = requestedAt
        self.alreadyGranted = alreadyGranted; self.requestInvoked = requestInvoked
        self.apiReturnedGranted = apiReturnedGranted
    }
}
