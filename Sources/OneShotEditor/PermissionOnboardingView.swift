import SwiftUI
import OneShotCore

/// Explains the two independent permissions before the user asks macOS to grant them.
/// Opening this guide never starts a capture or presents a system permission request.
struct PermissionOnboardingView: View {
    @ObservedObject var capture: CaptureController

    private var isReady: Bool { capture.permissionCheckError == nil && capture.permissionStatus?.allGranted == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 7) {
                    Text("开始使用 OneShot").font(.system(size: 26, weight: .bold))
                    Text("先完成两项权限设置，就能截取应用窗口、标注控件，\n把画面和你的意见一起交给 Agent。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text("1  权限准备").foregroundStyle(.primary).fontWeight(.semibold)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text("2  快捷键采集")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text("3  标注并交付")
                    }.font(.caption).foregroundStyle(.secondary).padding(.bottom, 2)

                    permissionCard(.screenRecording, step: 1)
                    permissionCard(.accessibility, step: 2)

                    if let error = capture.permissionCheckError {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("暂时无法确认权限状态").font(.subheadline.weight(.semibold))
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("只会在你点击“开启”后请求系统授权，不会自动开始截图。", systemImage: "hand.raised")
                        Text("如果系统列表显示“OneShot Capture”，它是 OneShot 的采集组件。开启权限后返回这里，应用会重新检查。")
                        Text("没有出现系统提示时，可分别点击“前往系统设置”，找到 OneShot 或 OneShot Capture 并开启开关。")
                    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.trailing, 4)
            }

            Divider()
            HStack(spacing: 12) {
                Button("稍后设置", action: capture.skipPermissionGuide)
                    .help("暂时跳过权限设置，仍可打开和编辑已有采集。")
                Spacer()
                Button(action: capture.checkPermissions) {
                    HStack(spacing: 6) {
                        if capture.isCheckingPermissions { ProgressView().controlSize(.small) }
                        Text(capture.isCheckingPermissions ? "正在检查…" : "重新检查")
                    }
                }.disabled(capture.isBusy)
                Button("开始使用 OneShot", action: capture.finishPermissionGuide)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!isReady || capture.isBusy || capture.authorizationInFlight != nil)
            }
            Text(isReady ? "权限已就绪。切到要采集的应用，按 ⌃⌥⌘S 开始。" : "暂时跳过也能编辑已有项目，首次采集前再完成设置。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 700, height: 650)
        .interactiveDismissDisabled()
    }

    private func permissionCard(_ kind: CapturePermissionKind, step: Int) -> some View {
        let granted = grant(for: kind) == .granted
        let requesting = capture.authorizationInFlight == kind
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 11) {
                Image(systemName: granted ? "checkmark.circle.fill" : symbol(for: kind))
                    .font(.system(size: 21)).foregroundStyle(granted ? .green : .blue)
                    .frame(width: 27)
                Text("\(step). \(title(for: kind))").font(.headline)
                Spacer()
                permissionState(granted: granted, requesting: requesting)
            }
            Text(explanation(for: kind)).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 11) {
                if granted {
                    Label("已完成", systemImage: "checkmark").font(.caption.weight(.medium)).foregroundStyle(.green)
                } else {
                    Button(requesting ? "等待系统授权…" : "开启\(title(for: kind))") {
                        capture.requestPermission(kind)
                    }.buttonStyle(.borderedProminent)
                        .disabled(capture.isBusy || capture.authorizationInFlight != nil)
                }
                Button(granted ? "查看系统设置" : "前往系统设置") {
                    capture.openPermissionSettings(kind)
                }.accessibilityLabel("打开\(title(for: kind))设置")
                    .disabled(capture.isCapturing)
            }
            Text(kind.settingsPathDescription)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(granted ? Color.green.opacity(0.28) : Color.primary.opacity(0.09)))
    }

    private func permissionState(granted: Bool, requesting: Bool) -> some View {
        let unknown = capture.permissionStatus == nil || capture.permissionCheckError != nil
        let text = granted ? "已开启" : requesting ? "等待授权" : capture.isCheckingPermissions ? "检查中" : unknown ? "待确认" : "未开启"
        let color: Color = granted ? .green : requesting || capture.isCheckingPermissions || unknown ? .secondary : .orange
        return Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func grant(for kind: CapturePermissionKind) -> CapturePermissionGrant? {
        guard capture.permissionCheckError == nil else { return nil }
        switch kind {
        case .screenRecording: return capture.permissionStatus?.screenRecording
        case .accessibility: return capture.permissionStatus?.accessibility
        }
    }

    private func title(for kind: CapturePermissionKind) -> String {
        switch kind { case .screenRecording: return "屏幕录制"; case .accessibility: return "辅助功能" }
    }

    private func symbol(for kind: CapturePermissionKind) -> String {
        switch kind { case .screenRecording: return "rectangle.inset.filled"; case .accessibility: return "accessibility" }
    }

    private func explanation(for kind: CapturePermissionKind) -> String {
        switch kind {
        case .screenRecording: return "截取你选择的应用窗口，保留画面用于标注。不会在后台持续录制屏幕。"
        case .accessibility: return "读取按钮、文字和控件状态，让 Agent 准确理解你指的是哪个位置。"
        }
    }
}
