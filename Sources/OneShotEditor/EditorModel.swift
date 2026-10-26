import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OneShotCore

@MainActor
final class EditorModel: ObservableObject {
    @Published var project: AnnotationProject?
    @Published var image: NSImage?
    @Published var selectedID: UUID?
    @Published var tool: EditorTool = .select
    @Published var zoom: Double = 1
    @Published var colorHex = "#E5484D"
    @Published var strokeWidth: Double = 6
    @Published var status = "打开一份采集，开始标注。"
    @Published var elementIndex: CapturedElementIndex?
    @Published var highlightedElementID: String?
    @Published var inspectorMode = "annotations"
    @Published var elementSearch = ""
    @Published var expandedElements: Set<String> = []
    @Published private(set) var undoHistory: [[AnnotationItem]] = []
    @Published private(set) var redoHistory: [[AnnotationItem]] = []
    @Published private(set) var recentCaptures: [RecentCapture] = []
    @Published private(set) var recentError: String?
    @Published private(set) var isExportingHandoff = false
    @Published private(set) var handoff: AgentHandoffExport?
    @Published var handoffPresented = false
    private let recentStore: RecentCapturesStore
    private var savedItems: [AnnotationItem] = []
    private var editGroup: String?
    weak var window: NSWindow?

    init(arguments: [String] = CommandLine.arguments) {
        if let flag = arguments.firstIndex(of: "--recent-index"), arguments.indices.contains(flag + 1),
           arguments[flag + 1].hasPrefix("/") {
            recentStore = RecentCapturesStore(fileURL: URL(fileURLWithPath: arguments[flag + 1]))
        } else {
            recentStore = RecentCapturesStore()
        }
        refreshRecents()
    }

    var document: AnnotationDocument? { project?.document }
    var selected: AnnotationItem? { document?.items.first { $0.id == selectedID } }
    var isDirty: Bool { (document?.items ?? []) != savedItems }
    var title: String { project?.projectDirectory?.deletingPathExtension().lastPathComponent ?? project?.captureDirectory.lastPathComponent ?? "OneShot" }

    func select(_ id: UUID?) {
        selectedID = id; editGroup = nil
        highlightedElementID = selected?.kind == .element ? selected?.targetNodeID : nil
    }

    func highlightElement(_ id: String) {
        selectedID = document?.items.first { $0.kind == .element && $0.targetNodeID == id }?.id
        highlightedElementID = id; editGroup = nil
    }

    func changeItems(_ items: [AnnotationItem], group: String? = nil) {
        guard var current = project, items != current.document.items else { return }
        var next = current.document
        next.items = items
        do { try next.validate() } catch { show(error); return }
        if group == nil || group != editGroup {
            undoHistory.append(current.document.items)
            if undoHistory.count > 100 { undoHistory.removeFirst() }
        }
        editGroup = group
        redoHistory.removeAll()
        current.document = next
        project = current
        if let selectedID, !items.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        status = "\(items.count) 个标注 · 尚未保存"
        updateWindow()
    }

    func updateSelected(_ mutate: (inout AnnotationItem) -> Void, group: String? = nil) {
        guard var items = document?.items, let index = items.firstIndex(where: { $0.id == selectedID }) else { return }
        mutate(&items[index])
        if let document, items[index].kind == .text || items[index].kind == .number {
            let size = CGSize(width: document.imageWidth, height: document.imageHeight)
            let bounds = AnnotationRenderer.bounds(for: items[index], imageSize: size)
            if bounds.width > size.width || bounds.height > size.height {
                status = "文字超出图片范围，请减少内容或使用更细的样式。"; return
            }
            let dx = min(size.width - bounds.maxX, max(0, -bounds.minX))
            let dy = min(size.height - bounds.maxY, max(0, -bounds.minY))
            for key in [\AnnotationItem.start, \AnnotationItem.end] {
                items[index][keyPath: key].x = min(size.width, max(0, items[index][keyPath: key].x + dx))
                items[index][keyPath: key].y = min(size.height, max(0, items[index][keyPath: key].y + dy))
            }
        }
        changeItems(items, group: group)
    }

