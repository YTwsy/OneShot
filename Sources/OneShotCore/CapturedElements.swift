import Foundation

/// An element of a frozen AX snapshot. Off-image elements remain available in the tree.
public struct CapturedElement: Identifiable, Equatable {
    public let id: String
    public let parentID: String?
    public let depth: Int
    public let role: String
    public let label: String
    public let imageBounds: CaptureRect?

    public init(id: String, parentID: String? = nil, depth: Int = 0, role: String,
                label: String, imageBounds: CaptureRect? = nil) {
        self.id = id
        self.parentID = parentID
        self.depth = depth
        self.role = role
        self.label = label
        self.imageBounds = imageBounds
    }

    private static let containerRoles: Set<String> = [
        "AXUnknown", "AXApplication", "AXWindow", "AXGroup", "AXSplitGroup", "AXScrollArea",
        "AXWebArea", "AXToolbar", "AXList", "AXOutline", "AXTable", "AXTabGroup",
    ]

    fileprivate var isContainer: Bool { Self.containerRoles.contains(role) }
}

public struct CapturedElementIndex {
    public let elements: [CapturedElement]
    public let status: String

    public init(elements: [CapturedElement], status: String) {
        self.elements = elements
        self.status = status
    }

    public func element(id: String) -> CapturedElement? { elements.first { $0.id == id } }

    /// Prefer a precise/deep node. Empty layout containers cannot capture clicks on whitespace.
    public func hitTest(point: AnnotationPoint) -> CapturedElement? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return elements.filter { element in
            guard let bounds = element.imageBounds,
                  bounds.width > 0, bounds.height > 0,
                  !(element.isContainer && element.label.isEmpty) else { return false }
            return point.x >= bounds.x && point.y >= bounds.y
                && point.x <= bounds.x + bounds.width && point.y <= bounds.y + bounds.height
        }.min { left, right in
            let leftArea = left.imageBounds!.width * left.imageBounds!.height
            let rightArea = right.imageBounds!.width * right.imageBounds!.height
            if leftArea != rightArea { return leftArea < rightArea }
            if left.depth != right.depth { return left.depth > right.depth }
            if left.isContainer != right.isContainer { return !left.isContainer }
            return left.id < right.id
        }
    }

    public static func load(from project: AnnotationProject) throws -> CapturedElementIndex {
        let axURL = project.captureDirectory.appendingPathComponent("accessibility.json")
        guard FileManager.default.fileExists(atPath: axURL.path) else {
            return CapturedElementIndex(elements: [], status: "此采集没有 AX 元素数据")
        }
        let capture = try JSONDecoder().decode(FrozenAX.self,
            from: AnnotationStore.readRegular(axURL, maximum: 512 * 1_024 * 1_024))
        guard capture.nodes.count <= 100_000 else {
            throw AnnotationError.invalidCapture("AX 节点数量超过可编辑范围。")
        }
        var ids = Set<String>()
        for node in capture.nodes {
            guard !node.id.isEmpty, node.id.utf8.count <= 256,
                  ids.insert(node.id).inserted, node.depth >= 0, node.depth <= 1_000,
                  node.parentID != node.id else {
                throw AnnotationError.invalidCapture("AX 节点标识或层级无效。")
            }
        }
        try rejectParentCycles(capture.nodes)
        let geometryURL = project.captureDirectory.appendingPathComponent("screenshot.json")
        let geometry = try? JSONDecoder().decode(ImageGeometry.self,
            from: AnnotationStore.readRegular(geometryURL, maximum: 1_048_576))
        let usableGeometry = geometry.flatMap { $0.valid(for: project.document) ? $0 : nil }
        let elements = capture.nodes.map { node in
            let role = node.attributes["AXRole"]?.value?.text ?? "AXUnknown"
            let label = ["AXTitle", "AXDescription", "AXValue"].compactMap { name -> String? in
                guard let attribute = node.attributes[name], attribute.status == "ok",
                      let text = attribute.value?.text else { return nil }
                let compact = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                return compact.isEmpty ? nil : String(compact.prefix(160))
            }.first ?? ""
            let frame = node.attributes["AXFrame"]
            let bounds = frame?.status == "ok" ? frame?.value?.components : nil
            return CapturedElement(id: node.id, parentID: node.parentID, depth: node.depth,
                role: role, label: label, imageBounds: usableGeometry?.project(bounds))
        }
        let locationStatus = usableGeometry == nil ? "；缺少有效图片定位信息，仍可在树中标注" : ""
        let coverage: String
        switch capture.completeness {
        case "completed_requested_reads_application_exposure_unknown": coverage = "本次读取已完成，应用暴露范围未知"
        case "partial_read_errors": coverage = "部分属性读取失败"
        case "partial_budget_limited": coverage = "采集达到预算限制"
        default: coverage = "采集完整度未确认"
        }
        return CapturedElementIndex(elements: elements,
            status: "已读取 \(elements.count) 个元素 · \(coverage)\(locationStatus)")
    }

    private static func rejectParentCycles(_ nodes: [FrozenNode]) throws {
        let parents = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parentID) })
        var finished = Set<String>()
        for node in nodes where !finished.contains(node.id) {
            var chain = Set<String>()
            var cursor: String? = node.id
            while let id = cursor, !finished.contains(id) {
                guard chain.insert(id).inserted else {
                    throw AnnotationError.invalidCapture("AX 父子关系包含循环。")
                }
                cursor = parents[id] ?? nil
            }
            finished.formUnion(chain)
        }
    }

    // Decode only the projection's fields, not duplicated rich text/runs or live AX handles.
    private struct FrozenAX: Decodable {
        let completeness: String?
        let nodes: [FrozenNode]
    }

    private struct FrozenNode: Decodable {
        let id: String
        let parentID: String?
        let depth: Int
        let attributes: [String: FrozenAttribute]
    }

    private struct FrozenAttribute: Decodable {
        let status: String
        let value: FrozenValue?
    }

    private struct FrozenValue: Decodable {
        let text: String?
        let components: [String: Double]?
    }

    private struct ImageGeometry: Decodable {
        let pixelWidth: Int
        let pixelHeight: Int
        let capturedBounds: CaptureRect

        func valid(for document: AnnotationDocument) -> Bool {
            pixelWidth == document.imageWidth && pixelHeight == document.imageHeight
                && [capturedBounds.x, capturedBounds.y, capturedBounds.width, capturedBounds.height].allSatisfy(\.isFinite)
                && capturedBounds.width > 0 && capturedBounds.height > 0
        }

        func project(_ components: [String: Double]?) -> CaptureRect? {
            guard let components, let x = components["x"], let y = components["y"],
                  let width = components["width"], let height = components["height"],
                  [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
            let scaleX = Double(pixelWidth) / capturedBounds.width
            let scaleY = Double(pixelHeight) / capturedBounds.height
            let left = (x - capturedBounds.x) * scaleX
            let top = (y - capturedBounds.y) * scaleY
            let right = (x + width - capturedBounds.x) * scaleX
            let bottom = (y + height - capturedBounds.y) * scaleY
            guard [left, top, right, bottom].allSatisfy(\.isFinite) else { return nil }
            let clippedLeft = max(0, left), clippedTop = max(0, top)
            let clippedRight = min(Double(pixelWidth), right), clippedBottom = min(Double(pixelHeight), bottom)
            guard clippedRight > clippedLeft, clippedBottom > clippedTop else { return nil }
            return CaptureRect(x: clippedLeft, y: clippedTop,
                width: clippedRight - clippedLeft, height: clippedBottom - clippedTop)
        }
    }
}
