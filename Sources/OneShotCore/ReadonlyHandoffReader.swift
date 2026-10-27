import Darwin
import Foundation
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
