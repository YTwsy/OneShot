import Testing
@testable import OneShotCore

struct WindowSelectionTests {
    private func window(_ id: UInt32, app: String = "target", visible: Bool = true) -> CaptureWindow {
        CaptureWindow(id: id, pid: 42, ownerName: app, title: "Same title",
                      bounds: CaptureRect(x: 0, y: 0, width: 800, height: 600),
                      isOnScreen: visible, bundleIdentifier: "example.\(app)")
    }

    @Test func ambiguousWindowRequiresExplicitIdentity() throws {
        let windows = [window(1), window(2)]
        #expect(throws: (any Error).self) { try WindowSelection.select(from: windows, app: "target", windowID: nil) }
        #expect(try WindowSelection.select(from: windows, app: "target", windowID: 2).id == 2)
    }

    @Test func idCannotEscapeRequestedApplication() {
        #expect(throws: (any Error).self) { try WindowSelection.select(from: [window(1, app: "other")], app: "target", windowID: 1) }
    }

    @Test func offscreenWindowRequiresExplicitSelection() throws {
        let windows = [window(1, visible: false)]
        #expect(throws: (any Error).self) { try WindowSelection.select(from: windows, app: "example.target", windowID: nil) }
        #expect(try WindowSelection.select(from: windows, app: "example.target", windowID: 1).id == 1)
    }
}
