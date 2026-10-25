import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Coordinates are Core Graphics desktop points, with the desktop's upper-left origin.
public struct CaptureRect: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct CaptureWindow: Codable, Equatable {
    public var id: UInt32
    public var pid: Int32
    public var ownerName: String
    public var title: String
    public var bounds: CaptureRect
    public var isOnScreen: Bool
    public var layer: Int
    public var alpha: Double
    public var bundleIdentifier: String?

    public init(id: UInt32, pid: Int32, ownerName: String, title: String,
                bounds: CaptureRect, isOnScreen: Bool, layer: Int = 0,
                alpha: Double = 1, bundleIdentifier: String? = nil) {
        self.id = id
        self.pid = pid
        self.ownerName = ownerName
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.layer = layer
        self.alpha = alpha
        self.bundleIdentifier = bundleIdentifier
    }

    public var cgRect: CGRect { bounds.cgRect }
}

public struct ScreenshotResult: Codable {
    public var path: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var windowID: UInt32
    public var pid: Int32
    public var startedAt: Date
    public var completedAt: Date
    public var source: String
    public var pointPixelScale: Double
    public var capturedBounds: CaptureRect
}

public enum WindowCaptureError: LocalizedError {
    case permissionDenied
    case targetUnavailable(UInt32)
    case targetOwnerChanged(UInt32)
    case invalidDimensions
    case imageDestinationUnavailable
    case imageWriteFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is not granted to this process. Grant it in System Settings > Privacy & Security > Screen Recording, then restart the process. OneShot did not request or change permission."
        case .targetUnavailable(let id):
            return "Window \(id) is no longer available to ScreenCaptureKit. No other window was substituted."
        case .targetOwnerChanged(let id):
            return "Window \(id) belongs to a different process than the selected target. Capture was cancelled."
        case .invalidDimensions:
            return "The selected window has invalid or unsupported capture dimensions."
        case .imageDestinationUnavailable:
            return "Could not create a PNG encoder for the screenshot."
        case .imageWriteFailed:
            return "The screenshot PNG could not be encoded."
        }
    }
}

public enum WindowCapture {
    /// This check does not present a permission prompt.
    public static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Enumeration does not activate an application or filter away off-screen windows.
    /// Window titles may be empty when the operating system withholds them.
    public static func listWindows() -> [CaptureWindow] {
        guard let records = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return records.compactMap { record in
            guard let id = record[kCGWindowNumber as String] as? NSNumber,
                  let pid = record[kCGWindowOwnerPID as String] as? NSNumber,
                  let rawBounds = record[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else {
                return nil
            }
            let processID = pid.int32Value
            return CaptureWindow(
                id: id.uint32Value,
                pid: processID,
                ownerName: record[kCGWindowOwnerName as String] as? String ?? "",
                title: record[kCGWindowName as String] as? String ?? "",
                bounds: CaptureRect(rect),
                isOnScreen: (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                layer: (record[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                bundleIdentifier: NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
            )
        }
    }

    /// Captures the exact window ID with public macOS APIs, independently of AX success.
    /// It never clicks, scrolls, raises, or focuses the target window.
    @available(macOS 14.0, *)
    public static func capture(window: CaptureWindow, to outputURL: URL) async throws -> ScreenshotResult {
        guard hasScreenRecordingPermission else { throw WindowCaptureError.permissionDenied }
        let startedAt = Date()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == window.id }) else {
            throw WindowCaptureError.targetUnavailable(window.id)
        }
        guard target.owningApplication?.processID == window.pid else {
            throw WindowCaptureError.targetOwnerChanged(window.id)
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let scale = Double(filter.pointPixelScale)
        let rect = filter.contentRect
        let width = Double(rect.width) * scale
        let height = Double(rect.height) * scale
        guard width.isFinite, height.isFinite, scale.isFinite, scale > 0,
              width > 0, height > 0, width <= Double(Int32.max), height <= Double(Int32.max) else {
            throw WindowCaptureError.invalidDimensions
        }
        let config = SCStreamConfiguration()
        config.width = Int(width.rounded(.up))
        config.height = Int(height.rounded(.up))
        config.captureResolution = .best
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        // Encode in memory before the atomic write, so partial images are not presented as captures.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw WindowCaptureError.imageDestinationUnavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WindowCaptureError.imageWriteFailed }
        try (data as Data).write(to: outputURL, options: .atomic)

        return ScreenshotResult(path: outputURL.path, pixelWidth: image.width, pixelHeight: image.height,
                                windowID: window.id, pid: window.pid, startedAt: startedAt, completedAt: Date(),
                                source: "ScreenCaptureKit.SCScreenshotManager", pointPixelScale: scale,
                                capturedBounds: CaptureRect(target.frame))
    }
}
