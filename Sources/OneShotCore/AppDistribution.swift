import Foundation

/// Product identities and on-disk code locations shared by the editor and its distribution.
public enum AppDistribution {
    public static let applicationBundleIdentifier = "io.github.ytwsy.oneshot"
    public static let captureBundleIdentifier = "io.github.ytwsy.oneshot.capture-probe"
    public static let developmentApplicationBundleIdentifier = "dev.oneshot.editor"
    public static let developmentCaptureBundleIdentifier = "dev.oneshot.capture-probe"

    public static let captureBundleIdentifiers: Set<String> = [captureBundleIdentifier, developmentCaptureBundleIdentifier]
    public static let allBundleIdentifiers: Set<String> = captureBundleIdentifiers.union([
        applicationBundleIdentifier, developmentApplicationBundleIdentifier,
    ])

    public static func usesEmbeddedCapture(applicationBundleIdentifier: String?) -> Bool {
        applicationBundleIdentifier == Self.applicationBundleIdentifier
    }

    public static func embeddedCaptureURL(applicationURL: URL) -> URL {
        applicationURL.appendingPathComponent("Contents/Helpers/OneShot Capture.app", isDirectory: true)
    }

    public static func mcpExecutableURL(applicationURL: URL) -> URL {
        applicationURL.appendingPathComponent("Contents/Helpers/oneshot-mcp", isDirectory: false)
    }

    /// A distributed app always uses its embedded component. A development preference
    /// must never silently replace the component that was shipped with a release.
    public static func captureURL(applicationURL: URL, applicationBundleIdentifier: String?,
                                  explicitURL: URL? = nil, savedDevelopmentURL: URL? = nil) -> URL {
        if let explicitURL { return explicitURL }
        if usesEmbeddedCapture(applicationBundleIdentifier: applicationBundleIdentifier) {
            return embeddedCaptureURL(applicationURL: applicationURL)
        }
        return savedDevelopmentURL
            ?? applicationURL.deletingLastPathComponent().appendingPathComponent("OneShot Probe.app", isDirectory: true)
    }
}

public enum CapturePermissionGrant: String, Codable {
    case granted
    case notGranted = "not_granted"
}

/// A report made by the process that actually captures the screen and reads AX.
/// Checking the editor's own permissions would report a different TCC identity.
public struct CapturePermissionStatus: Decodable, Equatable {
    public let accessibility: CapturePermissionGrant
    public let screenRecording: CapturePermissionGrant

    public var allGranted: Bool { accessibility == .granted && screenRecording == .granted }

    public var localizedDescription: String {
        "辅助功能：\(accessibility == .granted ? "已授权" : "未授权")；屏幕录制：\(screenRecording == .granted ? "已授权" : "未授权")。"
    }

    public static func decode(_ data: Data) throws -> CapturePermissionStatus {
        guard data.count <= 65_536 else {
            throw AnnotationError.invalidCapture("权限检查结果超过支持大小。")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
