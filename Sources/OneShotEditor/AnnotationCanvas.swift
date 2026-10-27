import AppKit
import SwiftUI
import OneShotCore

enum EditorTool: String, CaseIterable, Identifiable {
    case select, element, number, arrow, rectangle, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return "选择"
        case .element: return "元素"
        case .number: return "编号"
        case .arrow: return "箭头"
        case .rectangle: return "方框"
        case .text: return "文字"
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .element: return "viewfinder"
        case .number: return "1.circle"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .text: return "textformat"
        }
    }
}

/// Owns its scroll view. zoom=1 fits the original image inside the available viewport.
struct AnnotationCanvas: NSViewRepresentable {
    var image: NSImage
    var document: AnnotationDocument
    var tool: EditorTool
    var selectedID: UUID?
    var colorHex: String = "#EF4444"
    var strokeWidth: Double = 4
    var zoom: Double = 1
    var onSelect: (UUID?) -> Void
    var onChange: ([AnnotationItem]) -> Void
    var onDelete: () -> Void = {}
    var elementIndex: CapturedElementIndex? = nil
    var highlightedElementID: String? = nil
    var onElementSelect: (String) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var canUndo: Bool = true
    var canRedo: Bool = true
    var isPickingReference: Bool = false
    var onReferencePick: (String) -> Void = { _ in }
    var onCancelReferencePick: () -> Void = {}
    var onFeedbackReferenceSelect: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> AnnotationScrollView {
        let scroll = AnnotationScrollView()
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: AnnotationScrollView, context: Context) {
        scroll.canvas.configure(from: self)
        scroll.zoom = CGFloat(zoom)
        scroll.needsLayout = true
    }
}

final class AnnotationScrollView: NSScrollView {
    let canvas = AnnotationDrawingView()
    var zoom: CGFloat = 1

    init() {
        super.init(frame: .zero)
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = canvas
        setAccessibilityLabel("截图标注画布")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let size = canvas.imageSize
        guard size.width > 0, size.height > 0 else { return }
        let fit = min(1, min(max(1, viewport.width - 48) / size.width,
                             max(1, viewport.height - 48) / size.height))
        let scale = fit * min(8, max(0.25, zoom))
        let extent = CGSize(width: max(viewport.width, size.width * scale + 48),
                            height: max(viewport.height, size.height * scale + 48))
        if canvas.frame.size != extent { canvas.setFrameSize(extent) }
        canvas.imageRect = CGRect(x: (extent.width - size.width * scale) / 2,
                                  y: (extent.height - size.height * scale) / 2,
                                  width: size.width * scale, height: size.height * scale)
        canvas.scale = scale
        canvas.needsDisplay = true
    }
}

final class AnnotationDrawingView: NSView, NSUserInterfaceValidations {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var image: NSImage?
    private var document: AnnotationDocument?
    private var tool: EditorTool = .select
    private var selectedID: UUID?
    private var colorHex = "#EF4444"
    private var strokeWidth: Double = 4
    private var onSelect: (UUID?) -> Void = { _ in }
    private var onChange: ([AnnotationItem]) -> Void = { _ in }
    private var onDelete: () -> Void = {}
    private var onUndo: () -> Void = {}
    private var onRedo: () -> Void = {}
    private var canUndo = true
    private var canRedo = true
    private var elementIndex: CapturedElementIndex?
    private var highlightedElementID: String?
    private var hoveredElementID: String?
    private var onElementSelect: (String) -> Void = { _ in }
    private var isPickingReference = false
    private var onReferencePick: (String) -> Void = { _ in }
    private var onCancelReferencePick: () -> Void = {}
    private var onFeedbackReferenceSelect: (String) -> Void = { _ in }
    private var hoverTrackingArea: NSTrackingArea?
    private var localMouseMonitor: Any?
    private var drag: Drag?
    private var previewItems: [AnnotationItem]?
    var imageRect: CGRect = .zero
    var scale: CGFloat = 1
    var imageSize: CGSize {
        guard let document else { return .zero }
        return CGSize(width: document.imageWidth, height: document.imageHeight)
    }

