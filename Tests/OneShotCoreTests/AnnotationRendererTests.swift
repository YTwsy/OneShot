import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OneShotCore

struct AnnotationRendererTests {
    @Test func elementAnnotationsRenderGeometryButKeepNotesAndOffscreenReferencesOutOfPNG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-element-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        try Self.writeFixture(to: original)
        var document = AnnotationDocument(sourceCaptureID: "fixture", imageWidth: 400, imageHeight: 300)
        let offscreen = AnnotationItem(kind: .element, start: .init(), end: .init(),
                                      text: "没有可见边框的元素备注", targetNodeID: "n2")
        #expect(!AnnotationRenderer.hitTest(.zero, item: offscreen, imageSize: CGSize(width: 400, height: 300)))
        let empty = root.appendingPathComponent("empty.png")
        try AnnotationRenderer.exportPNG(imageURL: original, document: document, to: empty)
        document.items = [offscreen]
        let invisible = root.appendingPathComponent("offscreen.png")
        try AnnotationRenderer.exportPNG(imageURL: original, document: document, to: invisible)
        #expect(try Data(contentsOf: empty) == Data(contentsOf: invisible))

        document.items = [AnnotationItem(kind: .element, start: .init(x: 50, y: 60),
            end: .init(x: 170, y: 100), text: "这条很长的备注只保存在项目，不写进导出图。",
            colorHex: "#00AA00", strokeWidth: 4, number: 2, targetNodeID: "n1")]
        let annotated = root.appendingPathComponent("element.png")
        try AnnotationRenderer.exportPNG(imageURL: original, document: document, to: annotated)
        let pixels = try #require(NSBitmapImageRep(data: Data(contentsOf: annotated)))
        let border = try #require(pixels.colorAt(x: 170, y: 90)?.usingColorSpace(.sRGB))
        #expect(border.greenComponent > 0.5 && border.redComponent < 0.5)
        document.items[0].text = ""
        let withoutNote = root.appendingPathComponent("without-note.png")
        try AnnotationRenderer.exportPNG(imageURL: original, document: document, to: withoutNote)
        #expect(try Data(contentsOf: annotated) == Data(contentsOf: withoutNote))
    }

    @Test func exportPreservesNativePixelsAndTopLeftAnnotationCoordinates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        try Self.writeFixture(to: original)
        let originalData = try Data(contentsOf: original)
        let plain = AnnotationDocument(sourceCaptureID: "fixture", imageWidth: 400, imageHeight: 300)
        let copy = root.appendingPathComponent("plain.png")
        try AnnotationRenderer.exportPNG(imageURL: original, document: plain, to: copy)
        let unchanged = try #require(NSBitmapImageRep(data: Data(contentsOf: copy)))
        #expect(unchanged.pixelsWide == 400)
        #expect(unchanged.pixelsHigh == 300)
        // Asymmetric bands catch vertical flips, independently of the annotation code.
        let top = try #require(unchanged.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        let bottom = try #require(unchanged.colorAt(x: 10, y: 290)?.usingColorSpace(.sRGB))
        #expect(top.redComponent > 0.9 && top.blueComponent < 0.1)
        #expect(bottom.blueComponent > 0.9 && bottom.redComponent < 0.1)

        var annotated = plain
        annotated.items = [
            AnnotationItem(kind: .rectangle, start: .init(x: 50, y: 40), end: .init(x: 120, y: 90), colorHex: "#00AA00", strokeWidth: 6),
            AnnotationItem(kind: .arrow, start: .init(x: 40, y: 160), end: .init(x: 180, y: 160), colorHex: "#FF0000", strokeWidth: 6),
            AnnotationItem(kind: .text, start: .init(x: 210, y: 90), end: .init(x: 210, y: 90), text: "中文说明", colorHex: "#000000"),
            AnnotationItem(kind: .number, start: .init(x: 300, y: 220), end: .init(x: 300, y: 220), colorHex: "#FF0000", number: 7),
        ]
        let output = root.appendingPathComponent("annotated.png")
        try AnnotationRenderer.exportPNG(imageURL: original, document: annotated, to: output)
        let pixels = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        let rectangle = try #require(pixels.colorAt(x: 50, y: 60)?.usingColorSpace(.sRGB))
        #expect(rectangle.greenComponent > 0.5 && rectangle.redComponent < 0.2)
        let belowRectangle = try #require(pixels.colorAt(x: 50, y: 240)?.usingColorSpace(.sRGB))
        #expect(belowRectangle.redComponent > 0.9 && belowRectangle.greenComponent > 0.9)
        // Sample beyond the shaft and inside the triangle, away from its antialiased edge.
        let arrowHead = try #require(pixels.colorAt(x: 165, y: 164)?.usingColorSpace(.sRGB))
        #expect(arrowHead.redComponent > 0.8 && arrowHead.greenComponent < 0.2)
        let outsideArrow = try #require(pixels.colorAt(x: 165, y: 180)?.usingColorSpace(.sRGB))
        #expect(outsideArrow.redComponent > 0.9 && outsideArrow.greenComponent > 0.9)
        #expect(try Data(contentsOf: original) == originalData)
    }

    @Test func exportRejectsWrongImageAndExistingDestinationWithoutChangingEither() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oneshot-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        try Self.writeFixture(to: original)
        let before = try Data(contentsOf: original)
        var document = AnnotationDocument(sourceCaptureID: "fixture", imageWidth: 400, imageHeight: 300)
        #expect(throws: (any Error).self) {
            try AnnotationRenderer.exportPNG(imageURL: original, document: document, to: original)
        }
        let existing = root.appendingPathComponent("existing.png")
        try Data("keep me".utf8).write(to: existing)
        #expect(throws: (any Error).self) {
            try AnnotationRenderer.exportPNG(imageURL: original, document: document, to: existing)
        }
        document.imageWidth = 399
        #expect(throws: (any Error).self) {
            try AnnotationRenderer.exportPNG(imageURL: original, document: document, to: root.appendingPathComponent("mismatch.png"))
        }
        #expect(try Data(contentsOf: original) == before)
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("mismatch.png").path))
    }

    private static func writeFixture(to url: URL) throws {
        let width = 400, height = 300
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if y < 20 { bytes[i] = 255; bytes[i + 1] = 0; bytes[i + 2] = 0 }
                if y >= height - 20 { bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 255 }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
