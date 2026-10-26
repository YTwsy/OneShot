import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OneShotCore

struct RecentCapturesTests {
    @Test func recentProjectsSurviveRestartAndKeepEditableAnnotationsWithoutOriginalCapture() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("state/recent.json")
        let store = RecentCapturesStore(fileURL: indexURL)
        #expect(try store.load().isEmpty)
        let capture = try fixtureCapture(in: root, id: "first")
        let rawEntries = try store.record(directory: capture, at: Date(timeIntervalSince1970: 10))
        #expect(rawEntries.first?.isProject == false)
        #expect(rawEntries.first?.title == "Fixture · 测试窗口 first")
        let raw = try AnnotationStore.openCapture(at: capture)
        var document = raw.document
        document.items = [AnnotationItem(kind: .number, start: .init(x: 20, y: 20), text: "这里的提示不清楚")]
        let projectURL = root.appendingPathComponent("editable.oneshot")
        _ = try AnnotationStore.createProject(from: raw, document: document, at: projectURL)
        try store.record(directory: projectURL, at: Date(timeIntervalSince1970: 11))
        try FileManager.default.removeItem(at: capture)

        let restarted = RecentCapturesStore(fileURL: indexURL)
        let entries = try restarted.load()
        #expect(entries.count == 2)
        let projectEntry = try #require(entries.first)
        #expect(projectEntry.isProject)
        #expect(projectEntry.annotationCount == 1)
        #expect(projectEntry.isAvailable)
        #expect(try AnnotationStore.openProject(at: projectEntry.directory).document == document)
        #expect(entries[1].captureID == "first")
        #expect(!entries[1].isAvailable)
        let attributes = try FileManager.default.attributesOfItem(atPath: indexURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: indexURL.deletingLastPathComponent().path)
        #expect((parentAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func boundedListDeduplicatesReopenedPathsAndRemovingAnEntryKeepsItsFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentCapturesStore(fileURL: root.appendingPathComponent("recent.json"), limit: 2)
        let first = try fixtureCapture(in: root, id: "first")
        let second = try fixtureCapture(in: root, id: "second")
        let third = try fixtureCapture(in: root, id: "third")
        try store.record(directory: first, at: Date(timeIntervalSince1970: 10))
        try store.record(directory: second, at: Date(timeIntervalSince1970: 11))
        try store.record(directory: third, at: Date(timeIntervalSince1970: 12))
        #expect(try store.load().map(\.captureID) == ["third", "second"])
        try store.record(directory: second, at: Date(timeIntervalSince1970: 13))
        #expect(try store.load().map(\.captureID) == ["second", "third"])
        let removed = try store.remove(id: second.standardizedFileURL.path)
        #expect(removed.map(\.captureID) == ["third"])
        #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test func failedCaptureOrCorruptIndexCannotReplaceExistingRecords() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("recent.json")
        let store = RecentCapturesStore(fileURL: indexURL)
        let capture = try fixtureCapture(in: root, id: "valid")
        try store.record(directory: capture)
        let bytes = try Data(contentsOf: indexURL)
        #expect(throws: (any Error).self) { try store.record(directory: root.appendingPathComponent("missing")) }
        #expect(try Data(contentsOf: indexURL) == bytes)
        let corrupt = Data("not a recent index".utf8)
        try corrupt.write(to: indexURL)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.record(directory: capture) }
        #expect(try Data(contentsOf: indexURL) == corrupt)
    }

    @Test func linkedIndexAndLinkedRecentDirectoryAreNotReadOrOverwritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try fixtureCapture(in: root, id: "valid")
        let indexURL = root.appendingPathComponent("recent.json")
        let store = RecentCapturesStore(fileURL: indexURL)
        try store.record(directory: capture)
        let realIndex = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: indexURL, to: realIndex)
        let original = try Data(contentsOf: realIndex)
        try FileManager.default.createSymbolicLink(at: indexURL, withDestinationURL: realIndex)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.record(directory: capture) }
        #expect(try Data(contentsOf: realIndex) == original)
        try FileManager.default.removeItem(at: indexURL)
        let linkedCapture = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedCapture, withDestinationURL: capture)
        #expect(throws: (any Error).self) { try store.record(directory: linkedCapture) }
        #expect(!FileManager.default.fileExists(atPath: indexURL.path))
        let linkedParent = root.appendingPathComponent("linked-state")
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: root)
        let linkedStore = RecentCapturesStore(fileURL: linkedParent.appendingPathComponent("outside.json"))
        #expect(throws: (any Error).self) { try linkedStore.load() }
        #expect(throws: (any Error).self) { try linkedStore.record(directory: capture) }
        #expect(try Data(contentsOf: realIndex) == original)
    }

    @Test func validatedProjectCanBeRecordedWithoutAXReparseAndForgedBindingsAreRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecentCapturesStore(fileURL: root.appendingPathComponent("recent.json"))
        let capture = try fixtureCapture(in: root, id: "valid")
        let opened = try AnnotationStore.openCapture(at: capture)
        #expect(try store.record(project: opened).first?.captureID == "valid")
        let original = try Data(contentsOf: store.fileURL)
        var wrongID = opened
        wrongID.document.sourceCaptureID = "another-capture"
        var wrongDimensions = opened
        wrongDimensions.document.imageWidth += 1
        let wrongImage = AnnotationProject(document: opened.document, captureDirectory: capture,
            imageURL: root.appendingPathComponent("outside.png"))
        for wrong in [wrongID, wrongDimensions, wrongImage] {
            #expect(throws: (any Error).self) { try store.record(project: wrong) }
            #expect(try Data(contentsOf: store.fileURL) == original)
        }
    }

    @Test func unsupportedOrMalformedIndexIsPreservedAndDoesNotTouchReferencedDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try fixtureCapture(in: root, id: "valid")
        let indexURL = root.appendingPathComponent("recent.json")
        let store = RecentCapturesStore(fileURL: indexURL)
        try store.record(directory: capture)
        var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        value["schemaVersion"] = 99
        let futureData = try JSONSerialization.data(withJSONObject: value)
        try futureData.write(to: indexURL)
        #expect(throws: (any Error).self) { try store.record(directory: capture) }
        #expect(try Data(contentsOf: indexURL) == futureData)
        #expect(FileManager.default.fileExists(atPath: capture.appendingPathComponent("screenshot.png").path))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-recents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func fixtureCapture(in root: URL, id: String) throws -> URL {
        let store = try SnapshotStore(newDirectory: root.appendingPathComponent(id))
        let window = CaptureWindow(id: 1, pid: 42, ownerName: "Fixture", title: "测试窗口 \(id)",
            bounds: .init(x: 0, y: 0, width: 64, height: 48), isOnScreen: true)
        let manifest = SnapshotManifest(captureID: id, startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1), requestedApp: "example.fixture", applicationVersion: "1",
            window: window, windowAfter: window, accessibility: .init(status: "failed"),
            screenshot: .init(status: "captured", file: "screenshot.png"),
            ocr: .init(status: "not_requested"), consistency: "fixture", notes: [])
        try store.write(manifest, named: "manifest.json")
        try store.writeText("冻结的完整上下文", named: "context.txt")
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.9, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(context.makeImage())
        let output = try #require(CGImageDestinationCreateWithURL(store.directory.appendingPathComponent("screenshot.png") as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        return store.directory
    }
}