    private struct Drag {
        var origin: CGPoint
        var initialItems: [AnnotationItem]
        var index: Int
        var isNew: Bool
    }

    func configure(from configuration: AnnotationCanvas) {
        if document?.id != configuration.document.id || tool != configuration.tool || isPickingReference != configuration.isPickingReference {
            hoveredElementID = nil
            toolTip = nil
        }
        if document?.id != configuration.document.id || document?.items != configuration.document.items {
            drag = nil
            previewItems = nil
        }
        image = configuration.image
        document = configuration.document
        tool = configuration.tool
        selectedID = configuration.selectedID
        colorHex = configuration.colorHex
        strokeWidth = configuration.strokeWidth
        onSelect = configuration.onSelect
        onChange = configuration.onChange
        onDelete = configuration.onDelete
        onUndo = configuration.onUndo
        onRedo = configuration.onRedo
        canUndo = configuration.canUndo
        canRedo = configuration.canRedo
        elementIndex = configuration.elementIndex
        highlightedElementID = configuration.highlightedElementID
        onElementSelect = configuration.onElementSelect
        isPickingReference = configuration.isPickingReference
        onReferencePick = configuration.onReferencePick
        onCancelReferencePick = configuration.onCancelReferencePick
        onFeedbackReferenceSelect = configuration.onFeedbackReferenceSelect
        clearHoverIfMouseOutside()
        setAccessibilityRole(.image)
        setAccessibilityLabel("截图标注画布，\(configuration.document.items.count) 个标注")
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: tool == .select && !isPickingReference ? .arrow : .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        localMouseMonitor = nil
        guard window != nil else { clearHover(); return }
        window?.acceptsMouseMovedEvents = true
        // A SwiftUI sidebar may receive the next click without a tracking-area exit callback.
        // Observe only this app's events, return them unchanged, and check the clip viewport.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.window {
                self.clearHover()
            } else {
                self.clearHoverIfMouseOutside()
            }
            return event
        }
    }

    deinit {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { updateHoveredElement(event) }
    override func mouseEntered(with event: NSEvent) { updateHoveredElement(event) }
    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    private func clearHover() {
        guard hoveredElementID != nil || toolTip != nil else { return }
        hoveredElementID = nil
        toolTip = nil
        needsDisplay = true
    }

    private func clearHoverIfMouseOutside() {
        guard hoveredElementID != nil, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !visibleRect.contains(point) || !imageRect.contains(point) || !window.isKeyWindow {
            clearHover()
        }
    }

    private func updateHoveredElement(_ event: NSEvent) {
        guard tool == .element || isPickingReference else { return }
        let element = imagePoint(for: event, clamp: false).flatMap {
            elementIndex?.hitTest(point: AnnotationPoint(x: $0.x, y: $0.y))
        }
        guard hoveredElementID != element?.id else { return }
        hoveredElementID = element?.id
        toolTip = element.map { "\($0.role) · \(String($0.label.prefix(200)))" }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        clearHoverIfMouseOutside()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        dirtyRect.fill()
        guard let image, let document, imageRect.width > 0 else { return }
        NSColor.white.setFill()
        imageRect.fill()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: imageRect.minX, byY: imageRect.minY)
        var scaled = transform
        scaled.scale(scale)
        (scaled as NSAffineTransform).concat()
        let items = previewItems ?? document.items
        AnnotationRenderer.draw(items: items, imageSize: imageSize)
        if let elementIndex {
            AnnotationRenderer.drawFeedbackReferences(document: document, elementIndex: elementIndex,
                imageSize: imageSize, scale: scale, highlightedNodeID: highlightedElementID)
        }
        if let selected = items.first(where: { $0.id == selectedID }),
           selected.kind != .element || (selected.start.x != selected.end.x && selected.start.y != selected.end.y) {
            let selection = AnnotationRenderer.bounds(for: selected, imageSize: imageSize)
                .insetBy(dx: -6 / scale, dy: -6 / scale)
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 1.5 / scale
            path.setLineDash([5 / scale, 4 / scale], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if let id = highlightedElementID,
           id != (tool == .element || isPickingReference ? hoveredElementID : nil),
           (tool == .element || isPickingReference || !document.feedbackControlReferences.contains(where: { $0.nodeID == id })),
           let element = elementIndex?.element(id: id) {
            drawElementHighlight(element, showLabel: hoveredElementID == nil)
        }
        if tool == .element || isPickingReference, let id = hoveredElementID, let element = elementIndex?.element(id: id) {
            drawElementHighlight(element, showLabel: true)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawElementHighlight(_ element: CapturedElement, showLabel: Bool) {
        guard let bounds = element.imageBounds, bounds.width > 0, bounds.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: CGRect(origin: .zero, size: imageSize)).addClip()
        let rect = bounds.cgRect
        NSColor.systemBlue.withAlphaComponent(0.10).setFill()
        NSBezierPath(rect: rect).fill()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2 / scale
        NSColor.systemBlue.setStroke()
        border.stroke()
        guard showLabel else { return }
        let label = (element.label.isEmpty ? "未命名控件" : String(element.label.prefix(70))) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 / scale, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let measured = label.size(withAttributes: attributes)
        let padding = 6 / scale
        let width = min(imageSize.width, measured.width + padding * 2)
        let height = measured.height + padding * 2
        let y = rect.minY >= height ? rect.minY - height : min(rect.minY, imageSize.height - height)
        let labelRect = CGRect(x: min(rect.minX, imageSize.width - width), y: max(0, y), width: width, height: height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 3 / scale, yRadius: 3 / scale).fill()
        label.draw(in: labelRect.insetBy(dx: padding, dy: padding), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if isPickingReference {
            guard let point = imagePoint(for: event, clamp: false),
                  let element = elementIndex?.hitTest(point: AnnotationPoint(x: point.x, y: point.y)) else { return }
            onReferencePick(element.id)
            clearHover()
            return
        }
        window?.makeFirstResponder(self)
        guard let document, let point = imagePoint(for: event, clamp: false) else { return }
        var items = document.items
        if tool == .element {
            guard let element = elementIndex?.hitTest(point: AnnotationPoint(x: point.x, y: point.y)) else { return }
            hoveredElementID = element.id
            onElementSelect(element.id)
            needsDisplay = true
            return
        }
        if tool == .select {
            if let reference = feedbackReference(at: point, badgesOnly: true) {
                onFeedbackReferenceSelect(reference)
                return
            }
            let hit = items.indices.reversed().first {
                AnnotationRenderer.hitTest(point, item: items[$0], imageSize: imageSize, tolerance: 8 / scale)
            }
            if hit == nil, let reference = feedbackReference(at: point, badgesOnly: false) {
                onFeedbackReferenceSelect(reference)
                return
            }
            selectedID = hit.map { items[$0].id }
            drag = hit.flatMap {
                items[$0].kind == .element ? nil : Drag(origin: point, initialItems: items, index: $0, isNew: false)
            }
            onSelect(selectedID)
            needsDisplay = true
            return
        }
        guard items.count < 1000, let kind = AnnotationKind(rawValue: tool.rawValue) else { return }
        let nextNumber = min(9999, (items.filter { $0.kind == .number || $0.kind == .element }.map(\.number).max() ?? 0) + 1)
        var item = AnnotationItem(kind: kind, start: AnnotationPoint(x: point.x, y: point.y),
                                  end: AnnotationPoint(x: point.x, y: point.y),
                                  text: kind == .text ? "文字说明" : "", colorHex: colorHex,
                                  strokeWidth: strokeWidth, number: nextNumber)
        item = moved(item, dx: 0, dy: 0)
        selectedID = item.id
        items.append(item)
        if kind == .number || kind == .text {
            onChange(items)
            onSelect(item.id)
        } else {
            drag = Drag(origin: point, initialItems: items, index: items.count - 1, isNew: true)
            previewItems = items
            onSelect(item.id)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let point = imagePoint(for: event, clamp: true) else { return }
        var items = drag.initialItems
        if drag.isNew {
            items[drag.index].end = AnnotationPoint(x: point.x, y: point.y)
        } else {
            items[drag.index] = moved(items[drag.index], dx: point.x - drag.origin.x, dy: point.y - drag.origin.y)
        }
        previewItems = items
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        mouseDragged(with: event)
        let result = previewItems ?? drag.initialItems
        self.drag = nil
        previewItems = nil
        if drag.isNew {
            let item = result[drag.index]
            let distance = hypot(item.end.x - item.start.x, item.end.y - item.start.y) * scale
            if distance < 4 || (item.kind == .rectangle &&
                (abs(item.end.x - item.start.x) * scale < 3 || abs(item.end.y - item.start.y) * scale < 3)) {
                selectedID = nil
                onSelect(nil)
                needsDisplay = true
                return
            }
        }
        if result != document?.items { onChange(result) }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            if selectedID != nil { onDelete() }
        } else if event.keyCode == 53 {
            if isPickingReference { onCancelReferencePick(); clearHover(); return }
            drag = nil
            previewItems = nil
            selectedID = nil
            onSelect(nil)
            needsDisplay = true
        } else { super.keyDown(with: event) }
    }

    private func feedbackReference(at point: CGPoint, badgesOnly: Bool) -> String? {
        guard let document, let elementIndex else { return nil }
        for (offset, reference) in document.feedbackControlReferences.enumerated().reversed() {
            guard let bounds = elementIndex.element(id: reference.nodeID)?.imageBounds else { continue }
            let marker = AnnotationRenderer.feedbackReferenceBadgeBounds(number: offset + 1,
                elementBounds: bounds, imageSize: imageSize, scale: scale)
            if marker.contains(point) || (!badgesOnly && bounds.cgRect.contains(point)) { return reference.nodeID }
        }
        return nil
    }

    // These actions participate only while the canvas is in the responder chain. Native
    // text fields keep their own undo manager when the inspector has keyboard focus.
    @objc func undo(_ sender: Any?) { if canUndo { onUndo() } }
    @objc func redo(_ sender: Any?) { if canRedo { onRedo() } }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return canUndo }
        if item.action == #selector(redo(_:)) { return canRedo }
        return true
    }

    private func imagePoint(for event: NSEvent, clamp: Bool) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.width > 0, clamp || imageRect.contains(point) else { return nil }
        return CGPoint(x: min(imageSize.width, max(0, (point.x - imageRect.minX) / scale)),
                       y: min(imageSize.height, max(0, (point.y - imageRect.minY) / scale)))
    }

    private func moved(_ item: AnnotationItem, dx requestedX: CGFloat, dy requestedY: CGFloat) -> AnnotationItem {
        let rect = AnnotationRenderer.bounds(for: item, imageSize: imageSize)
        let dx = min(imageSize.width - rect.maxX, max(-rect.minX, requestedX))
        let dy = min(imageSize.height - rect.maxY, max(-rect.minY, requestedY))
        var moved = item
        // The model's anchor coordinates stay inside the original image even for oversized text.
        moved.start.x = min(imageSize.width, max(0, item.start.x + dx))
        moved.start.y = min(imageSize.height, max(0, item.start.y + dy))
        moved.end.x = min(imageSize.width, max(0, item.end.x + dx))
        moved.end.y = min(imageSize.height, max(0, item.end.y + dy))
        return moved
    }
}
