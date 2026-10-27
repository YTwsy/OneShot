import Foundation

public enum AnnotationKind: String, Codable, CaseIterable {
    case number, arrow, rectangle, text, element
}

/// Coordinates are original image pixels with a top-left origin, independent of display zoom.
public struct AnnotationPoint: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

public struct AnnotationItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var kind: AnnotationKind
    public var start: AnnotationPoint
    public var end: AnnotationPoint
    public var text: String
    public var colorHex: String
    public var strokeWidth: Double
    public var number: Int
    /// A node in this document's frozen source capture, never a live application handle.
    public var targetNodeID: String?

    public init(id: UUID = UUID(), kind: AnnotationKind,
                start: AnnotationPoint = .init(), end: AnnotationPoint = .init(),
                text: String = "", colorHex: String = "#EF4444", strokeWidth: Double = 4,
                number: Int = 1, targetNodeID: String? = nil) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
        self.colorHex = colorHex
        self.strokeWidth = strokeWidth
        self.number = number
        self.targetNodeID = targetNodeID
    }
}

public enum AnnotationError: LocalizedError {
    case invalidDocument(String)
    case invalidCapture(String)
    case invalidProject(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDocument(let detail): return "无法使用这份标注：\(detail)"
        case .invalidCapture(let detail): return "无法打开采集结果：\(detail)"
        case .invalidProject(let detail): return "无法保存或打开标注项目：\(detail)"
        }
    }
}

/// The editable layer. Original screenshot, AX, OCR and context stay in the frozen capture.
public struct AnnotationDocument: Codable, Equatable {
    public var schemaVersion: Int
    public var id: UUID
    public var sourceCaptureID: String
    public var imageWidth: Int
    public var imageHeight: Int
    public var items: [AnnotationItem]
    public var feedbacks: [FeedbackItem]

    public init(schemaVersion: Int = 1, id: UUID = UUID(), sourceCaptureID: String,
                imageWidth: Int, imageHeight: Int, items: [AnnotationItem] = [], feedbacks: [FeedbackItem] = []) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sourceCaptureID = sourceCaptureID
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.items = items
        self.feedbacks = feedbacks
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, sourceCaptureID, imageWidth, imageHeight, items, feedbacks
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(UUID.self, forKey: .id)
        sourceCaptureID = try values.decode(String.self, forKey: .sourceCaptureID)
        imageWidth = try values.decode(Int.self, forKey: .imageWidth)
        imageHeight = try values.decode(Int.self, forKey: .imageHeight)
        items = try values.decode([AnnotationItem].self, forKey: .items)
        feedbacks = try values.decodeIfPresent([FeedbackItem].self, forKey: .feedbacks) ?? []
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw AnnotationError.invalidDocument("不支持版本 \(schemaVersion)。")
        }
        guard !sourceCaptureID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceCaptureID.utf8.count <= 512 else {
            throw AnnotationError.invalidDocument("缺少有效的采集标识。")
        }
        guard imageWidth > 0, imageHeight > 0,
              imageWidth <= 32_768, imageHeight <= 32_768,
              imageWidth * imageHeight <= 100_000_000 else {
            throw AnnotationError.invalidDocument("图片尺寸无效或超过支持范围。")
        }
        guard items.count <= 2_000 else {
            throw AnnotationError.invalidDocument("标注数量超过 2000。")
        }
        var ids = Set<UUID>()
        var totalText = 0
        for item in items {
            guard ids.insert(item.id).inserted else {
                throw AnnotationError.invalidDocument("标注标识重复。")
            }
            if let target = item.targetNodeID {
                guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      target.utf8.count <= 256 else {
                    throw AnnotationError.invalidDocument("元素标注缺少有效的节点标识。")
                }
            }
            if item.kind == .element, item.targetNodeID == nil {
                throw AnnotationError.invalidDocument("元素标注必须绑定采集中的节点。")
            }
            for point in [item.start, item.end] {
                guard point.x.isFinite, point.y.isFinite,
                      (0...Double(imageWidth)).contains(point.x),
                      (0...Double(imageHeight)).contains(point.y) else {
                    throw AnnotationError.invalidDocument("标注坐标超出图片或包含无效数值。")
                }
            }
            let color = Array(item.colorHex.utf8)
            guard color.count == 7, color.first == 35,
                  color.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw AnnotationError.invalidDocument("颜色须使用 #RRGGBB 格式。")
            }
            guard item.strokeWidth.isFinite, (1...64).contains(item.strokeWidth),
                  (1...9_999).contains(item.number) else {
                throw AnnotationError.invalidDocument("线宽或编号超出支持范围。")
            }
            guard item.text.count <= 16_384 else {
                throw AnnotationError.invalidDocument("单条说明文字过长。")
            }
            totalText += item.text.utf8.count
            guard totalText <= 1_048_576 else {
                throw AnnotationError.invalidDocument("说明文字总量超过支持范围。")
            }
        }
        guard feedbacks.count <= 2_000 else {
            throw AnnotationError.invalidDocument("反馈数量超过 2000。")
        }
        var segmentCount = 0
        for feedback in feedbacks {
            guard ids.insert(feedback.id).inserted else {
                throw AnnotationError.invalidDocument("反馈标识重复。")
            }
            segmentCount += feedback.content.count
            guard feedback.content.count <= 2_000, segmentCount <= 20_000 else {
                throw AnnotationError.invalidDocument("反馈内容片段数量超过支持范围。")
            }
            var feedbackCharacters = 0
            for segment in feedback.content {
                switch segment {
                case .text(let text):
                    feedbackCharacters += text.count
                    totalText += text.utf8.count
                case .control(let reference):
                    guard ids.insert(reference.id).inserted else {
                        throw AnnotationError.invalidDocument("控件引用标识重复。")
                    }
                    guard !reference.nodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          reference.nodeID.utf8.count <= 256,
                          !reference.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          reference.label.count <= 512 else {
                        throw AnnotationError.invalidDocument("控件引用缺少有效节点标识或名称。")
                    }
                    feedbackCharacters += reference.label.count
                    totalText += reference.label.utf8.count
                }
                guard feedbackCharacters <= 16_384, totalText <= 1_048_576 else {
                    throw AnnotationError.invalidDocument("反馈说明文字超过支持范围。")
                }
            }
        }
    }
}
