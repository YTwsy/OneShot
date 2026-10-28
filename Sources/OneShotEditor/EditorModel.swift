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
    @Published var inspectorMode = "feedback"
    @Published var selectedFeedbackID: UUID?
    @Published var isPickingReference = false
    @Published var referenceSearchQuery: String?
    @Published var referenceSearchSelection = 0
    private var searchReplacesMention = false
    let feedbackEditor = FeedbackEditorBridge()
    @Published var elementSearch = ""
    @Published var expandedElements: Set<String> = []
    @Published private(set) var undoHistory: [AnnotationDocument] = []
    @Published private(set) var redoHistory: [AnnotationDocument] = []
    @Published private(set) var recentCaptures: [RecentCapture] = []
    @Published private(set) var recentError: String?
    @Published private(set) var isExportingHandoff = false
    @Published private(set) var handoff: AgentHandoffExport?
    @Published var handoffPresented = false
    @Published private(set) var publishedHandoff: PublishedHandoff?
    @Published private(set) var publishedHistory: [PublishedHandoff] = []
    @Published var agentConnectionPresented = false
    @Published var agentConnectionMessage = "首次选择客户端并连接，以后交付不需要更改配置。"
    @Published private(set) var isCheckingAgentConnection = false
    @Published private(set) var harnessStatuses: [AgentHarness: HarnessConnectionStatus] = [:]
    @Published private(set) var isManagingHarness = false
    let handoffLibrary: HandoffLibrary
    private let recentStore: RecentCapturesStore
    private var savedDocument: AnnotationDocument?
    private var editGroup: String?
    weak var window: NSWindow?

    init(arguments: [String] = CommandLine.arguments) {
        if let flag = arguments.firstIndex(of: "--handoff-library"), arguments.indices.contains(flag + 1),
           arguments[flag + 1].hasPrefix("/") {
            handoffLibrary = HandoffLibrary(directory: URL(fileURLWithPath: arguments[flag + 1], isDirectory: true))
        } else { handoffLibrary = HandoffLibrary() }
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
    var selectedFeedback: FeedbackItem? { document?.feedbacks.first { $0.id == selectedFeedbackID } }
    var isDirty: Bool { document != savedDocument }
    var title: String { project?.projectDirectory?.deletingPathExtension().lastPathComponent ?? project?.captureDirectory.lastPathComponent ?? "OneShot" }

    func select(_ id: UUID?) {
        cancelReferencePicking(restoreFocus: false)
        selectedID = id; editGroup = nil
        if id != nil { inspectorMode = "annotations" }
        highlightedElementID = selected?.kind == .element ? selected?.targetNodeID : nil
    }

    func highlightElement(_ id: String) {
        selectedID = document?.items.first { $0.kind == .element && $0.targetNodeID == id }?.id
        highlightedElementID = id; editGroup = nil
    }

    func changeItems(_ items: [AnnotationItem], group: String? = nil) {
        guard let current = project else { return }
        var next = current.document
        next.items = items
        changeDocument(next, group: group)
    }

    private func changeDocument(_ next: AnnotationDocument, group: String? = nil) {
        guard var current = project, next != current.document else { return }
        do { try next.validate() } catch { show(error); return }
        if group == nil || group != editGroup {
            undoHistory.append(current.document)
            if undoHistory.count > 100 { undoHistory.removeFirst() }
        }
        editGroup = group
        redoHistory.removeAll()
        current.document = next
        project = current
        if let selectedID, !next.items.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        if let selectedFeedbackID, !next.feedbacks.contains(where: { $0.id == selectedFeedbackID }) { self.selectedFeedbackID = nil }
        status = "\(next.feedbacks.count) 条反馈 · \(next.items.count) 个标注" + (isDirty ? " · 尚未保存" : " · 无未保存修改")
        updateWindow()
    }

    func writeFeedback() {
        feedbackEditor.commitEditing()
        inspectorMode = "feedback"
        selectedID = nil
        if selectedFeedback == nil {
            if let first = document?.feedbacks.first { selectedFeedbackID = first.id }
            else { addFeedback() }
        }
        feedbackEditor.focus()
    }

    func addFeedback() {
        feedbackEditor.commitEditing()
        guard var next = document, next.feedbacks.count < 2_000 else { return }
        cancelReferencePicking(restoreFocus: false)
        let feedback = FeedbackItem()
        next.feedbacks.append(feedback)
        changeDocument(next)
        selectedFeedbackID = feedback.id
        selectedID = nil
        inspectorMode = "feedback"
        feedbackEditor.focus()
    }

    func selectFeedback(_ id: UUID) {
        feedbackEditor.commitEditing()
        cancelReferencePicking(restoreFocus: false)
        selectedFeedbackID = id; selectedID = nil; editGroup = nil
        inspectorMode = "feedback"
        highlightedElementID = selectedFeedback?.controlReferences.first?.nodeID
    }

    func updateFeedback(_ id: UUID, content: [FeedbackSegment]) {
        guard var next = document, let index = next.feedbacks.firstIndex(where: { $0.id == id }) else { return }
        next.feedbacks[index].content = content
        changeDocument(next, group: "feedback-\(id)")
    }

    func deleteFeedback(_ id: UUID) {
        feedbackEditor.commitEditing()
        guard var next = document else { return }
        cancelReferencePicking(restoreFocus: false)
        next.feedbacks.removeAll { $0.id == id }
        changeDocument(next)
        selectedFeedbackID = next.feedbacks.first?.id
        highlightedElementID = nil
    }

    func beginReferencePicking() {
        if selectedFeedback == nil { writeFeedback() }
        feedbackEditor.prepareForPicking()
        referenceSearchQuery = nil
        isPickingReference = true
        inspectorMode = "feedback"
        status = "点选要引用的控件 · Esc 取消"
    }

    func cancelReferencePicking(restoreFocus: Bool = true) {
        let wasActive = isPickingReference || referenceSearchQuery != nil
        isPickingReference = false
        referenceSearchQuery = nil
        if restoreFocus && wasActive { feedbackEditor.cancelPicking() }
        if wasActive, let document {
            status = "\(document.feedbacks.count) 条反馈 · \(document.items.count) 个标注" + (isDirty ? " · 尚未保存" : "")
        }
    }

    func insertReference(_ nodeID: String, fromSearch: Bool = false) {
        guard selectedFeedback != nil, let element = elementIndex?.element(id: nodeID) else { return }
        let reference = FeedbackControlReference(nodeID: nodeID,
            label: element.label.isEmpty ? friendlyRole(element.role) : String(element.label.prefix(80)))
        let replacesMention = fromSearch && searchReplacesMention
        isPickingReference = false
        referenceSearchQuery = nil
        highlightedElementID = nodeID
        feedbackEditor.insert(reference, replacingMention: replacesMention)
        status = "已引用\(reference.label)，继续输入描述。"
    }

    func mentionChanged(_ query: String?) {
        referenceSearchQuery = query
        referenceSearchSelection = 0
        searchReplacesMention = query != nil
    }

    func beginReferenceSearch() {
        if selectedFeedback == nil { writeFeedback() }
        feedbackEditor.prepareForPicking()
        isPickingReference = false
        referenceSearchQuery = ""
        referenceSearchSelection = 0
        searchReplacesMention = false
    }

    var referenceSearchResults: [CapturedElement] {
        let query = (referenceSearchQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let all = elementIndex?.elements ?? []
        let matches = all.filter { element in
            if query.isEmpty { return !element.label.isEmpty || element.role == "AXButton" }
            return (element.label + " " + friendlyRole(element.role) + " " + element.id).localizedCaseInsensitiveContains(query)
        }
        return Array(matches.prefix(30))
    }

    func moveMentionSelection(_ offset: Int) {
        let count = referenceSearchResults.count
        if count > 0 { referenceSearchSelection = (referenceSearchSelection + offset + count) % count }
    }

    func acceptMentionSelection() -> Bool {
        guard referenceSearchQuery != nil else { return false }
        let results = referenceSearchResults
        guard results.indices.contains(referenceSearchSelection) else { return false }
        insertReference(results[referenceSearchSelection].id, fromSearch: true)
        return true
    }

    func friendlyRole(_ role: String) -> String {
        switch role {
        case "AXButton": return "按钮"
        case "AXTextField", "AXTextArea": return "输入框"
        case "AXStaticText": return "文本"
        case "AXCheckBox": return "复选框"
        case "AXPopUpButton", "AXComboBox": return "下拉选项"
        case "AXImage": return "图像"
        case "AXLink": return "链接"
        case "AXWindow": return "窗口"
        case "AXGroup": return "容器"
        default: return "控件"
        }
    }

    func showFeedbackReference(_ nodeID: String) {
        if selectedFeedback?.controlReferences.contains(where: { $0.nodeID == nodeID }) == true {
            inspectorMode = "feedback"
            highlightedElementID = nodeID
            return
        }
        guard let feedback = document?.feedbacks.first(where: { $0.controlReferences.contains { $0.nodeID == nodeID } }) else { return }
        selectFeedback(feedback.id)
        highlightedElementID = nodeID
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
        guard var current = project, let previous = undoHistory.popLast() else { return }
        cancelReferencePicking(restoreFocus: false)
        redoHistory.append(current.document); current.document = previous; project = current
        if !previous.feedbacks.contains(where: { $0.id == selectedFeedbackID }) { selectedFeedbackID = previous.feedbacks.first?.id }
        selectedID = nil; editGroup = nil; updateWindow(); status = "已撤销"
    }
    func redo() {
        guard var current = project, let next = redoHistory.popLast() else { return }
        cancelReferencePicking(restoreFocus: false)
        undoHistory.append(current.document); current.document = next; project = current
        if !next.feedbacks.contains(where: { $0.id == selectedFeedbackID }) { selectedFeedbackID = next.feedbacks.first?.id }
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
            cancelReferencePicking(restoreFocus: false)
            project = loaded; image = loadedImage; savedDocument = loaded.document
            undoHistory = []; redoHistory = []; selectedID = nil; editGroup = nil; tool = .select; zoom = 1
            highlightedElementID = nil; elementSearch = ""; inspectorMode = "feedback"
            selectedFeedbackID = loaded.document.feedbacks.first?.id
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
        feedbackEditor.commitEditing()
        window?.makeFirstResponder(nil)
        guard let current = project else { return false }
        do {
            if !asNew, let destination = current.projectDirectory {
                try AnnotationStore.save(document: current.document, in: destination)
            } else {
                let panel = NSSavePanel()
                panel.title = "保存可继续编辑的项目"
                panel.message = "项目包含原始截图、完整采集上下文、反馈与控件引用，以及独立标注层。"
                panel.nameFieldStringValue = title + ".oneshot"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let chosen = panel.url else { return false }
                let destination = chosen.pathExtension.lowercased() == "oneshot" ? chosen : chosen.appendingPathExtension("oneshot")
                project = try AnnotationStore.createProject(from: current, document: current.document, at: destination)
            }
            savedDocument = current.document; editGroup = nil; status = "已保存 \(project?.projectDirectory?.lastPathComponent ?? title)"
            if let project { remember(project) }
            updateWindow(); return true
        } catch { show(error); return false }
    }

    func exportPNG() {
        feedbackEditor.commitEditing()
        window?.makeFirstResponder(nil)
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
        feedbackEditor.commitEditing()
        window?.makeFirstResponder(nil)
        guard let current = project else { return }
        let library = handoffLibrary, title = title
        isExportingHandoff = true
        status = "正在准备固定版本的 Agent 材料…"
        Task {
            do {
                let entry = try await Task.detached(priority: .userInitiated) {
                    try library.publish(project: current, title: title)
                }.value
                publishedHandoff = entry; handoff = nil
                isExportingHandoff = false
                copyPublishedPrompt(entry)
                handoffPresented = true
            } catch { isExportingHandoff = false; show(error) }
        }
    }

    func exportAgentFolder() {
        guard project != nil, !isExportingHandoff else { return }
        feedbackEditor.commitEditing()
        // Commit an in-progress native text edit before taking the immutable export snapshot.
        window?.makeFirstResponder(nil)
        guard let current = project else { return }
        let panel = NSSavePanel()
        panel.title = "交给 Agent"
        panel.message = "导出当前截图、\(current.document.feedbacks.count) 条反馈、\(current.document.items.count) 个标注及完整上下文，并复制给 Agent 的说明。包含当前未保存的内容。"
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
                publishedHandoff = nil
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

    var mcpExecutable: URL {
        AppDistribution.mcpExecutableURL(applicationURL: Bundle.main.bundleURL)
    }

    var mcpLibraryOverride: URL? {
        handoffLibrary.directory == HandoffLibrary.defaultDirectory ? nil : handoffLibrary.directory
    }

    func showAgentConnection() {
        refreshPublishedHistory()
        agentConnectionPresented = true
        refreshHarnessConnections()
    }

    private var harnessManager: HarnessConnectionManager {
        var preferred: [AgentHarness: URL] = [:]
        for harness in AgentHarness.allCases {
            if let path = UserDefaults.standard.string(forKey: "harnessCLI.\(harness.rawValue)") {
                preferred[harness] = URL(fileURLWithPath: path)
            }
        }
        return HarnessConnectionManager(executable: mcpExecutable, library: mcpLibraryOverride, preferredCLIs: preferred)
    }

    func refreshHarnessConnections() {
        guard !isManagingHarness else { return }
        isManagingHarness = true
        let manager = harnessManager
        Task {
            harnessStatuses = await Task.detached {
                Dictionary(uniqueKeysWithValues: AgentHarness.allCases.map { ($0, manager.inspect($0)) })
            }.value
            isManagingHarness = false
        }
    }

    func chooseHarnessCLI(_ harness: AgentHarness) {
        let panel = NSOpenPanel()
        panel.title = "选择 \(harness.title) CLI 程序"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            agentConnectionMessage = "所选文件不可执行，请选择 \(harness.command) 程序。"; return
        }
        UserDefaults.standard.set(url.path, forKey: "harnessCLI.\(harness.rawValue)")
        refreshHarnessConnections()
    }

    func configureHarness(_ harness: AgentHarness, removing: Bool = false) {
        guard !isManagingHarness else { return }
        isManagingHarness = true
        agentConnectionMessage = removing ? "正在移除 \(harness.title) 的 OneShot 连接…" : "正在配置 \(harness.title)…"
        let manager = harnessManager
        Task {
            do {
                let backup = try await Task.detached {
                    try removing ? manager.remove(harness) : manager.connect(harness)
                }.value
                agentConnectionMessage = removing
                    ? "已移除 \(harness.title) 的用户级 OneShot 配置。已有会话请重启连接；交付材料仍保留。"
                    : "\(harness.title) 配置已写入，本地服务检查通过。请在客户端重启 MCP 连接或开始新会话；尚未确认 Agent 已连接。"
                if let backup { agentConnectionMessage += "\n原配置备份：\(backup.path)" }
            } catch { agentConnectionMessage = error.localizedDescription }
            harnessStatuses = await Task.detached {
                Dictionary(uniqueKeysWithValues: AgentHarness.allCases.map { ($0, manager.inspect($0)) })
            }.value
            isManagingHarness = false
        }
    }

    func refreshPublishedHistory() {
        do { publishedHistory = try handoffLibrary.list() }
        catch { agentConnectionMessage = error.localizedDescription }
    }

    func copyPublishedPrompt(_ entry: PublishedHandoff) {
        do {
            _ = try handoffLibrary.resolve(reference: entry.reference)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(entry.prompt, forType: .string) else {
                throw HandoffReadError.invalidPackage("复制失败，请选择文字手动复制。")
            }
            status = "材料 \(entry.reference) 已准备好，引用已复制。"
        } catch { show(error) }
    }

    func revokePublished(_ entry: PublishedHandoff) {
        do {
            try handoffLibrary.revoke(reference: entry.reference)
            refreshPublishedHistory()
            if publishedHandoff?.reference == entry.reference {
                publishedHandoff = publishedHistory.first { $0.reference == entry.reference }
            }
            status = "已撤销 \(entry.reference) 的后续 MCP 读取。"
        } catch { show(error) }
    }

    func checkAgentConnection() {
        guard !isCheckingAgentConnection else { return }
        isCheckingAgentConnection = true
        agentConnectionMessage = "正在检查本地 MCP 服务…"
        let executable = mcpExecutable, directory = handoffLibrary.directory
        Task {
            do {
                try await Task.detached { try MCPConnectionConfiguration.check(executable: executable, library: directory) }.value
                agentConnectionMessage = "本地服务检查通过。此检查不代表 Agent 已连接；配置后请在客户端重新连接或开始新会话。"
            } catch { agentConnectionMessage = error.localizedDescription }
            isCheckingAgentConnection = false
        }
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
        feedbackEditor.commitEditing()
        window?.makeFirstResponder(nil)
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存对“\(title)”的修改？"
        alert.informativeText = "原始采集已保存。反馈、控件引用和标注可以一起保存为可继续编辑的项目。"
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
