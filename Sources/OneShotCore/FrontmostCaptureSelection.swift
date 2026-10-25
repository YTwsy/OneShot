import Foundation

/// The application observed at the instant a capture shortcut is handled.
public struct FrontmostApplication: Codable, Equatable {
    public let pid: Int32
    public let name: String
    public let bundleIdentifier: String?

    public init(pid: Int32, name: String, bundleIdentifier: String?) {
        self.pid = pid; self.name = name; self.bundleIdentifier = bundleIdentifier
    }
}

/// A frozen selection. The caller must keep using this ID/PID rather than reselecting
/// whichever app happens to be frontmost after launching the capture helper.
public struct FrontmostCaptureTarget: Codable, Equatable {
    public let application: FrontmostApplication
    public let window: CaptureWindow
    public let selectedAt: Date
    public let selectionBasis: String

    /// Selection requires a real bundle ID. A malformed decoded target fails closed
    /// with an empty argument instead of falling back to an ambiguous display name.
    public var appArgument: String { application.bundleIdentifier ?? "" }
}

public enum FrontmostCaptureSelectionError: LocalizedError, Equatable {
    case noApplication
    case excludedApplication
    case missingApplicationIdentifier
    case noVisibleWindow
    case inconsistentIdentity
    case applicationChanged
    case windowInventoryUnavailable

    public var errorDescription: String? {
        switch self {
        case .noApplication: return "当前没有可采集的焦点应用。请打开目标应用的窗口后再试。"
        case .excludedApplication: return "请先切换到要采集的应用，再按采集快捷键。"
        case .missingApplicationIdentifier: return "当前应用没有可验证的应用标识，暂不支持通过快捷键采集此应用。"
        case .noVisibleWindow: return "当前应用没有可采集的可见窗口。请打开目标窗口后再试。"
        case .inconsistentIdentity: return "当前窗口的应用身份发生变化，请重新触发采集。"
        case .applicationChanged: return "选择目标时焦点应用发生变化，请重新触发采集。"
        case .windowInventoryUnavailable: return "无法读取当前可见窗口列表，请稍后重试。"
        }
    }
}

public enum FrontmostCaptureSelection {
    public static let excludedBundleIdentifiers: Set<String> = ["dev.oneshot.editor", "dev.oneshot.capture-probe"]
    public static let selectionBasis = "frontmost_application_and_front_to_back_normal_window"

    /// Input order must be Core Graphics front-to-back order, not sorted by title or ID.
    /// This chooses the foreground application's foremost normal, visible window. It
    /// does not claim to have read AXFocusedWindow, and deliberately ignores overlays.
    public static func select(application: FrontmostApplication?, windowsFrontToBack: [CaptureWindow],
                              excludingPIDs: Set<Int32> = [],
                              excludingBundleIdentifiers: Set<String> = excludedBundleIdentifiers,
                              at date: Date = Date()) throws -> FrontmostCaptureTarget {
        guard let application, application.pid > 0 else { throw FrontmostCaptureSelectionError.noApplication }
        if excludingPIDs.contains(application.pid)
            || application.bundleIdentifier.map(excludingBundleIdentifiers.contains) == true {
            throw FrontmostCaptureSelectionError.excludedApplication
        }
        guard let appBundle = application.bundleIdentifier,
              !appBundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FrontmostCaptureSelectionError.missingApplicationIdentifier
        }
        guard let selected = windowsFrontToBack.first(where: { window in
            window.pid == application.pid && window.id != 0 && window.isOnScreen && window.layer == 0
                && window.alpha.isFinite && window.alpha > 0
                && [window.bounds.x, window.bounds.y, window.bounds.width, window.bounds.height].allSatisfy(\.isFinite)
                && window.bounds.width > 0 && window.bounds.height > 0
        }) else { throw FrontmostCaptureSelectionError.noVisibleWindow }
        // Never substitute another matching window after an identity conflict.
        if let windowBundle = selected.bundleIdentifier,
           appBundle != windowBundle { throw FrontmostCaptureSelectionError.inconsistentIdentity }
        return FrontmostCaptureTarget(application: application, window: selected,
                                      selectedAt: date, selectionBasis: selectionBasis)
    }
}
