import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OneShotCore

struct AnnotationStoreTests {
    @Test func editableProjectKeepsOriginalBytesAndReopensAfterMovingWithoutSource() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try fixtureCapture(in: root)
        let originals = try captureFiles(capture)
        let opened = try AnnotationStore.openCapture(at: capture)
        #expect(opened.document.items.isEmpty)
        #expect(opened.document.imageWidth == 64)
        #expect(opened.document.imageHeight == 48)
        let destination = root.appendingPathComponent("notes.oneshot")
        let project = try AnnotationStore.createProject(from: opened, document: opened.document, at: destination)
        #expect(project.projectDirectory?.standardizedFileURL.path == destination.standardizedFileURL.path)
        #expect(try captureFiles(project.captureDirectory) == originals)

        var edited = project.document
        edited.items = [AnnotationItem(kind: .number, start: .init(x: 10, y: 12), number: 3),
                        AnnotationItem(kind: .arrow, start: .init(x: 4, y: 5), end: .init(x: 50, y: 40)),
                        AnnotationItem(kind: .rectangle, start: .init(x: 60, y: 44), end: .init(x: 12, y: 20)),
                        AnnotationItem(kind: .text, start: .init(x: 8, y: 30), text: "中文说明 🧭\n第二行")]
        try AnnotationStore.save(document: edited, in: destination)
        #expect(try AnnotationStore.openProject(at: destination).document == edited)
        #expect(try captureFiles(capture) == originals)
        #expect(try captureFiles(project.captureDirectory) == originals)
        #expect(throws: (any Error).self) {
            try AnnotationStore.createProject(from: opened, document: edited, at: destination)
        }

        let relocated = root.appendingPathComponent("moved.oneshot")
        try FileManager.default.moveItem(at: destination, to: relocated)
        try FileManager.default.removeItem(at: capture)
        let reopened = try AnnotationStore.openProject(at: relocated)
        #expect(reopened.document == edited)
        #expect(try captureFiles(reopened.captureDirectory) == originals)
        let attributes = try FileManager.default.attributesOfItem(atPath: relocated.appendingPathComponent("annotations.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func wrongCaptureAndUnsupportedSchemaCannotOverwriteExistingEdits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try AnnotationStore.openCapture(at: fixtureCapture(in: root))
        let directory = root.appendingPathComponent("notes.oneshot")
        let project = try AnnotationStore.createProject(from: source, document: source.document, at: directory)
        let path = directory.appendingPathComponent("annotations.json")
        let original = try Data(contentsOf: path)
        var wrongCapture = project.document
        wrongCapture.sourceCaptureID = "a-different-capture"
        var wrongDimensions = project.document
        wrongDimensions.imageWidth += 1
        var wrongIdentity = project.document
        wrongIdentity.id = UUID()
        for wrong in [wrongCapture, wrongDimensions, wrongIdentity] {
            #expect(throws: (any Error).self) { try AnnotationStore.save(document: wrong, in: directory) }
            #expect(try Data(contentsOf: path) == original)
        }
        var future = project.document
        future.schemaVersion = 99
        try SnapshotStore.encoder.encode(future).write(to: path)
        #expect(throws: (any Error).self) { try AnnotationStore.openProject(at: directory) }
        try SnapshotStore.encoder.encode(wrongDimensions).write(to: path)
        #expect(throws: (any Error).self) { try AnnotationStore.openProject(at: directory) }
    }

    @Test func malformedCoordinatesStylesAndDuplicateIdentitiesAreRejected() throws {
        let valid = AnnotationDocument(sourceCaptureID: "capture", imageWidth: 64, imageHeight: 48,
            items: [AnnotationItem(kind: .rectangle, start: .init(x: 64, y: 48), end: .init())])
        try valid.validate()
        var cases: [AnnotationDocument] = []
        var document = valid
        document.schemaVersion = 0; cases.append(document)
        document = valid; document.sourceCaptureID = " "; cases.append(document)
        document = valid; document.imageWidth = 0; cases.append(document)
        document = valid; document.items[0].start.x = .nan; cases.append(document)
        document = valid; document.items[0].end.y = .infinity; cases.append(document)
        document = valid; document.items[0].start.x = -0.1; cases.append(document)
        document = valid; document.items[0].end.y = 49; cases.append(document)
        document = valid; document.items[0].strokeWidth = 0; cases.append(document)
        document = valid; document.items[0].colorHex = "red"; cases.append(document)
        document = valid; document.items[0].number = 0; cases.append(document)
        document = valid; document.items.append(document.items[0]); cases.append(document)
        for invalid in cases { #expect(throws: (any Error).self) { try invalid.validate() } }
        let encoded = String(data: try SnapshotStore.encoder.encode(valid), encoding: .utf8)!
        let unknownKind = encoded.replacingOccurrences(of: "\"rectangle\"", with: "\"unknown-shape\"")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AnnotationDocument.self, from: Data(unknownKind.utf8))
        }
    }

    @Test func copyRejectsLinksAndNestedDestinationWithoutChangingSource() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try fixtureCapture(in: root)
        let source = try AnnotationStore.openCapture(at: capture)
        #expect(throws: (any Error).self) {
            try AnnotationStore.createProject(from: source, document: source.document,
                at: capture.appendingPathComponent("nested.oneshot"))
        }
        #expect(!FileManager.default.fileExists(atPath: capture.appendingPathComponent("nested.oneshot").path))
        let linked = capture.appendingPathComponent("linked-context.txt")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: capture.appendingPathComponent("context.txt"))
        let destination = root.appendingPathComponent("refused.oneshot")
        #expect(throws: (any Error).self) {
            try AnnotationStore.createProject(from: source, document: source.document, at: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try String(contentsOf: capture.appendingPathComponent("context.txt"), encoding: .utf8) == "冻结的完整上下文\n未标注区域也保留。")
        let linkedDirectory = root.appendingPathComponent("linked-capture")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: capture)
        #expect(throws: (any Error).self) { try AnnotationStore.openCapture(at: linkedDirectory) }
    }

    @Test func captureImagePathCannotEscapeDirectoryOrFollowLink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try fixtureCapture(in: root)
        let originalPNG = capture.appendingPathComponent("screenshot.png")
        let outsidePNG = root.appendingPathComponent("outside.png")
        try FileManager.default.moveItem(at: originalPNG, to: outsidePNG)
        try FileManager.default.createSymbolicLink(at: originalPNG, withDestinationURL: outsidePNG)
        #expect(throws: (any Error).self) { try AnnotationStore.openCapture(at: capture) }
        let manifestURL = capture.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["screenshot"] = ["status": "captured", "file": "../outside.png"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        #expect(throws: (any Error).self) { try AnnotationStore.openCapture(at: capture) }
    }

    @Test func frozenElementsProjectDesktopCoordinatesAndRetainOffImageTreeNodes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try fixtureCapture(in: root)
        try fixtureAX(in: capture)
        let project = try AnnotationStore.openCapture(at: capture)
        let index = try CapturedElementIndex.load(from: project)
        #expect(index.elements.count == 7)
        #expect(index.element(id: "button")?.imageBounds == CaptureRect(x: 8, y: 12, width: 16, height: 12))
        #expect(index.element(id: "clipped")?.imageBounds == CaptureRect(x: 0, y: 0, width: 8, height: 8))
        #expect(index.element(id: "offscreen")?.imageBounds == nil)
        #expect(index.element(id: "zero")?.imageBounds == nil)
        #expect(index.element(id: "button")?.label == "保存")
        #expect(index.element(id: "button")?.parentID == "window")
        #expect(index.hitTest(point: .init(x: 9, y: 13))?.id == "button")
        #expect(index.hitTest(point: .init(x: 13, y: 17))?.id == "label")
        #expect(index.hitTest(point: .init(x: -1, y: 0)) == nil)
        #expect(index.status.contains("部分属性读取失败"))
        try FileManager.default.removeItem(at: capture.appendingPathComponent("screenshot.json"))
        let withoutMapping = try CapturedElementIndex.load(from: project)
        #expect(withoutMapping.elements.count == 7)
        #expect(withoutMapping.elements.allSatisfy { $0.imageBounds == nil })
        #expect(withoutMapping.status.contains("定位信息"))
    }

    @Test func boundElementAnnotationsRoundTripAndRejectUnknownNodeOrForgedFrame() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try fixtureCapture(in: root)
        try fixtureAX(in: capture)
        let source = try AnnotationStore.openCapture(at: capture)
        var document = source.document
        document.items = [
            AnnotationItem(kind: .element, start: .init(x: 8, y: 12), end: .init(x: 24, y: 24),
                           text: "按钮需要更清楚的说明", targetNodeID: "button"),
            AnnotationItem(kind: .element, text: "屏幕外元素仍可评论", targetNodeID: "offscreen"),
        ]
        let destination = root.appendingPathComponent("bound.oneshot")
        let saved = try AnnotationStore.createProject(from: source, document: document, at: destination)
        #expect(saved.document == document)
        #expect(try AnnotationStore.openProject(at: destination).document.items[1].targetNodeID == "offscreen")
        let annotations = destination.appendingPathComponent("annotations.json")
        let original = try Data(contentsOf: annotations)
        var invalid = document
        invalid.items[0].targetNodeID = "absent"
        #expect(throws: (any Error).self) { try AnnotationStore.save(document: invalid, in: destination) }
        invalid = document
        invalid.items[0].start.x += 2
        #expect(throws: (any Error).self) { try AnnotationStore.save(document: invalid, in: destination) }
        invalid = document
        invalid.items[1].start.x = 2
        #expect(throws: (any Error).self) { try AnnotationStore.save(document: invalid, in: destination) }
        #expect(try Data(contentsOf: annotations) == original)
        invalid = document
        invalid.items[0].targetNodeID = nil
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.items[0].targetNodeID = "absent"
        try SnapshotStore.encoder.encode(invalid).write(to: annotations)
        #expect(throws: (any Error).self) { try AnnotationStore.openProject(at: destination) }
    }

    @Test func oldAnnotationsDecodeWithoutElementBindingAndMissingAXIsExplicit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try fixtureCapture(in: root)
        let source = try AnnotationStore.openCapture(at: capture)
        var document = source.document
        document.items = [AnnotationItem(kind: .number, start: .init(x: 12, y: 12))]
        let data = try SnapshotStore.encoder.encode(document)
        #expect(!String(decoding: data, as: UTF8.self).contains("targetNodeID"))
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: data) == document)
        try FileManager.default.removeItem(at: capture.appendingPathComponent("accessibility.json"))
        let index = try CapturedElementIndex.load(from: source)
        #expect(index.elements.isEmpty)
        #expect(index.status.contains("没有 AX"))
        document.items = [AnnotationItem(kind: .element, targetNodeID: "unavailable")]
        #expect(throws: (any Error).self) {
            try AnnotationStore.createProject(from: source, document: document, at: root.appendingPathComponent("missing.oneshot"))
        }
    }

    @Test func malformedFrozenTreeDoesNotProduceAmbiguousBindings() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try fixtureCapture(in: root)
        let source = try AnnotationStore.openCapture(at: capture)
        let url = capture.appendingPathComponent("accessibility.json")
        let malformedCases: [[[String: Any]]] = [
            [["id": "duplicate", "depth": 0, "attributes": [:]], ["id": "duplicate", "depth": 1, "attributes": [:]]],
            [["id": "a", "parentID": "b", "depth": 1, "attributes": [:]], ["id": "b", "parentID": "a", "depth": 2, "attributes": [:]]],
        ]
        for nodes in malformedCases {
            try JSONSerialization.data(withJSONObject: ["nodes": nodes]).write(to: url)
            #expect(throws: (any Error).self) { try CapturedElementIndex.load(from: source) }
        }
    }

    private func fixtureAX(in capture: URL) throws {
        func node(_ id: String, role: String, label: String = "", depth: Int = 1,
                  frame: [Double]) -> [String: Any] {
            var result: [String: Any] = ["id": id, "depth": depth, "attributes": [
                "AXRole": ["status": "ok", "value": ["text": role]],
                "AXTitle": ["status": "ok", "value": ["text": label]],
                "AXDescription": ["status": "ok", "value": ["text": label.isEmpty ? "" : "重复说明"]],
                "AXValue": ["status": "ok", "value": ["text": label.isEmpty ? "" : String(repeating: "重复长正文", count: 100)]],
                "AXFrame": ["status": "ok", "value": ["components": ["x": frame[0], "y": frame[1], "width": frame[2], "height": frame[3]]]],
            ]]
            if id != "window" { result["parentID"] = "window" }
            return result
        }
        let nodes = [
            node("window", role: "AXWindow", label: "测试窗口", depth: 0, frame: [100, 200, 32, 24]),
            node("button", role: "AXButton", label: "保存", frame: [104, 206, 8, 6]),
            node("empty-group", role: "AXGroup", depth: 9, frame: [104, 206, 8, 6]),
            node("label", role: "AXStaticText", label: "说明", depth: 2, frame: [106, 208, 2, 2]),
            node("offscreen", role: "AXStaticText", label: "屏幕外", frame: [100, 230, 8, 6]),
            node("zero", role: "AXStaticText", label: "未布局", frame: [104, 204, 0, 0]),
            node("clipped", role: "AXButton", label: "部分可见", frame: [96, 198, 8, 6]),
        ]
        try JSONSerialization.data(withJSONObject: ["completeness": "partial_read_errors", "nodes": nodes])
            .write(to: capture.appendingPathComponent("accessibility.json"))
        try JSONSerialization.data(withJSONObject: ["pixelWidth": 64, "pixelHeight": 48,
            "capturedBounds": ["x": 100, "y": 200, "width": 32, "height": 24]])
            .write(to: capture.appendingPathComponent("screenshot.json"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-annotations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func fixtureCapture(in root: URL) throws -> URL {
        let store = try SnapshotStore(newDirectory: root.appendingPathComponent("source-capture"))
        let window = CaptureWindow(id: 1, pid: 42, ownerName: "Fixture", title: "Fixture",
            bounds: .init(x: 0, y: 0, width: 32, height: 24), isOnScreen: true)
        let manifest = SnapshotManifest(captureID: "capture-fixture", startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1), requestedApp: "example.fixture", applicationVersion: "1",
            window: window, windowAfter: window, accessibility: .init(status: "captured", file: "accessibility.json"),
            screenshot: .init(status: "captured", file: "screenshot.png"),
            ocr: .init(status: "captured", file: "ocr.json"), consistency: "fixture", notes: [])
        try store.write(manifest, named: "manifest.json")
        try store.writeText("冻结的完整上下文\n未标注区域也保留。", named: "context.txt")
        try store.writeText("{\"nodes\": [{\"id\": \"unmarked-node\"}]}", named: "accessibility.json")
        try store.writeText("{\"observations\": []}", named: "ocr.json")
        // Deliberately misleading side metadata: image dimensions come from actual image bytes.
        try store.writeText("{\"pixelWidth\": 999, \"pixelHeight\": 999}", named: "screenshot.json")
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

    private func captureFiles(_ directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
