import AppKit
import ApplicationServices
import Foundation

/// Result of a single AX boolean read or settable probe. Unknown is distinct from false.
public struct ElectronAXBooleanObservation: Codable, Sendable {
    public var status: String
    public var value: Bool?
    public var errorCode: Int?
    public var valueType: String?
}

/// An audit record for an explicitly requested process-local Electron AX activation.
/// A successful write does not establish that a subsequent capture will succeed.
public struct ElectronAccessibilityOutcome: Codable, Sendable {
    public var pid: Int32
    public var startedAt: Date
    public var finishedAt: Date
    public var bundleIdentifier: String?
    public var bundlePath: String?
    public var executablePath: String?
    public var processLaunchDate: Date?
    public var electronFrameworkPath: String?
    public var electronFrameworkFound: Bool
    public var accessibilityTrusted: Bool
    public var attribute: String
    public var attributeDeclared: Bool?
    public var attributeNamesErrorCode: Int?
    public var messagingTimeoutErrorCode: Int?
    public var readBefore: ElectronAXBooleanObservation?
    public var settable: ElectronAXBooleanObservation?
    public var writeAttempted: Bool
    public var requestedValue: Bool
    public var setErrorCode: Int?
    public var readAfter: ElectronAXBooleanObservation?
    public var status: String
    public var note: String
    public var effectScope: String
}

