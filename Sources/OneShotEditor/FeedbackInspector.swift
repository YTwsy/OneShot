import AppKit
import SwiftUI
import OneShotCore

struct FeedbackInspector: View {
    @ObservedObject var model: EditorModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("反馈描述").font(.headline)
                Spacer()
                Button("新增", systemImage: "plus", action: model.addFeedback)
                    .help("新增一条独立反馈")
            }
            if let feedback = model.selectedFeedback, let document = model.document {
                editor(feedback, document: document)
                if model.referenceSearchQuery != nil { referenceSearch }
                if !feedback.controlReferences.isEmpty {
                    referenceSummary(feedback, document: document)
                }
                HStack {
                    Text("描述与引用会一起保存和导出。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { model.deleteFeedback(feedback.id) } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless).help("删除这条反馈").accessibilityLabel("删除反馈")
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "text.bubble").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("把想法写清楚").font(.title3.weight(.medium))
                    Text("描述想改什么，随时点选或输入 @ 引用控件。一条反馈可以引用多个对象。")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("写第一条反馈", systemImage: "plus.bubble", action: model.addFeedback)
                        .buttonStyle(.borderedProminent)
                }.padding(.vertical, 22)
            }
            Divider()
            HStack {
                Text("全部反馈").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(model.document?.feedbacks.count ?? 0)").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array((model.document?.feedbacks ?? []).enumerated()), id: \.element.id) { index, item in
                        Button { model.selectFeedback(item.id) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 18).padding(.top, 2)
                                Text(item.plainText.isEmpty ? "未填写的反馈" : item.plainText)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(10)
                                .background(model.selectedFeedbackID == item.id ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel("反馈 \(index + 1)：\(item.plainText.isEmpty ? "未填写" : item.plainText)")
                    }
                }
            }.frame(minHeight: 60, maxHeight: 180)
            Text("箭头、方框、编号和文字仍可在“标注”中编辑。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func editor(_ feedback: FeedbackItem, document: AnnotationDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                Text("描述想修改的地方").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 13).padding(.top, 12)
            FeedbackTextEditor(feedbackID: feedback.id,
                content: Binding(get: { model.document?.feedbacks.first(where: { $0.id == feedback.id })?.content ?? [] },
                                 set: { model.updateFeedback(feedback.id, content: $0) }),
                controlReferences: document.feedbackControlReferences, bridge: model.feedbackEditor,
                onMention: model.mentionChanged,
                onReferenceSelect: { model.highlightedElementID = $0 },
                onMentionMove: model.moveMentionSelection,
                onMentionAccept: model.acceptMentionSelection,
                onCancel: { model.cancelReferencePicking() })
                .id(feedback.id)
                .frame(minHeight: 148, idealHeight: 190, maxHeight: 240)
            Divider()
            HStack(spacing: 4) {
                Button("引用控件", systemImage: "viewfinder", action: model.beginReferencePicking)
                    .disabled(model.elementIndex?.elements.isEmpty ?? true)
                Button("@ 搜索") { model.beginReferenceSearch(); searchFocused = true }
                    .disabled(model.elementIndex?.elements.isEmpty ?? true)
                Spacer(minLength: 0)
            }.buttonStyle(.borderless).controlSize(.small).padding(11)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.10)))
    }

    private var referenceSearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索控件名称或类型", text: Binding(get: { model.referenceSearchQuery ?? "" }, set: {
                    // Ending field editing can write its final value after the
                    // candidate was accepted or cancelled; do not reopen it.
                    guard model.referenceSearchQuery != nil else { return }
                    model.referenceSearchQuery = $0; model.referenceSearchSelection = 0
                })).textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { _ = model.acceptMentionSelection() }
                    .onExitCommand { model.cancelReferencePicking() }
                    .onMoveCommand { direction in
                        if direction == .down { model.moveMentionSelection(1) }
                        else if direction == .up { model.moveMentionSelection(-1) }
                    }
                Button { model.cancelReferencePicking() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭控件搜索")
            }.padding(9).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            let results = model.referenceSearchResults
            if results.isEmpty {
                Text("没有匹配的控件。可换个名称，或到控件树查找。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(results) { element in
                                let selected = results.indices.contains(model.referenceSearchSelection)
                                    && results[model.referenceSearchSelection].id == element.id
                                Button { model.insertReference(element.id, fromSearch: true) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "viewfinder").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(element.label.isEmpty ? model.friendlyRole(element.role) : element.label).lineLimit(1)
                                            Text(model.friendlyRole(element.role) + (element.imageBounds == nil ? " · 截图外或无坐标" : ""))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        if selected { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(selected ? Color.accentColor.opacity(0.10) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain).id(element.id)
                            }
                        }
                    }.frame(maxHeight: 150)
                        .onChange(of: model.referenceSearchSelection) { _, value in
                            if results.indices.contains(value) { proxy.scrollTo(results[value].id) }
                        }
                }
            }
        }
    }

    private func referenceSummary(_ feedback: FeedbackItem, document: AnnotationDocument) -> some View {
        let references = document.feedbackControlReferences.filter { reference in
            feedback.controlReferences.contains { $0.nodeID == reference.nodeID }
        }
        return VStack(alignment: .leading, spacing: 5) {
            Text("引用 \(references.count) 个控件").font(.caption).foregroundStyle(.secondary)
            ScrollView {
            ForEach(references) { reference in
                Button { model.highlightedElementID = reference.nodeID } label: {
                    HStack(spacing: 7) {
                        Text("R\(document.feedbackReferenceNumber(for: reference.nodeID) ?? 0)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.tint)
                        Text(reference.label).font(.caption).lineLimit(1)
                        Spacer()
                        Image(systemName: "scope").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }.buttonStyle(.plain).help("在截图中定位此控件")
            }
            }.frame(maxHeight: 90)
        }
    }
}
