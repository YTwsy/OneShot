import AppKit
import Carbon
import CoreGraphics
import OneShotCore

/// Registers one explicit global chord instead of observing arbitrary key events.
/// The Carbon callback runs on the application's main event target and does not
/// activate OneShot before its caller freezes the foreground target.
@MainActor
final class GlobalCaptureHotKey {
    static let displayString = "⌃⌥⌘S"
    private static let signature: OSType = 0x4F536874 // OSht
    private static let identifier: UInt32 = 1
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onTrigger: (() -> Void)?
    private var isPressed = false

    var isRegistered: Bool { hotKey != nil }

    func register(onTrigger: @escaping @MainActor () -> Void) throws {
        unregister()
        self.onTrigger = onTrigger
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard Thread.isMainThread, let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard result == noErr else { return result }
            return MainActor.assumeIsolated {
                guard hotKeyID.signature == GlobalCaptureHotKey.signature,
                      hotKeyID.id == GlobalCaptureHotKey.identifier else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalCaptureHotKey>.fromOpaque(context).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    owner.isPressed = false
                    return noErr
                }
                guard !owner.isPressed else { return noErr }
                owner.isPressed = true
                owner.onTrigger?()
                return noErr
            }
        }, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            unregister(); throw RegistrationError(status: installed)
        }
        let id = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey), id,
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registered == noErr else {
            unregister(); throw RegistrationError(status: registered)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; onTrigger = nil; isPressed = false
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    struct RegistrationError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            status == eventHotKeyExistsErr
                ? "采集快捷键 ⌃⌥⌘S 已被其他应用占用。关闭冲突快捷键后，可重新启用采集快捷键。"
                : "暂时无法注册采集快捷键 ⌃⌥⌘S（系统错误 \(status)）。"
        }
    }
}

@MainActor
enum FrontmostCaptureReader {
    /// Metadata-only selection: no AX reads, permission prompts, clicks or activation.
    static func read() throws -> FrontmostCaptureTarget {
        guard let app = NSWorkspace.shared.frontmostApplication, !app.isTerminated, !app.isHidden else {
            throw FrontmostCaptureSelectionError.noApplication
        }
        let observedAt = Date()
        let application = FrontmostApplication(pid: app.processIdentifier, name: app.localizedName ?? "",
                                              bundleIdentifier: app.bundleIdentifier)
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else {
            throw FrontmostCaptureSelectionError.windowInventoryUnavailable
        }
        let windows = records.compactMap { record -> CaptureWindow? in
            guard let id = record[kCGWindowNumber as String] as? NSNumber,
                  let pid = record[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = record[kCGWindowLayer as String] as? NSNumber,
                  let onScreen = record[kCGWindowIsOnscreen as String] as? NSNumber,
                  let rawBounds = record[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else { return nil }
            return CaptureWindow(id: id.uint32Value, pid: pid.int32Value,
                                 ownerName: record[kCGWindowOwnerName as String] as? String ?? "",
                                 title: record[kCGWindowName as String] as? String ?? "", bounds: CaptureRect(bounds),
                                 isOnScreen: onScreen.boolValue, layer: layer.intValue,
                                 alpha: (record[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                                 bundleIdentifier: NSRunningApplication(processIdentifier: pid.int32Value)?.bundleIdentifier)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.pid, !app.isTerminated else {
            throw FrontmostCaptureSelectionError.applicationChanged
        }
        return try FrontmostCaptureSelection.select(application: application, windowsFrontToBack: windows,
                                                     excludingPIDs: [Int32(ProcessInfo.processInfo.processIdentifier)], at: observedAt)
    }
}
