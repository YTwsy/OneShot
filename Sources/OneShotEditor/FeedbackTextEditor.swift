import AppKit
import SwiftUI
import OneShotCore

/// Keeps insertion commands separate from SwiftUI updates so picking on the canvas does
/// not lose the text selection. It only ever holds the currently displayed editor.
@MainActor
final class FeedbackEditorBridge: ObservableObject {
    fileprivate weak var editor: FeedbackNativeTextView?
    private var selections: [UUID: NSRange] = [:]

    fileprivate func attach(_ editor: FeedbackNativeTextView) {
        if self.editor !== editor { self.editor?.rememberSelection() }
        self.editor = editor
        editor.onSelectionChange = { [weak self] feedbackID, selection in
            self?.selections[feedbackID] = selection
        }
    }

    fileprivate func selection(for feedbackID: UUID) -> NSRange? { selections[feedbackID] }

    /// Call before replacing the active feedback or changing away from its editor.
    func commitEditing() {
        guard let editor else { return }
        (editor.delegate as? FeedbackTextEditor.Coordinator)?.commitEditing(editor)
    }

    func prepareForPicking() {
        editor?.prepareForPicking()
    }

    func insert(_ reference: FeedbackControlReference, replacingMention: Bool = false) {
        editor?.insertReference(reference, replacingMention: replacingMention)
    }

    func cancelPicking() {
        editor?.cancelMentionAndRestoreFocus()
    }

    func focus() {
        // A new feedback can be selected in the same action that requests focus.
        DispatchQueue.main.async { [weak self] in self?.editor?.restoreInsertionFocus() }
    }
}

struct FeedbackTextEditor: NSViewRepresentable {
    var feedbackID: UUID
    @Binding var content: [FeedbackSegment]
    var controlReferences: [FeedbackControlReference]
    var bridge: FeedbackEditorBridge
    var onMention: (String?) -> Void
    var onReferenceSelect: (String) -> Void
    var onMentionMove: (Int) -> Void = { _ in }
    var onMentionAccept: () -> Bool = { false }
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let editor = FeedbackNativeTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.isRichText = true
        editor.importsGraphics = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.usesFindPanel = true
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.textColor = .labelColor
        editor.insertionPointColor = .controlAccentColor
        editor.textContainerInset = NSSize(width: 11, height: 12)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("反馈描述，可输入 @ 引用控件")
        scroll.documentView = editor
        context.coordinator.editor = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? FeedbackNativeTextView else { return }
        context.coordinator.parent = self
        bridge.attach(editor)
        editor.onMention = onMention
        editor.onReferenceSelect = onReferenceSelect
        editor.onMentionMove = onMentionMove
        editor.onMentionAccept = onMentionAccept
        editor.onCancel = onCancel
        editor.updateReferenceNumbers(controlReferences)
        let changedFeedback = editor.feedbackID != feedbackID
        if changedFeedback || (!editor.hasMarkedText() && editor.segments != content) {
            editor.load(content, feedbackID: feedbackID, resetSelection: changedFeedback,
                        restoredSelection: changedFeedback ? bridge.selection(for: feedbackID) : nil)
            context.coordinator.lastPublishedContent = content
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let editor = scroll.documentView as? FeedbackNativeTextView {
            // Keep the retiring coordinator's binding: SwiftUI may already have
            // selected another feedback while removing this native view.
            coordinator.commitEditing(editor)
            editor.rememberSelection()
            if coordinator.parent.bridge.editor === editor {
                coordinator.parent.bridge.editor = nil
            }
            editor.delegate = nil
        }
        scroll.documentView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedbackTextEditor
        weak var editor: FeedbackNativeTextView?
        fileprivate var lastPublishedContent: [FeedbackSegment]

        init(parent: FeedbackTextEditor) {
            self.parent = parent
            self.lastPublishedContent = parent.content
        }

        fileprivate func commitEditing(_ editor: FeedbackNativeTextView) {
            let retiringParent = parent
            guard editor.feedbackID == retiringParent.feedbackID else { return }
            editor.commitMarkedText()
            editor.rememberSelection()
            let finalContent = editor.segments
            // Compare to our own publication snapshot, never to a binding that may
            // now point at a freshly reopened copy after the user chose Don't Save.
            if finalContent != lastPublishedContent {
                lastPublishedContent = finalContent
                retiringParent.content = finalContent
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let editor, !editor.isLoading else { return }
            // The marked string must remain entirely owned by the input method.
            // Its final content is published when composition commits.
            if !editor.hasMarkedText() {
                let content = editor.segments
                if content != lastPublishedContent {
                    lastPublishedContent = content
                    parent.content = content
                }
            }
            editor.allowMentionAfterEdit()
            editor.didEditOrMoveSelection()
            editor.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor, !editor.isLoading else { return }
            editor.didEditOrMoveSelection()
        }
    }
}

@MainActor
final class FeedbackNativeTextView: NSTextView {
    fileprivate var feedbackID: UUID?
    fileprivate var isLoading = false
    fileprivate var onMention: (String?) -> Void = { _ in }
    fileprivate var onReferenceSelect: (String) -> Void = { _ in }
    fileprivate var onMentionMove: (Int) -> Void = { _ in }
    fileprivate var onMentionAccept: () -> Bool = { false }
    fileprivate var onCancel: () -> Void = {}
    fileprivate var onSelectionChange: (UUID, NSRange) -> Void = { _, _ in }
    private var insertionSelection = NSRange(location: 0, length: 0)
    private var mentionRange: NSRange?
    private var lastMention: String?
    private var suppressMentionUntilEdit = false
    private var referenceNumbers: [String: Int] = [:]

