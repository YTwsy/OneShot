import Foundation

/// An occurrence of a control in a feedback sentence. The node belongs to the
/// document's frozen source capture; the UUID identifies this occurrence only.
public struct FeedbackControlReference: Identifiable, Codable, Equatable {
    public var id: UUID
    public var nodeID: String
    public var label: String

    public init(id: UUID = UUID(), nodeID: String, label: String) {
        self.id = id
        self.nodeID = nodeID
        self.label = label
    }
}

/// Ordered text and semantic references, independent of any rendered label or badge.
public enum FeedbackSegment: Codable, Equatable {
    case text(String)
    case control(FeedbackControlReference)

    private enum CodingKeys: String, CodingKey { case kind, text, reference }
    private enum Kind: String, Codable { case text, control }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .text: self = .text(try values.decode(String.self, forKey: .text))
        case .control: self = .control(try values.decode(FeedbackControlReference.self, forKey: .reference))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try values.encode(Kind.text, forKey: .kind)
            try values.encode(text, forKey: .text)
        case .control(let reference):
            try values.encode(Kind.control, forKey: .kind)
            try values.encode(reference, forKey: .reference)
        }
    }
}

public struct FeedbackItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var content: [FeedbackSegment]

    public init(id: UUID = UUID(), content: [FeedbackSegment] = []) {
        self.id = id
        self.content = content
    }

    public var controlReferences: [FeedbackControlReference] {
        content.compactMap { segment in
            if case .control(let reference) = segment { return reference }
            return nil
        }
    }

    public var plainText: String {
        content.map { segment in
            switch segment {
            case .text(let text): return text
            case .control(let reference): return "[\(reference.label)]"
            }
        }.joined()
    }
}

extension AnnotationDocument {
    /// The first occurrence of each node, in document order. Badge numbering is
    /// presentation only: persisted links always use the frozen node identifier.
    public var feedbackControlReferences: [FeedbackControlReference] {
        var seen = Set<String>()
        return feedbacks.flatMap(\.controlReferences).filter { seen.insert($0.nodeID).inserted }
    }

    public func feedbackReferenceNumber(for nodeID: String) -> Int? {
        feedbackControlReferences.firstIndex(where: { $0.nodeID == nodeID }).map { $0 + 1 }
    }
}