/// Explicit opt-in adapter. Passive AX capture never calls this automatically.
/// Electron documents setting AXManualAccessibility from third-party assistive software:
/// https://www.electronjs.org/docs/latest/tutorial/accessibility#macos
public enum ElectronAccessibility {
    public static func enable(pid: pid_t) -> ElectronAccessibilityOutcome {
        let started = Date()
        var outcome = ElectronAccessibilityOutcome(
            pid: pid, startedAt: started, finishedAt: started,
            bundleIdentifier: nil, bundlePath: nil, executablePath: nil,
            processLaunchDate: nil, electronFrameworkPath: nil,
            electronFrameworkFound: false, accessibilityTrusted: AXIsProcessTrusted(),
            attribute: "AXManualAccessibility", attributeDeclared: nil,
            attributeNamesErrorCode: nil, messagingTimeoutErrorCode: nil,
            readBefore: nil, settable: nil, writeAttempted: false, requestedValue: true,
            setErrorCode: nil, readAfter: nil, status: "not_started", note: "",
            effectScope: "Changes accessibility support in the running Electron process and may affect its accessibility UI. No automatic reset is performed because other accessibility clients may share this state. It does not grant macOS permissions or establish capture completeness."
        )
        func finish(_ status: String, _ note: String) -> ElectronAccessibilityOutcome {
            outcome.status = status
            outcome.note = note
            outcome.finishedAt = Date()
            return outcome
        }

        guard pid > 0 else {
            return finish("invalid_pid", "A positive PID identifying an existing application is required; no AX access was attempted.")
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return finish("application_not_running", "The PID does not identify a running application; no AX access was attempted.")
        }

        outcome.bundleIdentifier = app.bundleIdentifier
        outcome.bundlePath = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path
        outcome.executablePath = app.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path
        outcome.processLaunchDate = app.launchDate
        guard let bundleIdentifier = outcome.bundleIdentifier, !bundleIdentifier.isEmpty,
              let bundlePath = outcome.bundlePath, let executablePath = outcome.executablePath,
              executablePath.hasPrefix(bundlePath + "/") else {
            return finish("unverified_application_identity", "A bundle identifier, bundle path, and executable inside that bundle are required before activation.")
        }

        // Intentionally restrict the initial adapter to the conventional Electron framework.
        // A renamed/custom framework requires a separately verified detection path.
        let framework = URL(fileURLWithPath: bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework", isDirectory: true)
        outcome.electronFrameworkPath = framework.path
        var isDirectory = ObjCBool(false)
        outcome.electronFrameworkFound = FileManager.default.fileExists(atPath: framework.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        guard outcome.electronFrameworkFound else {
            return finish("not_verified_electron", "The target bundle does not contain the expected Electron Framework.framework directory; no AX attributes were read or written.")
        }
        guard outcome.accessibilityTrusted else {
            return finish("permission_denied", "This process is not trusted for Accessibility; no permission prompt or AX attribute write was attempted.")
        }

        let axApp = AXUIElementCreateApplication(pid)
        outcome.messagingTimeoutErrorCode = Int(AXUIElementSetMessagingTimeout(axApp, 0.25).rawValue)
        let attribute = outcome.attribute as CFString
        var names: CFArray?
        let namesError = AXUIElementCopyAttributeNames(axApp, &names)
        outcome.attributeNamesErrorCode = Int(namesError.rawValue)
        if namesError == .success, let names = names as? [String] {
            outcome.attributeDeclared = names.contains(outcome.attribute)
        }
        outcome.readBefore = readBoolean(axApp, attribute)
        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(axApp, attribute, &settable)
        outcome.settable = ElectronAXBooleanObservation(
            status: settableError == .success ? "ok" : errorStatus(settableError),
            value: settableError == .success ? settable.boolValue : nil,
            errorCode: Int(settableError.rawValue), valueType: settableError == .success ? "boolean" : nil
        )
        if outcome.readBefore?.value == true {
            return finish("already_enabled", "AXManualAccessibility already reads true; no value was written. Subsequent window availability must still be checked.")
        }

        // Recheck identity immediately before the only target mutation. Never activate a
        // replacement process or a different app merely because its PID was reused.
        guard let current = NSRunningApplication(processIdentifier: pid), !current.isTerminated,
              current.bundleIdentifier == bundleIdentifier,
              current.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == bundlePath,
              current.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path == executablePath,
              current.launchDate == outcome.processLaunchDate else {
            return finish("target_identity_changed", "The target application identity changed before activation; no value was written.")
        }
        guard AXIsProcessTrusted() else {
            outcome.accessibilityTrusted = false
            return finish("permission_denied", "Accessibility trust was absent immediately before activation; no value was written.")
        }

        // Electron's documented operation may work even when the attribute is not listed
        // or a settable probe does not describe it. Preserve the probes, then report the
        // actual setter result rather than treating a missing declaration as permission.
        outcome.writeAttempted = true
        let setError = AXUIElementSetAttributeValue(axApp, attribute, kCFBooleanTrue)
        outcome.setErrorCode = Int(setError.rawValue)
        outcome.readAfter = readBoolean(axApp, attribute)
        guard setError == .success else {
            return finish("write_failed", "AXManualAccessibility=true returned AX error \(setError.rawValue). The read-after result is recorded separately; capture availability is not established.")
        }
        if outcome.readAfter?.value == true {
            return finish("enabled", "The AX setter succeeded and AXManualAccessibility reads true. No reset will be attempted; subsequent capture remains a separate operation.")
        }
        return finish("write_succeeded_unconfirmed", "The AX setter succeeded, but the immediate read-after did not confirm true. No retry or reset was attempted; subsequent capture remains a separate operation.")
    }

    private static func readBoolean(_ element: AXUIElement, _ attribute: CFString) -> ElectronAXBooleanObservation {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard error == .success else {
            return ElectronAXBooleanObservation(status: errorStatus(error), value: nil,
                                                errorCode: Int(error.rawValue), valueType: nil)
        }
        guard let raw = raw else {
            return ElectronAXBooleanObservation(status: "empty_result", value: nil, errorCode: 0, valueType: nil)
        }
        guard CFGetTypeID(raw) == CFBooleanGetTypeID(), let number = raw as? NSNumber else {
            return ElectronAXBooleanObservation(status: "unexpected_value_type", value: nil,
                                                errorCode: 0, valueType: "CFTypeID:\(CFGetTypeID(raw))")
        }
        return ElectronAXBooleanObservation(status: "ok", value: number.boolValue, errorCode: 0, valueType: "boolean")
    }

    private static func errorStatus(_ error: AXError) -> String {
        switch error {
        case .success: return "ok"
        case .attributeUnsupported: return "unsupported"
        case .noValue: return "no_value"
        case .apiDisabled: return "api_disabled"
        case .cannotComplete: return "cannot_complete"
        case .invalidUIElement: return "invalid_element"
        case .notImplemented: return "not_implemented"
        default: return "ax_error"
        }
    }
}
