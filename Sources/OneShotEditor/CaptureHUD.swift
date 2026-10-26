import AppKit
import SwiftUI

/// A passive panel: the target application stays frontmost while AX is being read.
@MainActor
final class CaptureHUD {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class State: ObservableObject {
        @Published var message = "正在采集…"
        @Published var detail = "请保持目标窗口，完成后会打开标注工作台。"
        @Published var startedAt = Date()
    }

    private let state = State()
    private var panel: NSPanel?

    func begin() {
        state.startedAt = Date()
        update("正在采集…", detail: "正在识别前台窗口，请稍候。")
        if panel == nil {
            let window = Panel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 102),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.contentView = NSHostingView(rootView: HUDView(state: state))
            panel = window
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(x: visible.maxX - 380, y: visible.maxY - 122))
        }
        panel?.orderFrontRegardless()
    }

    func update(_ message: String, detail: String = "请保持目标窗口，完成后会打开标注工作台。") {
        state.message = message
        state.detail = detail
    }

    func hide() { panel?.orderOut(nil) }

    private struct HUDView: View {
        @ObservedObject var state: State

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small).padding(.top, 3)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(state.message).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 5)
                        TimelineView(.periodic(from: state.startedAt, by: 1)) { context in
                            Text("\(max(0, Int(context.date.timeIntervalSince(state.startedAt)))) 秒")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(16).frame(width: 360, height: 102, alignment: .center)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)))
            .accessibilityElement(children: .combine)
        }
    }
}
