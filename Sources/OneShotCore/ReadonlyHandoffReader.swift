import Darwin
import Foundation
import CoreGraphics
import ImageIO

public struct HandoffTextPage: Codable {
    public let captureID: String
    public let source: String
    public let offset: Int
    public let nextOffset: Int
    public let totalBytes: Int
    public let hasMore: Bool
    public let text: String
}

extension ReadonlyHandoffReader {
    /// A bounded first read. Full user notes/segments are preferred; oversized rows
    /// retain explicit continuation pointers rather than silently losing content.
    public func readHandoff(reference: String) throws -> [String: Any] {
        try files["handoff"]!.requireUnchanged()
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: SnapshotStore.encoder.encode(value))
        }
        var budget = 48_000
        var feedbacks: [[String: Any]] = []
        var targetIDs: [String] = []
        func includeTarget(_ id: String) {
            if !targetIDs.contains(id) && targetIDs.count < 40 { targetIDs.append(id) }
        }
        for entry in document.feedbacks.prefix(20) {
            let numbers = Dictionary(uniqueKeysWithValues: entry.references.map { ($0.reference.id, $0.referenceNumber) })
            let display = entry.feedback.content.map { segment -> String in
                switch segment {
                case .text(let value): return value
                case .control(let ref): return "[R\(numbers[ref.id] ?? 0) \(ref.label)]"
                }
            }.joined()
            let encoded = try SnapshotStore.encoder.encode(entry.feedback)
            let full = encoded.count + display.utf8.count <= budget
            let note = Self.preview(display, maximumBytes: full ? budget : min(2_000, budget))
            var row: [String: Any] = ["id": entry.feedback.id.uuidString, "order": entry.order,
                "userText": note.text, "contentTruncated": !full, "imageId": "annotated",
                "details": ["kind": "feedback", "id": String(entry.order), "offset": 0]]
            if full { row["content"] = try object(entry.feedback.content) }
            row["references"] = entry.references.prefix(40).map { binding -> [String: Any] in
                includeTarget(binding.reference.nodeID)
                var ref: [String: Any] = ["occurrenceId": binding.reference.id.uuidString,
                    "targetId": binding.reference.nodeID, "badge": "R\(binding.referenceNumber)"]
                if let n = binding.imageBadgeNumber { ref["imageBadge"] = "R\(n)" }
                return ref
            }
            row["referencesTruncated"] = entry.references.count > 40
            feedbacks.append(row)
            budget = max(0, budget - (full ? encoded.count : 0) - note.text.utf8.count)
        }
        var annotations: [[String: Any]] = []
        for entry in document.annotations.prefix(20) {
            let note = Self.preview(entry.annotation.text, maximumBytes: min(4_000, budget))
            var row: [String: Any] = ["id": entry.annotation.id.uuidString, "order": entry.order,
                "kind": entry.annotation.kind.rawValue, "userText": note.text,
                "contentTruncated": note.truncated, "start": try object(entry.annotation.start),
                "end": try object(entry.annotation.end), "imageId": "annotated",
                "details": ["kind": "annotation", "id": String(entry.order), "offset": 0]]
            if let id = entry.annotation.targetNodeID { row["targetId"] = id; includeTarget(id) }
            if let number = entry.imageBadgeNumber { row["imageBadge"] = number }
            annotations.append(row); budget = max(0, budget - note.text.utf8.count)
        }
        var nodes: [String: AgentHandoffValue] = [:]
        for entry in document.feedbacks {
            for ref in entry.references where targetIDs.contains(ref.reference.nodeID) { nodes[ref.reference.nodeID] = ref.targetNode }
        }
        for entry in document.annotations {
            if let id = entry.annotation.targetNodeID, targetIDs.contains(id) { nodes[id] = entry.targetNode }
        }
        var geometry: [String: Any]?
        if let file = files["screenshot_geometry"] {
            geometry = try JSONSerialization.jsonObject(with: file.readAll(maximum: 1_048_576)) as? [String: Any]
        }
        let targets = try targetIDs.compactMap { id -> [String: Any]? in
            guard let node = nodes[id] else { return nil }
            let role = Self.preview(Self.textAttribute("AXRole", in: node) ?? "", maximumBytes: 256)
            let label = Self.preview(["AXTitle", "AXDescription", "AXValue"].compactMap { Self.textAttribute($0, in: node) }
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? "", maximumBytes: 1_024)
            var row: [String: Any] = ["id": id, "binding": ["kind": "ax", "captureId": document.captureID, "nodeId": id],
                "role": role.text, "label": label.text, "labelTruncated": label.truncated,
                "details": ["kind": "target", "id": id, "offset": 0]]
            if let parent = node["parentID"]?.stringValue { row["parentId"] = parent }
            var states: [String: Any] = [:]
            for name in ["AXEnabled", "AXFocused", "AXSelected", "AXExpanded"] {
                if let attribute = node["attributes"]?[name] { states[name] = try object(attribute) }
            }
            row["states"] = states
            if let frame = node["attributes"]?["AXFrame"]?["value"]?["components"],
               let rect = try object(frame) as? [String: Any],
               let bounds = Self.imageBounds(rect, geometry: geometry, width: document.imageWidth, height: document.imageHeight) {
                row["imageBounds"] = bounds; row["imageId"] = "annotated"
            }
            return row
        }
        var context: [String: Any] = ["available": false]
        if files["context"] != nil { context = ["available": true, "page": try object(readContext(limit: 4_000))] }
        return ["schemaVersion": 2, "reference": reference, "captureId": document.captureID,
            "capture": try object(document.capture), "feedbacks": feedbacks, "annotations": annotations,
            "feedbackCount": document.feedbacks.count, "annotationCount": document.annotations.count,
            "feedbacksHasMore": document.feedbacks.count > feedbacks.count, "feedbacksNextOffset": feedbacks.count,
            "annotationsHasMore": document.annotations.count > annotations.count, "annotationsNextOffset": annotations.count,
            "targets": targets, "targetSummaryLimit": 40,
            "targetSummariesTruncated": Set(document.feedbacks.flatMap(\.references).map { $0.reference.nodeID }
                + document.annotations.compactMap { $0.annotation.targetNodeID }).count > targets.count,
            "coordinateSpace": ["unit": "original_image_pixels", "origin": "top_left",
                "width": document.imageWidth, "height": document.imageHeight],
            "context": context, "availableSources": ContextSource.allCases.filter { files[$0.rawValue] != nil }.map(\.rawValue),
            "interpretation": document.interpretation,
            "continuation": "Use read_details(reference, kind: feedbacks/annotations, offset) for more rows; feedback/annotation with one-based id for complete notes; target with node id for full AX. Text pages use UTF-8 byte offsets and nextOffset. Source capture errors/truncation are recorded separately in capture and original AX diagnostics."]
    }

    public func readNode(id: String, offset: Int = 0, limit: Int = 12_000) throws -> HandoffTextPage {
        guard id.utf8.count <= 4_096, let file = files["accessibility"] else { throw HandoffReadError.unavailable }
        let nodes = try JSONDecoder().decode(FrozenNodes.self, from: file.readAll(maximum: 512 * 1_024 * 1_024)).nodes
        guard nodes.count <= 100_000 else { throw HandoffReadError.invalidPackage("AX 节点过多。") }
        let matching = nodes.filter { $0["id"]?.stringValue == id }
        guard matching.count == 1 else { throw HandoffReadError.unavailable }
        return try Self.textPage(data: SnapshotStore.encoder.encode(matching[0]), captureID: document.captureID,
            source: "target:\(id)", offset: offset, limit: limit)
    }

    private static func imageBounds(_ frame: [String: Any], geometry: [String: Any]?, width: Int, height: Int) -> [String: Double]? {
        guard let geometry, geometry["pixelWidth"] as? Int == width, geometry["pixelHeight"] as? Int == height,
              let bounds = geometry["capturedBounds"] as? [String: Double],
              let bx = bounds["x"], let by = bounds["y"], let bw = bounds["width"], let bh = bounds["height"],
              let x = frame["x"] as? Double, let y = frame["y"] as? Double,
              let w = frame["width"] as? Double, let h = frame["height"] as? Double,
              [bx, by, bw, bh, x, y, w, h].allSatisfy(\.isFinite), bw > 0, bh > 0, w > 0, h > 0 else { return nil }
        let left = max(0, (x - bx) * Double(width) / bw), top = max(0, (y - by) * Double(height) / bh)
        let right = min(Double(width), (x + w - bx) * Double(width) / bw)
        let bottom = min(Double(height), (y + h - by) * Double(height) / bh)
        guard right > left, bottom > top else { return nil }
        return ["x": left, "y": top, "width": right - left, "height": bottom - top]
    }

    /// Decodes only a thumbnail unless a full-resolution region is requested.
    /// Returned mapping always refers to the original top-left image pixels.
    public func presentationImage(annotated: Bool, region: CGRect? = nil) throws -> (data: Data, metadata: [String: Any]) {
        guard let file = files[annotated ? "annotated" : "raw"] else { throw HandoffReadError.unavailable }
        let data = try file.readAll(maximum: 512 * 1_024 * 1_024)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == document.imageWidth,
              properties[kCGImagePropertyPixelHeight] as? Int == document.imageHeight else {
            throw HandoffReadError.invalidPackage("图片尺寸与材料不一致。")
        }
        let full = CGRect(x: 0, y: 0, width: document.imageWidth, height: document.imageHeight)
        let image: CGImage
        if let region {
            guard region.width > 0, region.height > 0, region == region.integral, full.contains(region),
                  region.width <= 4096, region.height <= 4096,
                  let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let cropped = original.cropping(to: region) else { throw HandoffReadError.invalidRange }
            image = cropped
        } else {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ] as CFDictionary) else { throw HandoffReadError.unavailable }
            image = thumbnail
        }
        let result = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil) else { throw HandoffReadError.unavailable }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw HandoffReadError.unavailable }
        guard result.length <= 10 * 1_024 * 1_024 else { throw HandoffReadError.imageTooLarge }
        let rect = region ?? full
        return (result as Data, ["imageId": annotated ? "annotated" : "raw", "mimeType": "image/png",
            "width": image.width, "height": image.height, "originalWidth": document.imageWidth, "originalHeight": document.imageHeight,
            "originalRegion": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height],
            "originalPixelsPerReturnedPixel": ["x": rect.width / Double(image.width), "y": rect.height / Double(image.height)],
            "origin": "top_left"])
    }
}