    func setColor(_ hex: String) { colorHex = hex; updateSelected { $0.colorHex = hex } }
    func setWidth(_ width: Double) { strokeWidth = width; updateSelected { $0.strokeWidth = width } }
    func deleteSelected() {
        guard let selectedID, let items = document?.items else { return }
        changeItems(items.filter { $0.id != selectedID })
    }
    func undo() {
        guard var current = project, let items = undoHistory.popLast() else { return }
        redoHistory.append(current.document.items); current.document.items = items; project = current
        selectedID = nil; editGroup = nil; updateWindow(); status = "已撤销"
    }
    func redo() {
        guard var current = project, let items = redoHistory.popLast() else { return }
        undoHistory.append(current.document.items); current.document.items = items; project = current
        selectedID = nil; editGroup = nil; updateWindow(); status = "已重做"
    }

    func openPanel() {
        guard confirmUnsaved() else { return }
        let panel = NSOpenPanel()
        panel.title = "打开采集或标注项目"
        panel.message = "选择包含 manifest.json 的采集文件夹，或 .oneshot 标注项目。"
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    @discardableResult func open(_ url: URL) -> Bool {
        do {
            let loaded = url.pathExtension.lowercased() == "oneshot"
                ? try AnnotationStore.openProject(at: url) : try AnnotationStore.openCapture(at: url)
            guard let loadedImage = NSImage(contentsOf: loaded.imageURL) else {
                throw NSError(domain: "OneShot", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取这份截图。"])
            }
            project = loaded; image = loadedImage; savedItems = loaded.document.items
            undoHistory = []; redoHistory = []; selectedID = nil; editGroup = nil; tool = .select; zoom = 1
            highlightedElementID = nil; elementSearch = ""; inspectorMode = "annotations"
            do { elementIndex = try CapturedElementIndex.load(from: loaded) }
            catch { elementIndex = CapturedElementIndex(elements: [], status: "无法读取控件树：\(error.localizedDescription)") }
            expandedElements = Set(elementIndex?.elements.filter { $0.depth < 3 }.map(\.id) ?? [])
            status = "\(loaded.document.imageWidth) × \(loaded.document.imageHeight) · 截图与原始上下文已载入"
            remember(loaded)
            updateWindow()
            return true
        } catch { show(error); return false }
    }

    @discardableResult func save(asNew: Bool = false) -> Bool {
        guard let current = project else { return false }
        do {
            if !asNew, let destination = current.projectDirectory {
                try AnnotationStore.save(document: current.document, in: destination)
            } else {
                let panel = NSSavePanel()
                panel.title = "保存可继续编辑的项目"
                panel.message = "项目包含原始截图、完整采集上下文和独立标注层。"
                panel.nameFieldStringValue = title + ".oneshot"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let chosen = panel.url else { return false }
                let destination = chosen.pathExtension.lowercased() == "oneshot" ? chosen : chosen.appendingPathExtension("oneshot")
                project = try AnnotationStore.createProject(from: current, document: current.document, at: destination)
            }
            savedItems = current.document.items; editGroup = nil; status = "已保存 \(project?.projectDirectory?.lastPathComponent ?? title)"
            if let project { remember(project) }
            updateWindow(); return true
        } catch { show(error); return false }
    }

    func exportPNG() {
        guard let current = project else { return }
        let panel = NSSavePanel()
        panel.title = "导出标注图片"
        panel.nameFieldStringValue = title + "-annotated.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let protected = [current.captureDirectory, current.projectDirectory].compactMap { $0?.resolvingSymlinksInPath().standardizedFileURL.path }
        guard !protected.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) else {
            show(NSError(domain: "OneShot", code: 1, userInfo: [NSLocalizedDescriptionKey: "请把导出图片保存在原始采集和标注项目之外。"])); return
        }
        do {
            try AnnotationRenderer.exportPNG(imageURL: current.imageURL, document: current.document, to: destination)
            status = "已导出 \(destination.lastPathComponent)"
        } catch { show(error) }
    }

    func exportForAgent() {
        guard project != nil, !isExportingHandoff else { return }
        // Commit an in-progress native text edit before taking the immutable export snapshot.
        window?.makeFirstResponder(nil)
        guard let current = project else { return }
        let panel = NSSavePanel()
        panel.title = "交给 Agent"
        panel.message = "导出当前截图、\(current.document.items.count) 条标注及完整上下文，并复制给 Agent 的说明。包含当前未保存的标注。"
        panel.nameFieldStringValue = title + "-agent"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingHandoff = true
        status = "正在整理截图、标注和完整上下文…"
        Task {
            do {
                let exported = try await Task.detached(priority: .userInitiated) {
                    try AgentHandoffStore.export(project: current, to: destination)
                }.value
                isExportingHandoff = false
                handoff = exported
                copyHandoffPrompt()
                handoffPresented = true
            } catch {
                isExportingHandoff = false
                show(error)
            }
        }
    }

    func copyHandoffPrompt() {
        guard let handoff else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(handoff.prompt, forType: .string) {
            status = "Agent 材料已导出，说明已复制。粘贴给可读取本地文件的 Agent 即可。"
        } else {
            status = "材料已导出，复制失败；可在交付窗口选择并复制说明。"
        }
    }

    func refreshRecents() {
        do { recentCaptures = try recentStore.load(); recentError = nil }
        catch { recentError = error.localizedDescription }
    }

    @discardableResult func remember(_ directory: URL) -> Bool {
        do { recentCaptures = try recentStore.record(directory: directory); recentError = nil; return true }
        catch { recentError = error.localizedDescription; return false }
    }

    @discardableResult func remember(_ project: AnnotationProject) -> Bool {
        do { recentCaptures = try recentStore.record(project: project); recentError = nil; return true }
        catch { recentError = error.localizedDescription; return false }
    }

    func openRecent(_ capture: RecentCapture) {
        guard confirmUnsaved() else { return }
        open(capture.directory)
    }

    func removeRecent(_ capture: RecentCapture) {
        do { recentCaptures = try recentStore.remove(id: capture.id); recentError = nil }
        catch { recentError = error.localizedDescription }
    }

    func confirmUnsaved() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存对“\(title)”的标注修改？"
        alert.informativeText = "原始采集已保存。尚未保存的标注修改可以保存为可继续编辑的项目。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func updateWindow() { window?.title = "\(title) — OneShot"; window?.isDocumentEdited = isDirty }

    func annotateElement(_ id: String) {
        guard let element = elementIndex?.element(id: id), var items = document?.items else { return }
        highlightedElementID = id; inspectorMode = "annotations"
        if let existing = items.first(where: { $0.kind == .element && $0.targetNodeID == id }) {
            select(existing.id); return
        }
        let frame = element.imageBounds
        let item = AnnotationItem(kind: .element,
            start: .init(x: frame?.x ?? 0, y: frame?.y ?? 0),
            end: .init(x: (frame?.x ?? 0) + (frame?.width ?? 0), y: (frame?.y ?? 0) + (frame?.height ?? 0)),
            colorHex: colorHex, strokeWidth: strokeWidth,
            number: min(9999, (items.filter { $0.kind == .number || $0.kind == .element }.map(\.number).max() ?? 0) + 1), targetNodeID: id)
        items.append(item); changeItems(items); select(item.id)
        status = frame == nil ? "已绑定控件；该节点不在截图可定位区域，可在右侧添加说明。" : "已绑定控件，在右侧添加说明。"
    }

    var visibleElements: [CapturedElement] {
        guard let elements = elementIndex?.elements else { return [] }
        let query = elementSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return elements.filter { ($0.label + " " + $0.role + " " + $0.id).localizedCaseInsensitiveContains(query) }
        }
        let ids = Set(elements.map(\.id))
        let children = Dictionary(grouping: elements.filter { $0.parentID != nil }, by: { $0.parentID! })
        var result: [CapturedElement] = []
        var visited = Set<String>()
        func append(_ element: CapturedElement) {
            guard visited.insert(element.id).inserted else { return }
            result.append(element)
            if expandedElements.contains(element.id) { for child in children[element.id] ?? [] { append(child) } }
        }
        for root in elements where root.parentID == nil || !ids.contains(root.parentID!) { append(root) }
        return result
    }

    func show(_ error: Error) {
        status = error.localizedDescription
        let alert = NSAlert(); alert.messageText = "无法完成操作"; alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好"); alert.runModal()
    }
}
