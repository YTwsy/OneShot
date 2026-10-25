import Foundation

public enum WindowSelection {
    public static func candidates(from windows: [CaptureWindow], app: String) -> [CaptureWindow] {
        windows.filter { ($0.bundleIdentifier == app || $0.ownerName == app) && $0.layer == 0 && $0.bounds.width > 0 && $0.bounds.height > 0 }
    }

    public static func select(from windows: [CaptureWindow], app: String, windowID: UInt32?) throws -> CaptureWindow {
        let matches = candidates(from: windows, app: app)
        if let windowID {
            guard let target = matches.first(where: { $0.id == windowID }) else {
                throw selectionError("Window \(windowID) does not belong to the requested app '\(app)' or is unavailable.")
            }
            return target
        }
        let visible = matches.filter(\.isOnScreen)
        guard visible.count == 1 else {
            let choices = matches.map { "\($0.id): \($0.title) [onScreen=\($0.isOnScreen)]" }.joined(separator: "; ")
            throw selectionError("Expected one visible window for '\(app)', found \(visible.count). Use --window-id from 'windows --app'. \(choices)")
        }
        return visible[0]
    }

    private static func selectionError(_ text: String) -> NSError {
        NSError(domain: "OneShot.WindowSelection", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
