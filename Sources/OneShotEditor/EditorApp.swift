import AppKit
import SwiftUI
import OneShotCore

@main
enum EditorApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = EditorDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class EditorDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    let model = EditorModel()
    lazy var capture = CaptureController(model: model)
    var window: NSWindow!
    private var statusItem: NSStatusItem?
    private var captureStatusItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 900, height: 620)
        window.title = "OneShot"
        window.delegate = self; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(model: model, capture: capture))
        model.window = window
        capture.showEditor = { [weak self] in self?.showEditor() }
        capture.hideEditor = { [weak self] in self?.window.orderOut(nil); NSApp.hide(nil) }
        makeMenus()
        makeStatusMenu()
        capture.enableShortcut()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--capture"), arguments.indices.contains(flag + 1) {
            model.open(URL(fileURLWithPath: arguments[flag + 1]))
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first, model.confirmUnsaved() { model.open(URL(fileURLWithPath: path)) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model.confirmUnsaved() ? .terminateNow : .terminateCancel }
    func applicationWillTerminate(_ notification: Notification) { capture.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.confirmUnsaved() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showEditor(); return true }
    @objc func showEditor() {
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func makeStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "OneShot 采集")
        item.button?.toolTip = "OneShot · \(GlobalCaptureHotKey.displayString) 采集当前应用"
        let menu = NSMenu(); menu.delegate = self
        add(menu, "打开标注工作台", #selector(showEditor), "")
        add(menu, "3 秒后采集当前应用", #selector(countdownCapture), "")
        add(menu, "取消倒计时", #selector(cancelCaptureCountdown), "")
        menu.addItem(.separator())
        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(status); captureStatusItem = status
        add(menu, "打开采集目录", #selector(revealCaptures), "")
        add(menu, "选择采集组件…", #selector(chooseProbe), "")
        add(menu, "重新启用快捷键", #selector(enableShortcut), "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 OneShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu; statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        captureStatusItem?.title = capture.isCapturing ? "采集中…" : capture.countdown.map { "\($0) 秒后采集" }
            ?? (capture.shortcutRegistered ? "\(GlobalCaptureHotKey.displayString) 已启用" : "采集快捷键未启用")
    }

    func makeMenus() {
        let bar = NSMenu()
        let application = NSMenuItem(); bar.addItem(application)
        let appMenu = NSMenu(); application.submenu = appMenu
        appMenu.addItem(withTitle: "关于 OneShot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 OneShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); file.title = "文件"; file.submenu = NSMenu(title: "文件"); bar.addItem(file)
        add(file.submenu!, "3 秒后采集当前应用", #selector(countdownCapture), "")
        add(file.submenu!, "打开…", #selector(openAction), "o")
        add(file.submenu!, "保存", #selector(saveAction), "s")
        add(file.submenu!, "另存为…", #selector(saveAsAction), "s", [.command, .shift])
        add(file.submenu!, "导出 PNG…", #selector(exportAction), "e")
        let edit = NSMenuItem(); edit.title = "编辑"; edit.submenu = NSMenu(title: "编辑"); bar.addItem(edit)
        // Responder-chain actions preserve native text editing in the inspector.
        edit.submenu!.addItem(withTitle: "撤销", action: #selector(undo(_:)), keyEquivalent: "z")
        let redo = edit.submenu!.addItem(withTitle: "重做", action: #selector(redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.submenu!.addItem(.separator())
        edit.submenu!.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu!.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu!.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu!.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = bar
    }
    func add(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key); item.target = self; item.keyEquivalentModifierMask = modifiers
    }
    @objc func openAction() { model.openPanel() }
    @objc func saveAction() { model.save() }
    @objc func saveAsAction() { model.save(asNew: true) }
    @objc func exportAction() { model.exportPNG() }
    @objc func countdownCapture() { capture.captureAfterCountdown() }
    @objc func cancelCaptureCountdown() { capture.cancelCountdown() }
    @objc func chooseProbe() { showEditor(); capture.chooseProbe() }
    @objc func revealCaptures() { capture.revealCaptures() }
    @objc func enableShortcut() { capture.enableShortcut() }
    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(countdownCapture) || menuItem.action == #selector(chooseProbe) { return !capture.isCapturing && capture.countdown == nil }
        if menuItem.action == #selector(cancelCaptureCountdown) { return capture.countdown != nil }
        if menuItem.action == #selector(undo(_:)) { return !model.undoHistory.isEmpty }
        if menuItem.action == #selector(redo(_:)) { return !model.redoHistory.isEmpty }
        if [#selector(saveAction), #selector(saveAsAction), #selector(exportAction)].contains(menuItem.action) { return model.project != nil }
        return true
    }
}

struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var capture: CaptureController
    let colors = ["#E5484D", "#F59E0B", "#30A46C", "#3E63DD", "#8E4EC6", "#FFFFFF", "#202124"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("OneShot").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("标注工作台").foregroundStyle(.secondary)
                Spacer()
                Button("打开…", systemImage: "folder", action: model.openPanel)
                Button("保存项目", systemImage: "square.and.arrow.down") { model.save() }.disabled(model.project == nil)
                Button("导出 PNG", systemImage: "square.and.arrow.up", action: model.exportPNG).disabled(model.project == nil)
            }.padding(18)
            Divider()
            HStack(spacing: 12) {
                if capture.isCapturing { ProgressView().controlSize(.small) }
                else { Image(systemName: "viewfinder").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(capture.message).font(.caption).textSelection(.enabled).lineLimit(3)
                    if let ready = capture.pending.first {
                        HStack {
                            Text("\(capture.pending.count) 份新采集待打开").font(.caption).foregroundStyle(.secondary)
                            Button("打开 \(ready.applicationName) 的采集") { capture.openPending(ready) }
                        }
                    }
                }
                Spacer()
                Button("3 秒后采集") { capture.captureAfterCountdown() }
                    .disabled(capture.isCapturing || capture.countdown != nil)
                Menu("采集设置") {
                    Text("快捷键：\(GlobalCaptureHotKey.displayString)")
                    Button("重新启用快捷键", action: capture.enableShortcut)
                    Button("选择采集组件…", action: capture.chooseProbe).disabled(capture.isCapturing)
                    Button("打开采集目录", action: capture.revealCaptures)
                }.fixedSize()
            }.padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            if let document = model.document, let image = model.image {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            toolButton(.select, "选择", "cursorarrow")
                            toolButton(.element, "控件", "viewfinder")
                            toolButton(.number, "编号", "number.circle")
                            toolButton(.arrow, "箭头", "arrow.up.right")
                            toolButton(.rectangle, "方框", "rectangle")
                            toolButton(.text, "文字", "textformat")
                            Spacer()
                            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("撤销 ⌘Z").accessibilityLabel("撤销").disabled(model.undoHistory.isEmpty)
                            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("重做 ⇧⌘Z").accessibilityLabel("重做").disabled(model.redoHistory.isEmpty)
                            Picker("缩放", selection: $model.zoom) {
                                Text("适应").tag(1.0); Text("150%").tag(1.5); Text("200%").tag(2.0); Text("300%").tag(3.0)
                            }.labelsHidden().frame(width: 82).accessibilityLabel("画布缩放")
                        }.padding(12)
                        Divider()
                        AnnotationCanvas(image: image, document: document, tool: model.tool, selectedID: model.selectedID,
                                         colorHex: model.colorHex, strokeWidth: model.strokeWidth, zoom: model.zoom,
                                         onSelect: model.select, onChange: { model.changeItems($0) }, onDelete: model.deleteSelected,
                                         elementIndex: model.elementIndex, highlightedElementID: model.highlightedElementID,
                                         onElementSelect: model.annotateElement, onUndo: model.undo, onRedo: model.redo,
                                         canUndo: !model.undoHistory.isEmpty, canRedo: !model.redoHistory.isEmpty)
                    }
                    Divider()
                    inspector(document).frame(width: 290)
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "rectangle.and.pencil.and.ellipsis").font(.system(size: 52)).foregroundStyle(.tint)
                    Text("让重点一眼可见").font(.title2.bold())
                    Text("打开一次已保存的采集，用编号、箭头和文字表达想法。\n标注可以修改，原始截图与上下文会一起保留。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("打开采集或项目…", action: model.openPanel).buttonStyle(.borderedProminent).controlSize(.large)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Circle().fill(model.isDirty ? Color.orange : Color.green).frame(width: 6, height: 6)
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let document = model.document { Text("\(document.items.count) 个标注").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 16).padding(.vertical, 9)
        }.frame(minWidth: 900, minHeight: 580)
    }

    func toolButton(_ tool: EditorTool, _ title: String, _ icon: String) -> some View {
        Button { model.tool = tool; if tool == .element { model.inspectorMode = "elements" } } label: { Label(title, systemImage: icon).padding(.vertical, 4).padding(.horizontal, 3) }
            .buttonStyle(.bordered).tint(model.tool == tool ? .accentColor : .secondary)
            .accessibilityLabel(title + "工具")
            .disabled(tool == .element && (model.elementIndex?.elements.isEmpty ?? true))
    }

    func inspector(_ document: AnnotationDocument) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("侧栏", selection: $model.inspectorMode) {
                Text("标注").tag("annotations"); Text("控件树").tag("elements")
            }.pickerStyle(.segmented)
            if model.inspectorMode == "elements" {
                elementsInspector
            } else {
            Text(model.selected == nil ? "新标注样式" : "编辑标注").font(.headline)
            HStack(spacing: 8) {
                ForEach(colors, id: \.self) { hex in
                    Button { model.setColor(hex) } label: {
                        Circle().fill(color(hex)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity((model.selected?.colorHex ?? model.colorHex) == hex ? 0.8 : 0.15), lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityLabel("颜色 " + hex)
                }
            }
            HStack {
                Text("线条").foregroundStyle(.secondary)
                Spacer()
                ForEach([3.0, 6.0, 10.0], id: \.self) { width in
                    Button(width == 3 ? "细" : width == 6 ? "中" : "粗") { model.setWidth(width) }
                        .tint((model.selected?.strokeWidth ?? model.strokeWidth) == width ? .accentColor : .secondary)
                }
            }
            if let selected = model.selected {
                if selected.kind == .element, let nodeID = selected.targetNodeID {
                    let node = model.elementIndex?.element(id: nodeID)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("控件 #\(selected.number)").font(.subheadline.bold())
                        Text(node?.label ?? nodeID).lineLimit(3)
                        Text("\(node?.role ?? "AX") · \(nodeID)").font(.caption).foregroundStyle(.secondary)
                        if node?.imageBounds == nil { Text("截图外或没有可定位坐标").font(.caption).foregroundStyle(.secondary) }
                        Button("在控件树中查看") { model.highlightedElementID = nodeID; model.elementSearch = nodeID; model.inspectorMode = "elements" }
                    }
                }
                if selected.kind == .text || selected.kind == .element {
                    TextField("文字说明", text: Binding(get: { model.selected?.text ?? "" }, set: { text in
                        model.updateSelected({ $0.text = text }, group: "text-\(selected.id)")
                    }), axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder).accessibilityLabel("标注文字")
                }
                if selected.kind == .number {
                    Stepper("编号 \(selected.number)", value: Binding(get: { model.selected?.number ?? 1 }, set: { value in model.updateSelected { $0.number = value } }), in: 1...999)
                }
                Button("删除标注", systemImage: "trash", role: .destructive, action: model.deleteSelected)
            } else {
                Text("点击放置编号和文字，拖动绘制箭头和方框。使用选择工具移动已有标注。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack { Text("标注").font(.headline); Spacer(); Text("\(document.items.count)").foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(document.items) { item in
                        Button { model.select(item.id); model.tool = .select } label: {
                            HStack {
                                Image(systemName: icon(item.kind)).foregroundStyle(color(item.colorHex)).frame(width: 22)
                                Text(label(item)).lineLimit(1)
                                Spacer()
                            }.padding(8).frame(maxWidth: .infinity)
                                .background(model.selectedID == item.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel(label(item))
                    }
                }
            }
            Text("保存项目后可继续修改。\n导出 PNG 得到合成后的图片。")
                .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxHeight: .infinity, alignment: .top)
    }

    var elementsInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("搜索控件、文字或节点 ID", text: $model.elementSearch).textFieldStyle(.roundedBorder).accessibilityLabel("搜索控件")
            Text(model.elementIndex?.status ?? "这份采集没有可用的控件树，仍可使用图形标注。")
                .font(.caption).foregroundStyle(.secondary)
            if let id = model.highlightedElementID, let element = model.elementIndex?.element(id: id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(element.label).font(.subheadline.bold()).lineLimit(3)
                    Text("\(element.role) · \(id)").font(.caption).foregroundStyle(.secondary)
                    if element.imageBounds == nil { Text("截图外或没有可定位坐标").font(.caption).foregroundStyle(.secondary) }
                    Button("标注此控件", systemImage: "plus.bubble") { model.annotateElement(id) }.buttonStyle(.borderedProminent)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.visibleElements) { element in
                        HStack(spacing: 4) {
                            if model.elementSearch.isEmpty {
                                Button {
                                    if model.expandedElements.contains(element.id) { model.expandedElements.remove(element.id) }
                                    else { model.expandedElements.insert(element.id) }
                                } label: {
                                    Image(systemName: model.expandedElements.contains(element.id) ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 12)
                                }.buttonStyle(.plain).accessibilityLabel("展开或收起 " + element.id)
                            }
                            Button { model.highlightElement(element.id) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    if !element.label.isEmpty { Text(element.label).lineLimit(1) }
                                    Text("\(element.role) · \(element.id)" + (element.imageBounds == nil ? " · 无框" : ""))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityLabel("控件 " + element.id + " " + element.label)
                        }.padding(.leading, model.elementSearch.isEmpty ? CGFloat(min(element.depth, 8) * 8) : 0)
                            .padding(.vertical, 6).padding(.trailing, 4)
                            .background(model.highlightedElementID == element.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            Text("从截图点选或从树中选择控件，再填写说明。引用绑定到这次采集，不会操作原应用。")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxHeight: .infinity)
    }
    func label(_ item: AnnotationItem) -> String {
        switch item.kind { case .number: return "编号 \(item.number)"; case .arrow: return "箭头"; case .rectangle: return "方框"; case .text: return item.text.isEmpty ? "文字说明" : item.text; case .element: return "控件 #\(item.number) · " + (item.text.isEmpty ? (model.elementIndex?.element(id: item.targetNodeID ?? "")?.label ?? "添加说明") : item.text) }
    }
    func icon(_ kind: AnnotationKind) -> String {
        switch kind { case .number: return "number.circle"; case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .text: return "textformat"; case .element: return "viewfinder" }
    }
    func color(_ hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xE5484D
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
