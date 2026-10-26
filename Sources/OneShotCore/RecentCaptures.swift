import Darwin
import Foundation
import ImageIO

/// A local pointer to a frozen capture or an editable project. Moving a project does not move this pointer.
public struct RecentCapture: Identifiable, Codable, Equatable {
    public let directory: URL
    public let captureID: String
    public let applicationName: String
    public let windowTitle: String
    public let capturedAt: Date
    public let lastOpenedAt: Date
    public let isProject: Bool
    public let annotationCount: Int

    public var id: String { directory.standardizedFileURL.path }
    public var title: String { windowTitle.isEmpty ? applicationName : "\(applicationName) · \(windowTitle)" }

    /// A missing or moved entry stays in the list; only opening it attempts to read its content.
    public var isAvailable: Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}

public enum RecentCapturesError: LocalizedError {
    case invalidIndex
    case unavailableDirectory
    case cannotSave

    public var errorDescription: String? {
        switch self {
        case .invalidIndex: return "最近采集记录无法读取，原有记录已保留。"
        case .unavailableDirectory: return "最近采集记录目录无效或为符号链接。"
        case .cannotSave: return "无法保存最近采集记录，原有记录已保留。"
        }
    }
}

/// A bounded, private index. It never copies captures, refreshes a snapshot or deletes user material.
public struct RecentCapturesStore {
    public let fileURL: URL
    public let limit: Int
    private static let maximumBytes = 1_048_576

    public init(fileURL: URL = Self.defaultFileURL, limit: Int = 30) {
        self.fileURL = fileURL.standardizedFileURL
        self.limit = min(100, max(1, limit))
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OneShot/recent-captures.json")
    }

    public func load() throws -> [RecentCapture] {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else { throw RecentCapturesError.invalidIndex }
        var parentInfo = stat()
        if lstat(fileURL.deletingLastPathComponent().path, &parentInfo) == 0 {
            guard parentInfo.st_mode & S_IFMT == S_IFDIR else { throw RecentCapturesError.unavailableDirectory }
        } else if errno != ENOENT { throw RecentCapturesError.unavailableDirectory }
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            if errno == ENOENT { return [] }
            throw RecentCapturesError.invalidIndex
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw RecentCapturesError.invalidIndex }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(Index.self,
                from: AnnotationStore.readRegular(fileURL, maximum: Self.maximumBytes))
            guard index.schemaVersion == 1, index.entries.count <= 100 else { throw RecentCapturesError.invalidIndex }
            var ids = Set<String>()
            for entry in index.entries {
                guard valid(entry), ids.insert(entry.id).inserted else { throw RecentCapturesError.invalidIndex }
            }
            return Array(index.entries.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(limit))
        } catch { throw RecentCapturesError.invalidIndex }
    }

    /// Call after a capture finishes, an item is opened, or an editable project is saved.
    /// An unreadable existing index is never silently replaced with a new empty one.
    @discardableResult
    public func record(directory: URL, at date: Date = Date()) throws -> [RecentCapture] {
        let project = directory.pathExtension.lowercased() == "oneshot"
            ? try AnnotationStore.openProject(at: directory) : try AnnotationStore.openCapture(at: directory)
        return try record(project: project, at: date)
    }

    /// Reuse a project already opened by AnnotationStore. This reads the manifest and image
    /// header for identity checks without rereading PNG bytes or parsing its AX tree again.
    @discardableResult
    public func record(project: AnnotationProject, at date: Date = Date()) throws -> [RecentCapture] {
        var entries = try load()
        guard date.timeIntervalSince1970.isFinite else { throw RecentCapturesError.invalidIndex }
        try project.document.validate()
        let directory = project.projectDirectory ?? project.captureDirectory
        for folder in [directory, project.captureDirectory] {
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw RecentCapturesError.unavailableDirectory
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SnapshotManifest.self,
            from: AnnotationStore.readRegular(project.captureDirectory.appendingPathComponent("manifest.json"), maximum: Self.maximumBytes))
        guard manifest.schemaVersion == 1, manifest.captureID == project.document.sourceCaptureID,
              manifest.screenshot.status == "captured", let file = manifest.screenshot.file,
              !file.isEmpty, file != ".", file != "..", !file.contains("/"), !file.contains("\\"), !file.contains("\0"),
              project.imageURL.standardizedFileURL == project.captureDirectory.appendingPathComponent(file).standardizedFileURL else {
            throw RecentCapturesError.invalidIndex
        }
        var imageInfo = stat()
        guard lstat(project.imageURL.path, &imageInfo) == 0, imageInfo.st_mode & S_IFMT == S_IFREG,
              let image = CGImageSourceCreateWithURL(project.imageURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == project.document.imageWidth,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == project.document.imageHeight else {
            throw RecentCapturesError.invalidIndex
        }
        let entry = RecentCapture(directory: directory.resolvingSymlinksInPath().standardizedFileURL,
            captureID: manifest.captureID, applicationName: manifest.window.ownerName,
            windowTitle: manifest.window.title, capturedAt: manifest.startedAt,
            lastOpenedAt: date, isProject: project.projectDirectory != nil,
            annotationCount: project.document.items.count)
        guard valid(entry) else { throw RecentCapturesError.invalidIndex }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(limit))
        try save(entries)
        return entries
    }

    /// Removes a pointer only; the capture or project on disk is never changed.
    @discardableResult
    public func remove(id: String) throws -> [RecentCapture] {
        let entries = try load().filter { $0.id != id }
        try save(entries)
        return entries
    }

    private func valid(_ entry: RecentCapture) -> Bool {
        entry.directory.isFileURL && entry.directory.path.hasPrefix("/")
            && entry.directory.path.utf8.count <= 16_384
            && !entry.captureID.isEmpty && entry.captureID.utf8.count <= 512
            && entry.applicationName.utf8.count <= 16_384 && entry.windowTitle.utf8.count <= 65_536
            && entry.capturedAt.timeIntervalSince1970.isFinite && entry.lastOpenedAt.timeIntervalSince1970.isFinite
            && (0...2_000).contains(entry.annotationCount)
    }

    private func save(_ entries: [RecentCapture]) throws {
        let data = try SnapshotStore.encoder.encode(Index(schemaVersion: 1, entries: entries))
        guard data.count <= Self.maximumBytes else { throw RecentCapturesError.cannotSave }
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR else {
            throw RecentCapturesError.unavailableDirectory
        }
        let temporary = parent.appendingPathComponent(".recent-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RecentCapturesError.cannotSave }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw RecentCapturesError.cannotSave }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw RecentCapturesError.cannotSave }
        var info = stat()
        if lstat(fileURL.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw RecentCapturesError.invalidIndex }
        } else if errno != ENOENT { throw RecentCapturesError.cannotSave }
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw RecentCapturesError.cannotSave }
    }

    private struct Index: Codable {
        let schemaVersion: Int
        let entries: [RecentCapture]
    }
}
