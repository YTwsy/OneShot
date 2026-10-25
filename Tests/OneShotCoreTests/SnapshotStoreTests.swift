import Foundation
import Testing
@testable import OneShotCore

struct SnapshotStoreTests {
    @Test func longUnicodeCaptureSurvivesOfflineReadAndCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SnapshotStore(newDirectory: root.appendingPathComponent("capture"))
        let original = String(repeating: "正文：界面之外也要保留 🧭\n", count: 20000) + "末尾标记"
        try store.writeText(original, named: "context.txt")
        #expect(try SnapshotStore.readContext(from: store.directory) == original)
        #expect(throws: (any Error).self) { try store.writeText("changed", named: "context.txt") }
        #expect(throws: (any Error).self) { try SnapshotStore(newDirectory: store.directory) }
        #expect(try SnapshotStore.readContext(from: store.directory) == original)
    }

    @Test func snapshotCannotWriteOutsideItsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SnapshotStore(newDirectory: root)
        #expect(throws: (any Error).self) { try store.writeText("bad", named: "../escape.txt") }
        #expect(throws: (any Error).self) { try store.writeText("bad", named: "/absolute.txt") }
    }
}
