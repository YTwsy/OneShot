import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AnnotationRenderError: LocalizedError {
    case invalidImage
    case imageSizeMismatch
    case unsafeDestination
    case bitmapUnavailable
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取原始截图。"
        case .imageSizeMismatch: return "截图像素尺寸与标注项目不一致。"
        case .unsafeDestination: return "导出必须使用新的 PNG 文件，不能覆盖原图或已有文件。"
        case .bitmapUnavailable: return "无法创建导出图像。"
        case .encodingFailed: return "PNG 编码失败。"
        }
    }
}

/// The editor and export share these drawing routines. All coordinates are original
/// image pixels from the top-left; callers supply a flipped NSGraphicsContext.
public enum AnnotationRenderer {
    public static func color(hex: String) -> NSColor {
        let string = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return .systemRed }
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                       green: Double((value >> 8) & 255) / 255,
                       blue: Double(value & 255) / 255, alpha: 1)
    }

    public static func bounds(for item: AnnotationItem, imageSize: CGSize) -> CGRect {
        let start = CGPoint(x: item.start.x, y: item.start.y)
        let end = CGPoint(x: item.end.x, y: item.end.y)
        switch item.kind {
        case .number:
            let radius = numberRadius(item)
            return CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
        case .text:
            let font = textFont(item)
            // Stable wrapping makes a text block keep its size while dragged; the canvas
            // translates its complete bounds back inside the image at placement time.
            let width = max(1, min(600, imageSize.width - 20))
            let measured = (item.text as NSString).boundingRect(
                with: CGSize(width: width, height: max(1, imageSize.height)),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font])
            return CGRect(x: start.x, y: start.y,
                          width: min(width, max(font.pointSize, ceil(measured.width))) + 20,
                          height: max(font.pointSize + 4, ceil(measured.height)) + 16)
        case .arrow, .rectangle, .element:
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
    }

    public static func hitTest(_ point: CGPoint, item: AnnotationItem,
                               imageSize: CGSize, tolerance: CGFloat = 8) -> Bool {
        if item.kind == .element {
            let rect = bounds(for: item, imageSize: imageSize)
            // Off-screen or geometry-less AX references remain editable in the list only.
            guard rect.width > 0, rect.height > 0 else { return false }
        }
        if item.kind != .arrow {
            return bounds(for: item, imageSize: imageSize).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
        let a = CGPoint(x: item.start.x, y: item.start.y)
        let b = CGPoint(x: item.end.x, y: item.end.y)
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
        let distance = hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
        return distance <= max(tolerance, item.strokeWidth * 2)
    }

    public static func draw(items: [AnnotationItem], imageSize: CGSize) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: CGRect(origin: .zero, size: imageSize)).addClip()
        for item in items { draw(item: item, imageSize: imageSize) }
    }

    /// Subtle R-prefixed badges for feedback controls. Their frozen bounds are
    /// independent of editable drawing annotations and are never persisted as geometry.
    public static func feedbackReferenceBadgeBounds(number: Int, elementBounds: CaptureRect,
                                                     imageSize: CGSize, scale: CGFloat = 1) -> CGRect {
        let safeScale = max(0.01, scale.isFinite ? scale : 1)
        let label = "R\(number)" as NSString
        let measured = label.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11 / safeScale, weight: .semibold)])
        let width = min(imageSize.width, measured.width + 10 / safeScale)
        let height = min(imageSize.height, measured.height + 5 / safeScale)
        let rect = elementBounds.cgRect
        return CGRect(x: min(max(0, rect.maxX - width / 2), max(0, imageSize.width - width)),
                      y: min(max(0, rect.minY - height / 2), max(0, imageSize.height - height)),
                      width: width, height: height)
    }

    public static func drawFeedbackReferences(document: AnnotationDocument, elementIndex: CapturedElementIndex,
                                               imageSize: CGSize, scale: CGFloat = 1,
                                               highlightedNodeID: String? = nil) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: CGRect(origin: .zero, size: imageSize)).addClip()
        let elements = Dictionary(uniqueKeysWithValues: elementIndex.elements.map { ($0.id, $0) })
        let safeScale = max(0.01, scale.isFinite ? scale : 1)
        let tint = NSColor.systemBlue
        for (offset, reference) in document.feedbackControlReferences.enumerated() {
            guard let bounds = elements[reference.nodeID]?.imageBounds else { continue }
            let rect = bounds.cgRect
            if reference.nodeID == highlightedNodeID {
                tint.withAlphaComponent(0.08).setFill()
                NSBezierPath(rect: rect).fill()
                tint.setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 1.5 / safeScale
                border.stroke()
            }
            let label = "R\(offset + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11 / safeScale, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let measured = label.size(withAttributes: attributes)
            let badge = feedbackReferenceBadgeBounds(number: offset + 1, elementBounds: bounds,
                                                      imageSize: imageSize, scale: safeScale)
            tint.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4 / safeScale, yRadius: 4 / safeScale).fill()
            label.draw(at: CGPoint(x: badge.midX - measured.width / 2, y: badge.midY - measured.height / 2),
                       withAttributes: attributes)
        }
    }

    private static func draw(item: AnnotationItem, imageSize: CGSize) {
        let tint = color(hex: item.colorHex)
        let start = CGPoint(x: item.start.x, y: item.start.y)
        let end = CGPoint(x: item.end.x, y: item.end.y)
        let width = CGFloat(item.strokeWidth)
        tint.setStroke()
        tint.setFill()
        switch item.kind {
        case .element:
            let rect = bounds(for: item, imageSize: imageSize)
            guard rect.width > 0, rect.height > 0 else { return }
            tint.withAlphaComponent(0.07).setFill()
            NSBezierPath(rect: rect).fill()
            tint.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = max(1, min(3, width * 0.6))
            border.stroke()
            let radius = max(16, min(24, width * 3))
            let badge = CGRect(x: min(rect.minX, max(0, imageSize.width - radius * 2)),
                               y: min(rect.minY, max(0, imageSize.height - radius * 2)),
                               width: radius * 2, height: radius * 2)
            tint.setFill()
            NSBezierPath(ovalIn: badge).fill()
            drawNumber(item.number, in: badge, radius: radius, tint: tint)
        case .rectangle:
            let path = NSBezierPath(rect: bounds(for: item, imageSize: imageSize))
            path.lineWidth = width
            path.lineJoinStyle = .round
            path.stroke()
        case .arrow:
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0 else { return }
            let ux = (end.x - start.x) / length, uy = (end.y - start.y) / length
            let head = min(length * 0.55, max(20, width * 4))
            let headWidth = head * 0.52
            let base = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: base)
            path.lineWidth = width
            path.lineCapStyle = .round
            path.stroke()
            let tip = NSBezierPath()
            tip.move(to: end)
            tip.line(to: CGPoint(x: base.x - uy * headWidth, y: base.y + ux * headWidth))
            tip.line(to: CGPoint(x: base.x + uy * headWidth, y: base.y - ux * headWidth))
            tip.close()
            tip.fill()
        case .number:
            let rect = bounds(for: item, imageSize: imageSize)
            NSBezierPath(ovalIn: rect).fill()
            drawNumber(item.number, in: rect, radius: numberRadius(item), tint: tint)
        case .text:
            let rect = bounds(for: item, imageSize: imageSize)
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            (item.text as NSString).draw(in: rect.insetBy(dx: 10, dy: 8), withAttributes: [
                .font: textFont(item), .foregroundColor: labelColor(on: tint),
            ])
        }
    }

    private static func numberRadius(_ item: AnnotationItem) -> CGFloat { max(18, item.strokeWidth * 4) }
    private static func drawNumber(_ number: Int, in rect: CGRect, radius: CGFloat, tint: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius * 1.12, weight: .bold),
            .foregroundColor: labelColor(on: tint), .paragraphStyle: style,
        ]
        let label = String(number) as NSString
        let labelHeight = label.size(withAttributes: attributes).height
        label.draw(in: CGRect(x: rect.minX, y: rect.midY - labelHeight / 2,
                              width: rect.width, height: labelHeight + 2), withAttributes: attributes)
    }
    private static func textFont(_ item: AnnotationItem) -> NSFont {
        NSFont.systemFont(ofSize: max(24, item.strokeWidth * 6), weight: .semibold)
    }

    private static func labelColor(on color: NSColor) -> NSColor {
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance > 0.65 ? NSColor(calibratedWhite: 0.08, alpha: 1) : .white
    }

    /// Writes a new PNG. The input image and captured context are never mutated.
    public static func exportPNG(imageURL: URL, document: AnnotationDocument, to outputURL: URL,
                                 elementIndex: CapturedElementIndex? = nil) throws {
        try document.validate()
        let feedbackElements: CapturedElementIndex?
        if document.feedbackControlReferences.isEmpty {
            feedbackElements = nil
        } else {
            feedbackElements = try elementIndex ?? CapturedElementIndex.load(from: AnnotationProject(
                document: document, captureDirectory: imageURL.deletingLastPathComponent(), imageURL: imageURL))
            let knownIDs = Set(feedbackElements!.elements.map(\.id))
            guard document.feedbackControlReferences.allSatisfy({ knownIDs.contains($0.nodeID) }) else {
                throw AnnotationError.invalidProject("反馈引用了此采集中不存在的 AX 节点。")
            }
        }
        let sourceURL = imageURL.resolvingSymlinksInPath().standardizedFileURL
        let destinationURL = outputURL.resolvingSymlinksInPath().standardizedFileURL
        guard sourceURL != destinationURL,
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw AnnotationRenderError.unsafeDestination
        }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AnnotationRenderError.invalidImage
        }
        guard original.width == document.imageWidth, original.height == document.imageHeight else {
            throw AnnotationRenderError.imageSizeMismatch
        }
        guard let bitmap = CGContext(data: nil, width: original.width, height: original.height,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AnnotationRenderError.bitmapUnavailable
        }
        bitmap.translateBy(x: 0, y: CGFloat(original.height))
        bitmap.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: true)
        let size = CGSize(width: original.width, height: original.height)
        let image = NSImage(cgImage: original, size: size)
        image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy,
                   fraction: 1, respectFlipped: true, hints: nil)
        draw(items: document.items, imageSize: size)
        if let feedbackElements {
            drawFeedbackReferences(document: document, elementIndex: feedbackElements, imageSize: size)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let flattened = bitmap.makeImage() else { throw AnnotationRenderError.bitmapUnavailable }
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw AnnotationRenderError.encodingFailed
        }
        CGImageDestinationAddImage(encoder, flattened, nil)
        guard CGImageDestinationFinalize(encoder) else { throw AnnotationRenderError.encodingFailed }
        // Foundation forbids combining .atomic and .withoutOverwriting. Finish a private
        // sibling file first, then link it into place: link fails if a destination appeared
        // meanwhile, and readers never see a partially encoded PNG under the chosen name.
        let temporary = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".oneshot-export-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data as Data)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.linkItem(at: temporary, to: outputURL)
    }
}
