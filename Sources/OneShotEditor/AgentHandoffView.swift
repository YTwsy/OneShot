import AppKit
import SwiftUI

struct AgentHandoffView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Agent 材料已准备好", systemImage: "checkmark.circle.fill")
                .font(.title2.bold()).foregroundStyle(.green)
            Text("把下面的说明粘贴给可读取本地文件的 Agent。材料先呈现标注重点，并保留截图、冻结的控件信息和完整上下文。")
                .foregroundStyle(.secondary)
            if let handoff = model.handoff {
                ScrollView {
                    Text(handoff.prompt).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 180).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text(handoff.directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("材料包含当前标注快照。后续修改后，请再次导出。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([handoff.directory]) }
                    Spacer()
                    Button("再次复制说明", action: model.copyHandoffPrompt)
                    Button("完成") { model.handoffPresented = false }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 620)
    }
}
