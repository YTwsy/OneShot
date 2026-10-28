import AppKit
import SwiftUI
import OneShotCore

struct AgentHandoffView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Agent 材料已准备好", systemImage: "checkmark.circle.fill")
                .font(.title2.bold()).foregroundStyle(.green)
            if let entry = model.publishedHandoff {
                Text(entry.reference).font(.title3.monospaced().bold()).textSelection(.enabled)
                Text("把引用粘贴给已连接 OneShot MCP 的 Agent，即可读取本次反馈、标注图和完整冻结上下文。")
                    .foregroundStyle(.secondary)
                if let image = NSImage(contentsOf: model.handoffLibrary.snapshotDirectory(for: entry).appendingPathComponent("annotated.png")) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180)
                        .accessibilityLabel("本次交付的标注图预览")
                }
                ScrollView {
                    Text(entry.prompt).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 110).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text("这是固定版本，包含当前未保存的反馈。后续编辑请再次交付；旧引用继续指向旧版本。")
                    .font(.caption).foregroundStyle(.secondary)
                if entry.revokedAt != nil { Text("此版本已撤销").foregroundStyle(.orange) }
                HStack {
                    Button("连接说明") {
                        model.handoffPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.showAgentConnection() }
                    }
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.handoffLibrary.snapshotDirectory(for: entry)])
                    }
                    Spacer()
                    Button("复制引用") { model.copyPublishedPrompt(entry) }.disabled(entry.revokedAt != nil)
                    Button("完成") { model.handoffPresented = false }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } else if let handoff = model.handoff {
                Text("将说明粘贴给可读取本地文件的 Agent。").foregroundStyle(.secondary)
                ScrollView {
                    Text(handoff.prompt).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 180).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text(handoff.directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("材料包含当前反馈、引用和标注的快照。后续修改后，请再次导出。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([handoff.directory]) }
                    Spacer()
                    Button("再次复制说明", action: model.copyHandoffPrompt)
                    Button("完成") { model.handoffPresented = false }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 660)
    }
}

struct AgentConnectionView: View {
    @ObservedObject var model: EditorModel
    @State private var format = "codex"
    @State private var copied = false

    private var configuration: String {
        format == "codex"
            ? MCPConnectionConfiguration.toml(executable: model.mcpExecutable, library: model.mcpLibraryOverride)
            : MCPConnectionConfiguration.json(executable: model.mcpExecutable, library: model.mcpLibraryOverride)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent 连接与材料").font(.title2.bold())
            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("一次连接，按编号读取每次交付").font(.headline)
                        Text("选择客户端写入用户级配置，之后只需粘贴材料引用。新增交付不需要重启连接。")
                            .foregroundStyle(.secondary)
                        ForEach(AgentHarness.allCases) { harness in
                            harnessRow(harness)
                        }
                        HStack {
                            Button("刷新状态", action: model.refreshHarnessConnections).disabled(model.isManagingHarness)
                            Button("检查本地服务", action: model.checkAgentConnection)
                                .disabled(model.isCheckingAgentConnection || model.isManagingHarness)
                            if model.isManagingHarness || model.isCheckingAgentConnection { ProgressView().controlSize(.small) }
                        }
                        Text(model.agentConnectionMessage).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        DisclosureGroup("手动配置与其他客户端") {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker("配置格式", selection: $format) {
                                    Text("Codex · TOML").tag("codex")
                                    Text("Claude Code / 通用 · JSON").tag("json")
                                }.pickerStyle(.segmented).onChange(of: format) { _, _ in copied = false }
                                Text(configuration).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                Text(format == "codex" ? "合并到 ~/.codex/config.toml 的 mcp_servers，或在 Codex 的 MCP 设置中添加。"
                                     : "Claude Code 用户级配置位于 ~/.claude.json 的 mcpServers；其他客户端使用各自的 MCP 配置。仅合并 oneshot 条目。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(copied ? "已复制配置" : "复制配置") {
                                    NSPasteboard.general.clearContents()
                                    copied = NSPasteboard.general.setString(configuration, forType: .string)
                                }
                            }.padding(.top, 8)
                        }
                        Text("仅在点击连接、更新或移除时修改配置，并备份原文件。只提供已交付的固定版本；未交付的采集和草稿不进入材料库。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                }.tabItem { Text("连接 Agent") }
                VStack(alignment: .leading, spacing: 10) {
                    Text("撤销会阻止后续 MCP 读取，保留本地文件；无法收回 Agent 已读取的内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.publishedHistory.isEmpty {
                        ContentUnavailableView("尚无交付材料", systemImage: "tray", description: Text("在编辑器中点击“交给 Agent”即可创建。"))
                    } else {
                        List(model.publishedHistory) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.reference).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Text(entry.title).lineLimit(1)
                                    Text(entry.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if entry.revokedAt != nil { Text("已撤销").foregroundStyle(.secondary) }
                                else {
                                    Button("复制引用") { model.copyPublishedPrompt(entry) }
                                    Button("撤销") { model.revokePublished(entry) }
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    Button("刷新", action: model.refreshPublishedHistory)
                }.padding(16).tabItem { Text("交付历史") }
            }
            HStack { Spacer(); Button("完成") { model.agentConnectionPresented = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 760, height: 680)
    }

    private func harnessRow(_ harness: AgentHarness) -> some View {
        let status = model.harnessStatuses[harness]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(harness.title).font(.headline)
                Spacer()
                Text(status?.state.title ?? "正在检查…")
                    .foregroundStyle(status?.state == .configured ? Color.green : Color.secondary)
                Button(status?.state == .needsUpdate ? "更新连接" : "连接到 \(harness.title)") {
                    model.configureHarness(harness)
                }.disabled(model.isManagingHarness || status?.canConnect != true)
                if status?.canRemove == true {
                    Button("移除连接") { model.configureHarness(harness, removing: true) }
                        .disabled(model.isManagingHarness)
                }
            }
            if let status {
                Text(status.detail).font(.caption).foregroundStyle(.secondary)
                if let path = status.configuration?.path {
                    Text("配置：\(path)").font(.caption.monospaced()).textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(status.cli.map { "CLI：" + $0.path } ?? "未找到 CLI")
                        .font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("选择程序…") { model.chooseHarnessCLI(harness) }
                        .font(.caption).disabled(model.isManagingHarness)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

}