public enum HandoffReadError: LocalizedError {
    case invalidPackage(String)
    case invalidRange
    case unavailable
    case changed
    case imageTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidPackage(let message): return "无法读取交付材料：\(message)"
        case .invalidRange: return "分页范围无效。offset 使用 UTF-8 字节位置，请沿用上一页的 nextOffset；limit 须为 4…65536。"
        case .unavailable: return "这次采集没有所请求的材料。"
        case .changed: return "材料在 MCP 启动后发生变化，请重新确认交付目录并重启 MCP。"
        case .imageTooLarge: return "原始图片超过 MCP 单次 10 MiB 图片上限，请通过本机文件路径读取完整图片。"
        }
    }
}

/// Pins one explicitly selected export. Files are opened once using openat/O_NOFOLLOW;
/// clients cannot supply paths, and later directory replacements cannot widen access.
public final class ReadonlyHandoffReader {
    public enum ContextSource: String, CaseIterable {
        case context, accessibility, ocr, manifest, screenshotGeometry = "screenshot_geometry"
    }

    public let directory: URL
    public let document: AgentHandoffDocument
    private let files: [String: PinnedFile]
    private var cachedAnnotation: (order: Int, data: Data)?
    private var cachedFeedback: (order: Int, data: Data)?

    public init(directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw HandoffReadError.invalidPackage("必须显式选择绝对路径的本地交付目录。")
        }
        self.directory = directory.standardizedFileURL
        let root = Darwin.open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw HandoffReadError.invalidPackage("目录不存在、不可读或为符号链接。") }
        defer { Darwin.close(root) }
        var pinned: [String: PinnedFile] = [:]
        for (key, path, required) in [
            ("brief", "AGENT.md", true), ("handoff", "handoff.json", true),
            ("annotations", "source.oneshot/annotations.json", true),
            ("manifest", "source.oneshot/capture/manifest.json", true),
            ("context", "source.oneshot/capture/context.txt", false),
            ("accessibility", "source.oneshot/capture/accessibility.json", false),
            ("ocr", "source.oneshot/capture/ocr.json", false),
            ("screenshot_geometry", "source.oneshot/capture/screenshot.json", false),
            ("annotated", "annotated.png", true),
        ] {
            if let file = try Self.openFile(root: root, relative: path, required: required) { pinned[key] = file }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let handoff = try decoder.decode(AgentHandoffDocument.self,
            from: pinned["handoff"]!.readAll(maximum: AgentHandoffStore.maximumDocumentBytes))
        let manifest = try decoder.decode(SnapshotManifest.self, from: pinned["manifest"]!.readAll(maximum: 1_048_576))
        let annotations = try JSONDecoder().decode(AnnotationDocument.self, from: pinned["annotations"]!.readAll(maximum: 4 * 1_024 * 1_024))
        try annotations.validate()
        guard handoff.schemaVersion == 1, manifest.schemaVersion == 1,
              handoff.captureID == manifest.captureID, annotations.sourceCaptureID == manifest.captureID,
              handoff.capture.captureID == manifest.captureID,
              try SnapshotStore.encoder.encode(handoff.capture) == SnapshotStore.encoder.encode(manifest),
              handoff.projectID == annotations.id,
              handoff.imageWidth == annotations.imageWidth, handoff.imageHeight == annotations.imageHeight,
              handoff.annotations.map(\.annotation) == annotations.items,
              handoff.annotations.enumerated().allSatisfy({ $0.element.order == $0.offset + 1 }),
              handoff.feedbacks.map(\.feedback) == annotations.feedbacks,
              handoff.feedbacks.enumerated().allSatisfy({ $0.element.order == $0.offset + 1 }),
              handoff.feedbacks.allSatisfy({ $0.references.map(\.reference) == $0.feedback.controlReferences }),
              manifest.screenshot.status == "captured", let image = manifest.screenshot.file,
              Self.safeName(image) else {
            throw HandoffReadError.invalidPackage("采集、标注和交付材料的身份不一致。")
        }
        let targets = Set(annotations.items.compactMap(\.targetNodeID) + annotations.feedbackControlReferences.map(\.nodeID))
        let referenceNumbers = Dictionary(uniqueKeysWithValues: annotations.feedbackControlReferences.enumerated()
            .map { ($0.element.nodeID, $0.offset + 1) })
        if !targets.isEmpty {
            guard let sourceAX = pinned["accessibility"] else {
                throw HandoffReadError.invalidPackage("标注对应的 AX 数据缺失。")
            }
            let nodes = try decoder.decode(FrozenNodes.self, from: sourceAX.readAll(maximum: 512 * 1_024 * 1_024)).nodes
            guard nodes.count <= 100_000 else { throw HandoffReadError.invalidPackage("AX 节点数量超过支持范围。") }
            var selected: [String: AgentHandoffValue] = [:]
            for node in nodes {
                guard let id = node["id"]?.stringValue, targets.contains(id) else { continue }
                guard selected.updateValue(node, forKey: id) == nil else {
                    throw HandoffReadError.invalidPackage("AX 节点身份重复。")
                }
            }
            for entry in handoff.annotations {
                guard let id = entry.annotation.targetNodeID else { continue }
                let node = selected[id]
                let role = Self.textAttribute("AXRole", in: node)
                let label = ["AXTitle", "AXDescription", "AXValue"].compactMap { Self.textAttribute($0, in: node) }
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                guard node != nil, entry.targetNode == node, entry.targetRole == role, entry.targetLabel == label else {
                    throw HandoffReadError.invalidPackage("标注目标与原始 AX 节点不一致。")
                }
            }
            for reference in handoff.feedbacks.flatMap(\.references) {
                let node = selected[reference.reference.nodeID]
                let role = Self.textAttribute("AXRole", in: node)
                let label = ["AXTitle", "AXDescription", "AXValue"].compactMap { Self.textAttribute($0, in: node) }
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                guard node != nil, reference.targetNode == node,
                      reference.targetRole == role, reference.targetLabel == label,
                      reference.referenceNumber == referenceNumbers[reference.reference.nodeID],
                      reference.imageBadgeNumber == nil || reference.imageBadgeNumber == reference.referenceNumber else {
                    throw HandoffReadError.invalidPackage("反馈引用与原始 AX 节点不一致。")
                }
            }
        }
        pinned["raw"] = try Self.openFile(root: root, relative: "source.oneshot/capture/" + image, required: true)
        self.document = handoff
        self.files = pinned
    }

    public func readBrief(offset: Int = 0, limit: Int = 12_000) throws -> HandoffTextPage {
        try page(file: "brief", offset: offset, limit: limit)
    }

    public func readContext(source: ContextSource = .context, offset: Int = 0, limit: Int = 12_000) throws -> HandoffTextPage {
        try page(file: source.rawValue, offset: offset, limit: limit)
    }

    /// Summary rows stay small; readAnnotation returns every byte of one full entry.
    public func readAnnotations(offset: Int = 0, limit: Int = 20) throws -> [String: Any] {
        guard offset >= 0, offset <= document.annotations.count, (1...100).contains(limit) else { throw HandoffReadError.invalidRange }
        try files["handoff"]!.requireUnchanged()
        let end = min(document.annotations.count, offset + limit)
        let rows: [[String: Any]] = document.annotations[offset..<end].map { entry in
            let annotation = entry.annotation
            let note = Self.preview(annotation.text, maximumBytes: 1_600)
            var row: [String: Any] = ["order": entry.order, "annotationID": annotation.id.uuidString,
                "kind": annotation.kind.rawValue, "userNote": note.text,
                "userNoteTruncated": note.truncated,
                "start": ["x": annotation.start.x, "y": annotation.start.y],
                "end": ["x": annotation.end.x, "y": annotation.end.y]]
            if let badge = entry.imageBadgeNumber { row["imageBadgeNumber"] = badge }
            if let node = annotation.targetNodeID { row["targetNodeID"] = node }
            if let role = entry.targetRole {
                let preview = Self.preview(role, maximumBytes: 256)
                row["targetRole"] = preview.text; row["targetRoleTruncated"] = preview.truncated
            }
            if let label = entry.targetLabel {
                let preview = Self.preview(label, maximumBytes: 640)
                row["targetLabel"] = preview.text; row["targetLabelTruncated"] = preview.truncated
            }
            return row
        }
        return ["captureID": document.captureID, "offset": offset, "nextOffset": end,
                "totalAnnotations": document.annotations.count, "hasMore": end < document.annotations.count,
                "totalFeedbacks": document.feedbacks.count,
                "annotations": rows, "fullDetails": "read_annotation(order, offset, limit) returns the complete user note and frozen AX node as paged JSON."]
    }

    public func readAnnotation(order: Int, offset: Int = 0, limit: Int = 12_000) throws -> HandoffTextPage {
        guard order > 0, order <= document.annotations.count, offset >= 0,
              (4...65_536).contains(limit) else { throw HandoffReadError.invalidRange }
        try files["handoff"]!.requireUnchanged()
        let data: Data
        if let cachedAnnotation, cachedAnnotation.order == order {
            data = cachedAnnotation.data
        } else {
            data = try SnapshotStore.encoder.encode(document.annotations[order - 1])
            cachedAnnotation = (order, data)
        }
        return try Self.textPage(data: data, captureID: document.captureID, source: "annotation:\(order)", offset: offset, limit: limit)
    }

    /// Feedback summaries retain reference identity without duplicating full frozen nodes.
    public func readFeedbacks(offset: Int = 0, limit: Int = 20) throws -> [String: Any] {
        guard offset >= 0, offset <= document.feedbacks.count, (1...100).contains(limit) else {
            throw HandoffReadError.invalidRange
        }
        try files["handoff"]!.requireUnchanged()
        let end = min(document.feedbacks.count, offset + limit)
        let rows: [[String: Any]] = document.feedbacks[offset..<end].map { entry in
            let note = Self.preview(entry.feedback.plainText, maximumBytes: 1_600)
            let references: [[String: Any]] = entry.references.prefix(8).map { binding in
                let label = Self.preview(binding.reference.label, maximumBytes: 160)
                var value: [String: Any] = ["referenceID": binding.reference.id.uuidString,
                    "nodeID": binding.reference.nodeID, "label": label.text, "labelTruncated": label.truncated,
                    "referenceNumber": binding.referenceNumber, "reference": "R\(binding.referenceNumber)"]
                if let badge = binding.imageBadgeNumber { value["imageBadge"] = "R\(badge)" }
                return value
            }
            return ["order": entry.order, "feedbackID": entry.feedback.id.uuidString,
                    "userNote": note.text, "userNoteTruncated": note.truncated,
                    "referenceCount": entry.references.count,
                    "referencesTruncated": entry.references.count > references.count, "references": references]
        }
        return ["captureID": document.captureID, "offset": offset, "nextOffset": end,
                "totalFeedbacks": document.feedbacks.count, "hasMore": end < document.feedbacks.count,
                "feedbacks": rows,
                "fullDetails": "read_feedback(order, offset, limit) returns the ordered text and references with every full frozen AX node as paged JSON."]
    }

    public func readFeedback(order: Int, offset: Int = 0, limit: Int = 12_000) throws -> HandoffTextPage {
        guard order > 0, order <= document.feedbacks.count, offset >= 0,
              (4...65_536).contains(limit) else { throw HandoffReadError.invalidRange }
        try files["handoff"]!.requireUnchanged()
        let data: Data
        if let cachedFeedback, cachedFeedback.order == order {
            data = cachedFeedback.data
        } else {
            data = try SnapshotStore.encoder.encode(document.feedbacks[order - 1])
            cachedFeedback = (order, data)
        }
        return try Self.textPage(data: data, captureID: document.captureID,
            source: "feedback:\(order)", offset: offset, limit: limit)
    }

    public func readFeedback(id: UUID, offset: Int = 0, limit: Int = 12_000) throws -> HandoffTextPage {
        guard let entry = document.feedbacks.first(where: { $0.feedback.id == id }) else {
            throw HandoffReadError.unavailable
        }
        return try readFeedback(order: entry.order, offset: offset, limit: limit)
    }

    private static func preview(_ value: String, maximumBytes: Int) -> (text: String, truncated: Bool) {
        var bytes = Array(value.utf8.prefix(maximumBytes))
        var text = String(bytes: bytes, encoding: .utf8)
        for _ in 0..<3 where text == nil && !bytes.isEmpty {
            bytes.removeLast(); text = String(bytes: bytes, encoding: .utf8)
        }
        return (text ?? "", value.utf8.count > bytes.count)
    }

    public func readImage(annotated: Bool = true) throws -> (data: Data, mimeType: String) {
        guard let file = files[annotated ? "annotated" : "raw"] else { throw HandoffReadError.unavailable }
        guard file.size <= 10 * 1_024 * 1_024 else { throw HandoffReadError.imageTooLarge }
        let data = try file.readAll(maximum: 10 * 1_024 * 1_024)
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(image) == 1, CGImageSourceGetStatus(image) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == document.imageWidth,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == document.imageHeight,
              let type = CGImageSourceGetType(image),
              ["public.png", "public.jpeg"].contains(type as String) else {
            throw HandoffReadError.invalidPackage("图片无效或与采集尺寸不一致。")
        }
        // Known formats do not need a LaunchServices type-registry lookup. That
        // registry may be unavailable to an otherwise valid headless stdio client.
        return (data, type as String == "public.png" ? "image/png" : "image/jpeg")
    }

    private func page(file key: String, offset: Int, limit: Int) throws -> HandoffTextPage {
        guard let file = files[key] else { throw HandoffReadError.unavailable }
        guard offset >= 0, offset <= file.size, (4...65_536).contains(limit) else { throw HandoffReadError.invalidRange }
        let data = try file.read(offset: offset, count: min(file.size - offset, limit))
        return try Self.textPage(data: data, captureID: document.captureID, source: key,
            offset: 0, limit: limit, absoluteOffset: offset, totalBytes: file.size)
    }

    private static func textPage(data: Data, captureID: String, source: String, offset: Int, limit: Int,
                                 absoluteOffset: Int? = nil, totalBytes: Int? = nil) throws -> HandoffTextPage {
        guard offset >= 0, offset <= data.count, (4...65_536).contains(limit) else { throw HandoffReadError.invalidRange }
        var chunk = data.subdata(in: offset..<min(data.count, offset + limit))
        // Never split a UTF-8 character at the nextOffset boundary.
        var text = String(data: chunk, encoding: .utf8)
        for _ in 0..<3 where text == nil && !chunk.isEmpty {
            chunk.removeLast(); text = String(data: chunk, encoding: .utf8)
        }
        guard let text, !chunk.isEmpty || offset == data.count else { throw HandoffReadError.invalidRange }
        let start = absoluteOffset ?? offset, total = totalBytes ?? data.count
        let next = start + chunk.count
        return HandoffTextPage(captureID: captureID, source: source, offset: start, nextOffset: next,
            totalBytes: total, hasMore: next < total, text: text)
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private struct FrozenNodes: Decodable { let nodes: [AgentHandoffValue] }

    private static func textAttribute(_ name: String, in node: AgentHandoffValue?) -> String? {
        guard let attribute = node?["attributes"]?[name], attribute["status"]?.stringValue == "ok" else { return nil }
        return attribute["value"]?["text"]?.stringValue
    }

    private static func openFile(root: Int32, relative: String, required: Bool) throws -> PinnedFile? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy(safeName) else { throw HandoffReadError.invalidPackage("文件路径无效。") }
        var parent = Darwin.dup(root)
        guard parent >= 0 else { throw HandoffReadError.invalidPackage("无法固定交付目录。") }
        defer { Darwin.close(parent) }
        for component in components.dropLast() {
            let next = Darwin.openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HandoffReadError.invalidPackage("材料目录不可读或包含符号链接。") }
            Darwin.close(parent); parent = next
        }
        let descriptor = Darwin.openat(parent, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, !required { return nil }
        guard descriptor >= 0 else { throw HandoffReadError.invalidPackage("材料文件不可读或包含符号链接。") }
        return try PinnedFile(descriptor: descriptor)
    }

    private final class PinnedFile {
        let descriptor: Int32
        let original: stat
        var size: Int { Int(original.st_size) }

        init(descriptor: Int32) throws {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_size <= 512 * 1_024 * 1_024 else {
                Darwin.close(descriptor)
                throw HandoffReadError.invalidPackage("材料不是常规文件或超过 512 MiB。")
            }
            self.descriptor = descriptor; original = info
        }
        deinit { Darwin.close(descriptor) }

        func requireUnchanged() throws {
            var current = stat()
            guard fstat(descriptor, &current) == 0, current.st_size == original.st_size,
                  current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else { throw HandoffReadError.changed }
        }

        func readAll(maximum: Int) throws -> Data {
            guard size <= maximum else { throw HandoffReadError.invalidPackage("材料超过支持大小。") }
            return try read(offset: 0, count: size)
        }

        func read(offset: Int, count: Int) throws -> Data {
            try requireUnchanged()
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { buffer in
                var completed = 0
                while completed < count {
                    let bytes = Darwin.pread(descriptor, buffer.baseAddress!.advanced(by: completed), count - completed, off_t(offset + completed))
                    if bytes < 0, errno == EINTR { continue }
                    guard bytes > 0 else { throw HandoffReadError.changed }
                    completed += bytes
                }
            }
            try requireUnchanged()
            return data
        }
    }
}