    private var editingAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph]
    }

    fileprivate var segments: [FeedbackSegment] {
        segments(in: NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    private func segments(in range: NSRange) -> [FeedbackSegment] {
        guard let storage = textStorage, range.length > 0 else { return [] }
        var result: [FeedbackSegment] = []
        var text = ""
        func flushText() {
            if !text.isEmpty { result.append(.text(text)); text = "" }
        }
        storage.enumerateAttributes(in: range) { attributes, run, _ in
            if let attachment = attributes[.attachment] as? FeedbackReferenceAttachment {
                flushText()
                result.append(.control(attachment.reference))
            } else {
                // Plain-text paste never gets to manufacture a frozen-node reference.
                text += (storage.string as NSString).substring(with: run)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        flushText()
        return result
    }

    fileprivate func load(_ content: [FeedbackSegment], feedbackID: UUID, resetSelection: Bool,
                          restoredSelection: NSRange? = nil) {
        rememberSelection()
        isLoading = true
        defer { isLoading = false }
        let selection = restoredSelection ?? (resetSelection ? nil : selectedRange())
        self.feedbackID = feedbackID
        let attributed = NSMutableAttributedString()
        for segment in content {
            switch segment {
            case .text(let text):
                attributed.append(NSAttributedString(string: text, attributes: editingAttributes))
            case .control(let reference):
                attributed.append(attributedReference(reference))
            }
        }
        textStorage?.setAttributedString(attributed)
        typingAttributes = editingAttributes
        undoManager?.removeAllActions()
        insertionSelection = clamped(selection ?? NSRange(location: attributed.length, length: 0))
        setSelectedRange(insertionSelection)
        rememberSelection()
        mentionRange = nil
        lastMention = nil
        suppressMentionUntilEdit = false
        needsDisplay = true
    }

    fileprivate func updateReferenceNumbers(_ references: [FeedbackControlReference]) {
        var numbers: [String: Int] = [:]
        for reference in references where numbers[reference.nodeID] == nil {
            numbers[reference.nodeID] = numbers.count + 1
        }
        guard numbers != referenceNumbers else { return }
        referenceNumbers = numbers
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? FeedbackReferenceAttachment,
                  let cell = attachment.attachmentCell as? FeedbackReferenceCell else { return }
            cell.number = numbers[attachment.reference.nodeID]
        }
        layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        needsDisplay = true
    }

    private func attributedReference(_ reference: FeedbackControlReference) -> NSAttributedString {
        if referenceNumbers[reference.nodeID] == nil {
            referenceNumbers[reference.nodeID] = (referenceNumbers.values.max() ?? 0) + 1
        }
        let attachment = FeedbackReferenceAttachment(reference: reference,
            number: referenceNumbers[reference.nodeID])
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(editingAttributes, range: NSRange(location: 0, length: result.length))
        result.addAttribute(.toolTip, value: reference.label, range: NSRange(location: 0, length: result.length))
        return result
    }

    fileprivate func prepareForPicking() {
        // Resigning uses the input method's normal commit path before the canvas takes focus.
        if hasMarkedText() { window?.makeFirstResponder(nil) }
        insertionSelection = clamped(selectedRange())
        rememberSelection()
    }

    fileprivate func rememberSelection() {
        guard let feedbackID else { return }
        insertionSelection = clamped(selectedRange())
        onSelectionChange(feedbackID, insertionSelection)
    }

    fileprivate func commitMarkedText() {
        if hasMarkedText() {
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            if hasMarkedText() { unmarkText() }
        }
    }

    fileprivate func cancelMentionAndRestoreFocus() {
        suppressMentionUntilEdit = true
        updateMention(nil, range: nil)
        restoreInsertionFocus()
    }

    fileprivate func allowMentionAfterEdit() { suppressMentionUntilEdit = false }

    fileprivate func restoreInsertionFocus() {
        window?.makeFirstResponder(self)
        setSelectedRange(clamped(insertionSelection))
        rememberSelection()
        scrollRangeToVisible(selectedRange())
    }

    fileprivate func insertReference(_ reference: FeedbackControlReference, replacingMention: Bool) {
        if hasMarkedText() { window?.makeFirstResponder(nil) }
        let range = clamped(replacingMention ? (mentionRange ?? insertionSelection) : insertionSelection)
        window?.makeFirstResponder(self)
        setSelectedRange(range)
        let attachment = NSMutableAttributedString(attributedString: attributedReference(reference))
        attachment.append(NSAttributedString(string: " ", attributes: editingAttributes))
        // NSTextView's replacement API registers a native undo operation and emits the
        // ordinary delegate notification; directly mutating textStorage would not.
        breakUndoCoalescing()
        insertText(attachment, replacementRange: range)
        breakUndoCoalescing()
        typingAttributes = editingAttributes
        insertionSelection = selectedRange()
        rememberSelection()
        mentionRange = nil
        if lastMention != nil { lastMention = nil; onMention(nil) }
        scrollRangeToVisible(selectedRange())
        undoManager?.setActionName("插入控件引用")
    }

    fileprivate func didEditOrMoveSelection() {
        guard !isLoading else { return }
        rememberSelection()
        guard !hasMarkedText() else { return }
        // Moving focus to a candidate button must not discard the @ range: the
        // eventual selection replaces that range even though this view is inactive.
        guard window?.firstResponder === self else { return }
        guard !suppressMentionUntilEdit else { return }
        guard insertionSelection.length == 0 else {
            updateMention(nil, range: nil)
            return
        }
        let cursor = insertionSelection.location
        let prefix = (string as NSString).substring(to: cursor)
        // Allow “请把@保存按钮…” without inserting a space, while ordinary email
        // addresses keep their native text behavior. A chip terminates the query.
        guard let expression = try? NSRegularExpression(pattern: "(?:^|[^A-Za-z0-9._%+\\-])(@[^@\\s\\uFFFC]{0,80})$"),
              let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else {
            updateMention(nil, range: nil)
            return
        }
        let range = match.range(at: 1)
        let value = (prefix as NSString).substring(with: range)
        updateMention(String(value.dropFirst()), range: range)
    }

    private func updateMention(_ query: String?, range: NSRange?) {
        mentionRange = range
        guard query != lastMention else { return }
        lastMention = query
        onMention(query)
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let count = textStorage?.length ?? 0
        let location = min(range.location == NSNotFound ? count : range.location, count)
        return NSRange(location: location, length: min(range.length, count - location))
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.keyCode == 53 {
            suppressMentionUntilEdit = true
            updateMention(nil, range: nil)
            onCancel()
            return
        }
        if !hasMarkedText(), mentionRange != nil {
            switch event.keyCode {
            case 125: onMentionMove(1); return
            case 126: onMentionMove(-1); return
            case 36, 48:
                if onMentionAccept() { return }
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let textPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        if let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 {
            let index = layoutManager.characterIndex(for: textPoint, in: textContainer,
                                                     fractionOfDistanceBetweenInsertionPoints: nil)
            if index < storage.length,
               let attachment = storage.attribute(.attachment, at: index, effectiveRange: nil) as? FeedbackReferenceAttachment {
                let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
                if layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).contains(textPoint) {
                    window?.makeFirstResponder(self)
                    setSelectedRange(NSRange(location: index, length: 1))
                    onReferenceSelect(attachment.reference.nodeID)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, selectedRange().length > 0 else { return false }
        let text = segments(in: selectedRange()).map { segment -> String in
            switch segment {
            case .text(let text): return text
            case .control(let reference):
                let number = referenceNumbers[reference.nodeID].map { "R\($0) · " } ?? ""
                return "[\(number)\(reference.label)]"
            }
        }.joined()
        return pasteboard.setString(text, forType: .string)
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let text = pasteboard.string(forType: .string) else { return false }
        insertText(text.replacingOccurrences(of: "\u{FFFC}", with: ""), replacementRange: selectedRange())
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let placeholder = "描述想修改什么…\n输入 @ 或点选画面引用控件"
        let rect = bounds.insetBy(dx: textContainerInset.width + 5, dy: textContainerInset.height)
        placeholder.draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor])
    }
}

private final class FeedbackReferenceAttachment: NSTextAttachment {
    let reference: FeedbackControlReference

    init(reference: FeedbackControlReference, number: Int?) {
        self.reference = reference
        super.init(data: nil, ofType: nil)
        attachmentCell = FeedbackReferenceCell(label: reference.label, number: number)
    }

    required init?(coder: NSCoder) { nil }
}

private final class FeedbackReferenceCell: NSTextAttachmentCell {
    let label: String
    var number: Int?

    private var chipTitle: String {
        let compact = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = compact.isEmpty ? "未命名控件" : compact
        let clipped = display.count > 24 ? String(display.prefix(23)) + "…" : display
        return number.map { "R\($0)  \(clipped)" } ?? clipped
    }

    init(label: String, number: Int?) {
        self.label = label
        self.number = number
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cellSize() -> NSSize {
        let measured = (chipTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        return NSSize(width: min(242, ceil(measured.width) + 18), height: 23)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -5) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rect = cellFrame.insetBy(dx: 1, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.11).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (chipTitle as NSString).draw(in: rect.insetBy(dx: 6, dy: 3), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor,
            .paragraphStyle: paragraph,
        ])
    }
}
