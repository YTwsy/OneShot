import Darwin
import Foundation
import ImageIO

public struct AnnotationProject {
    public var document: AnnotationDocument
    public let captureDirectory: URL
    public let imageURL: URL
    public let projectDirectory: URL?

    public init(document: AnnotationDocument, captureDirectory: URL, imageURL: URL,
                projectDirectory: URL? = nil) {
        self.document = document
        self.captureDirectory = captureDirectory
        self.imageURL = imageURL
        self.projectDirectory = projectDirectory
    }
}

/// Local editing never rereads the target application. Projects carry their own frozen capture.
public enum AnnotationStore {
    private static let maximumProjectBytes = 512 * 1_024 * 1_024
    private static let maximumDocumentBytes = 4 * 1_024 * 1_024

    public static func openCapture(at directory: URL) throws -> AnnotationProject {
        let directory = directory.standardizedFileURL
        try requireDirectory(directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SnapshotManifest.self,
            from: readRegular(directory.appendingPathComponent("manifest.json"), maximum: 1_048_576))
        guard manifest.schemaVersion == 1, manifest.screenshot.status == "captured",
              let file = manifest.screenshot.file, safeFileName(file) else {
            throw AnnotationError.invalidCapture("需要含有截图的有效采集目录。")
        }
        let imageURL = directory.appendingPathComponent(file)
        let data = try readRegular(imageURL, maximum: maximumProjectBytes)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw AnnotationError.invalidCapture("截图文件无法读取。")
        }
        let document = AnnotationDocument(sourceCaptureID: manifest.captureID,
            imageWidth: width.intValue, imageHeight: height.intValue)
        try document.validate()
        return AnnotationProject(document: document, captureDirectory: directory, imageURL: imageURL)
    }

    public static func openProject(at directory: URL) throws -> AnnotationProject {
        let directory = directory.standardizedFileURL
        try requireDirectory(directory)
        let document = try JSONDecoder().decode(AnnotationDocument.self,
            from: readRegular(directory.appendingPathComponent("annotations.json"), maximum: maximumDocumentBytes))
        try document.validate()
        let capture = try openCapture(at: directory.appendingPathComponent("capture", isDirectory: true))
        try requireBinding(document, capture.document)
        try requireElementBindings(document, capture: capture)
        return AnnotationProject(document: document, captureDirectory: capture.captureDirectory,
                                 imageURL: capture.imageURL, projectDirectory: directory)
    }

    public static func createProject(from source: AnnotationProject, document: AnnotationDocument,
                                     at destination: URL) throws -> AnnotationProject {
        try document.validate()
        // Recheck the files, rather than trusting an in-memory project supplied by the caller.
        let capture = try openCapture(at: source.captureDirectory)
        try requireBinding(document, capture.document)
        try requireElementBindings(document, capture: capture)
        let destination = destination.standardizedFileURL
        let sourcePath = capture.captureDirectory.resolvingSymlinksInPath().path
        let destinationPath = destination.resolvingSymlinksInPath().path
        guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else {
            throw AnnotationError.invalidProject("标注项目须保存在原始采集目录之外。")
        }
        try requireDirectory(destination.deletingLastPathComponent())
        guard mkdir(destination.path, S_IRWXU) == 0 else {
            throw AnnotationError.invalidProject("目标已存在或无法创建；请选择新的项目名称。")
        }
        do {
            let frozen = destination.appendingPathComponent("capture", isDirectory: true)
            var files = 0
            var bytes = 0
            try copyDirectory(capture.captureDirectory, to: frozen, depth: 0, files: &files, bytes: &bytes)
            let copied = try openCapture(at: frozen)
            try requireBinding(document, copied.document)
            try requireElementBindings(document, capture: copied)
            try writeDocument(document, in: destination)
            return try openProject(at: destination)
        } catch {
            // Only this call's newly reserved directory is removed on an unsuccessful creation.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    public static func save(document: AnnotationDocument, in directory: URL) throws {
        try document.validate()
        let current = try openProject(at: directory)
        try requireBinding(document, current.document)
        try requireElementBindings(document, capture: current)
        guard document.id == current.document.id else {
            throw AnnotationError.invalidProject("标注身份不同，请另存为新项目。")
        }
        try writeDocument(document, in: directory)
    }

    private static func requireBinding(_ document: AnnotationDocument, _ source: AnnotationDocument) throws {
        guard document.sourceCaptureID == source.sourceCaptureID,
              document.imageWidth == source.imageWidth, document.imageHeight == source.imageHeight else {
            throw AnnotationError.invalidProject("标注的采集标识或图片尺寸与原始快照不一致。")
        }
    }

    private static func requireElementBindings(_ document: AnnotationDocument, capture: AnnotationProject) throws {
        let targets = document.items.compactMap(\.targetNodeID)
        guard !targets.isEmpty else { return }
        let index = try CapturedElementIndex.load(from: capture)
        let elements = Dictionary(uniqueKeysWithValues: index.elements.map { ($0.id, $0) })
        guard targets.allSatisfy({ elements[$0] != nil }) else {
            throw AnnotationError.invalidProject("元素标注引用了此采集中不存在的 AX 节点。")
        }
        for item in document.items where item.kind == .element {
            let bounds = elements[item.targetNodeID!]?.imageBounds
            let x: Double = bounds?.x ?? 0
            let y: Double = bounds?.y ?? 0
            let width: Double = bounds?.width ?? 0
            let height: Double = bounds?.height ?? 0
            let expected: [Double] = [x, y, x + width, y + height]
            let actual: [Double] = [item.start.x, item.start.y, item.end.x, item.end.y]
            guard zip(actual, expected).allSatisfy({ pair in abs(pair.0 - pair.1) <= 0.01 }) else {
                throw AnnotationError.invalidProject("元素标注的位置与冻结快照中的节点不一致。")
            }
        }
    }

    private static func safeFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private static func requireDirectory(_ directory: URL) throws {
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else {
            throw AnnotationError.invalidProject("目录无效或为符号链接。")
        }
    }

    static func readRegular(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError("无法读取 \(url.lastPathComponent)。") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maximum) else {
            throw AnnotationError.invalidProject("文件不是常规文件或超过支持大小。")
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("读取文件失败。")
            }
            guard result.count <= maximum - count else {
                throw AnnotationError.invalidProject("文件在读取时超过支持大小。")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private static func copyDirectory(_ source: URL, to destination: URL, depth: Int,
                                      files: inout Int, bytes: inout Int) throws {
        guard depth <= 16 else { throw AnnotationError.invalidProject("采集目录层级过深。") }
        try requireDirectory(source)
        guard mkdir(destination.path, S_IRWXU) == 0 else { throw posixError("无法创建快照副本目录。") }
        for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            files += 1
            guard files <= 4_096 else { throw AnnotationError.invalidProject("采集目录包含过多文件。") }
            let properties = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else {
                throw AnnotationError.invalidProject("采集目录包含符号链接，未复制。")
            }
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if properties.isDirectory == true {
                try copyDirectory(child, to: target, depth: depth + 1, files: &files, bytes: &bytes)
            } else {
                let data = try readRegular(child, maximum: maximumProjectBytes - bytes)
                bytes += data.count
                try writePrivate(data, to: target)
            }
        }
    }

    private static func writeDocument(_ document: AnnotationDocument, in directory: URL) throws {
        let data = try SnapshotStore.encoder.encode(document)
        guard data.count <= maximumDocumentBytes else {
            throw AnnotationError.invalidDocument("标注文件超过支持大小。")
        }
        let temporary = directory.appendingPathComponent(".annotations-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writePrivate(data, to: temporary)
        guard Darwin.rename(temporary.path, directory.appendingPathComponent("annotations.json").path) == 0 else {
            throw posixError("保存标注失败；原有标注已保留。")
        }
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError("无法创建私有项目文件。") }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError("写入项目文件失败。") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError("同步项目文件失败。") }
    }

    private static func posixError(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
