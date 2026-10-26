import AppKit
import ApplicationServices
import Foundation

public struct AXCaptureOptions: Codable {
    public var maxNodes: Int
    public var maxDepth: Int
    public var timeoutSeconds: Double
    public var maxTextCharacters: Int
    public var maxTotalTextCharacters: Int
    public init(maxNodes: Int = 12_000, maxDepth: Int = 100, timeoutSeconds: Double = 20,
                maxTextCharacters: Int = 2_000_000, maxTotalTextCharacters: Int = 8_000_000) {
        self.maxNodes = maxNodes; self.maxDepth = maxDepth; self.timeoutSeconds = timeoutSeconds
        self.maxTextCharacters = maxTextCharacters; self.maxTotalTextCharacters = maxTotalTextCharacters
    }
}

public struct AXCaptureDiagnostic: Codable {
    public var code: String
    public var message: String
    public var nodeID: String?
    public var attribute: String?
}

public struct AXTextRun: Codable {
    public var location: Int
    public var length: Int
    public var attributes: [String: String]
}

/// Each value retains its native category. Rich-text ranges use UTF-16 offsets, as AX does.
public struct AXSnapshotValue: Codable {
    public var type: String
    public var text: String?
    public var number: Double?
    public var boolean: Bool?
    public var components: [String: Double]?
    public var elements: [AXSnapshotValue]?
    public var runs: [AXTextRun]?
    public var originalCharacterCount: Int?
    public var truncated: Bool?
    public init(type: String, text: String? = nil, number: Double? = nil, boolean: Bool? = nil,
                components: [String: Double]? = nil, elements: [AXSnapshotValue]? = nil,
                runs: [AXTextRun]? = nil, originalCharacterCount: Int? = nil, truncated: Bool? = nil) {
        self.type = type; self.text = text; self.number = number; self.boolean = boolean
        self.components = components; self.elements = elements; self.runs = runs
        self.originalCharacterCount = originalCharacterCount; self.truncated = truncated
    }
}

public struct AXCapturedAttribute: Codable {
    public var status: String
    public var value: AXSnapshotValue?
    public var settable: Bool?
    public var errorCode: Int?
    public var note: String?
}

public struct AXSnapshotNode: Codable {
    public var id: String
    public var depth: Int
    /// First-discovery parent through the named traversal relations, not an inferred AXParent.
    public var parentID: String?
    public var availableAttributes: [String]
    public var parameterizedAttributes: [String]
    public var attributes: [String: AXCapturedAttribute]
    public var relations: [String: [String]]
    public var omittedAttributes: [String: String]
}

public struct AXWindowDiagnostic: Codable {
    public var index: Int
    public var title: AXCapturedAttribute
    public var position: AXCapturedAttribute
    public var size: AXCapturedAttribute
    public var bounds: CGRect?
}

public struct AXApplicationFeatureProbe: Codable {
    /// nil means AXCopyAttributeNames failed, so declaration status is unknown.
    public var declared: Bool?
    public var value: AXCapturedAttribute
    public var settable: AXCapturedAttribute
}

public struct AXReferencedWindowDiagnostic: Codable {
    /// The reference is read only for diagnostics. No handle bytes or window content are persisted.
    public var read: AXCapturedAttribute
    public var title: AXCapturedAttribute?
    public var position: AXCapturedAttribute?
    public var size: AXCapturedAttribute?
    public var bounds: CGRect?
    /// Indices from AXWindows whose handles compare equal to this reference; never fallback candidates.
    public var matchingCandidateIndices: [Int]?
}

public struct AXApplicationStateDiagnostic: Codable {
    public var observedAt: Date
    public var hidden: AXCapturedAttribute
    public var frontmost: AXCapturedAttribute
    public var focusedWindow: AXReferencedWindowDiagnostic
    public var mainWindow: AXReferencedWindowDiagnostic
}

public enum AXWindowSelectionFailureReason: String, Codable {
    case emptyWindowInventory = "empty_window_inventory"
    case windowInventoryUnavailable = "window_inventory_unavailable"
    case incompleteWindowInventory = "incomplete_window_inventory"
    case uncertainWindowMatch = "uncertain_window_match"
    case ambiguousWindowMatch = "ambiguous_window_match"
    case noMatchingWindow = "no_matching_window"
}

public struct AXApplicationDiagnosticResult: Codable {
    public var pid: Int32
    public var observedAt: Date
    public var accessibilityTrusted: Bool
    public var attributeNamesRead: AXCapturedAttribute
    public var availableAttributes: [String]
    public var windowsRead: AXCapturedAttribute
    public var windowEntryCount: Int?
    public var validWindowCount: Int
    public var candidates: [AXWindowDiagnostic]
    public var accessibilityFeatures: [String: AXApplicationFeatureProbe]
    public var inspectionAttempts: Int = 1
    public var retryHistory: [String]? = nil
    public var applicationState: AXApplicationStateDiagnostic? = nil
    public var failureReason: AXWindowSelectionFailureReason? = nil

    /// Suitable for error logs: retain matching evidence without reproducing window titles.
    public var summary: String {
        let candidateSummary = candidates.map { candidate in
            "#\(candidate.index){title=\(candidate.title.status),titleCharacters=\(candidate.title.value?.text?.count ?? 0),position=\(candidate.position.status),size=\(candidate.size.status),bounds=\(String(describing: candidate.bounds))}"
        }.joined(separator: "; ")
        let featureSummary = accessibilityFeatures.keys.sorted().map { key -> String in
            let probe = accessibilityFeatures[key]!
            let declared = probe.declared.map(String.init) ?? "unknown"
            let value = probe.value.value?.boolean.map(String.init) ?? probe.value.value.map { "type:\($0.type)" } ?? probe.value.status
            return "\(key){declared=\(declared),value=\(value),settable=\(probe.settable.value?.boolean.map(String.init) ?? probe.settable.status)}"
        }.joined(separator: "; ")
        var stateSummary = "not_recorded"
        if let state = applicationState {
            func flag(_ attribute: AXCapturedAttribute) -> String {
                "\(attribute.status):\(attribute.value?.boolean.map(String.init) ?? "unknown")"
            }
            func reference(_ window: AXReferencedWindowDiagnostic) -> String {
                "read=\(window.read.status),title=\(window.title?.status ?? "not_read"),titleCharacters=\(window.title?.value?.text?.count ?? 0),position=\(window.position?.status ?? "not_read"),size=\(window.size?.status ?? "not_read"),candidateIndices=\(String(describing: window.matchingCandidateIndices)),bounds=\(String(describing: window.bounds))"
            }
            stateSummary = "hidden=\(flag(state.hidden)),frontmost=\(flag(state.frontmost)),focusedWindow={\(reference(state.focusedWindow))},mainWindow={\(reference(state.mainWindow))}"
        }
        return "inspectionAttempts=\(inspectionAttempts); failureReason=\(failureReason?.rawValue ?? "none"); AXWindows status=\(windowsRead.status),error=\(windowsRead.errorCode.map(String.init) ?? "none"),entries=\(windowEntryCount.map(String.init) ?? "unknown"),validCandidates=\(validWindowCount); candidates=[\(candidateSummary)]; features=[\(featureSummary)]; applicationState={\(stateSummary)}"
    }
}

public struct AXCaptureResult: Codable {
    public var pid: Int32
    public var windowTitle: String?
    public var windowMatch: String
    public var rootNodeID: String
    public var focusedNodeID: String?
    public var nodes: [AXSnapshotNode]
    public var diagnostics: [AXCaptureDiagnostic]
    public var startedAt: Date
    public var finishedAt: Date
    public var durationSeconds: Double
    public var completeness: String
    public var options: AXCaptureOptions
    public var totalTextCharacters: Int
    /// Read/membership status is retained even when no target-window focus node is available.
    public var focusRead: AXCapturedAttribute? = nil
    /// Selection-time metadata, including any bounded inventory retry history, preserved on success.
    public var windowSelectionDiagnostic: AXApplicationDiagnosticResult? = nil

    public var readableText: String {
        var lines = ["AX capture: pid=\(pid), window=\(windowTitle ?? "(untitled)"), match=\(windowMatch)",
                     "Completeness: \(completeness); nodes=\(nodes.count); focus=\(focusedNodeID ?? "unavailable")"]
        if let focusRead = focusRead { lines.append("Focus read: \(focusRead.status)\(focusRead.errorCode.map { "; AX error=\($0)" } ?? "")\(focusRead.note.map { "; \($0)" } ?? "")") }
        for node in nodes {
            let indent = String(repeating: "  ", count: min(node.depth, 30))
            let role = node.attributes["AXRole"]?.value?.text ?? "unknown role"
            lines.append("\(indent)[\(node.id)] \(role)\(node.id == focusedNodeID ? " (focused)" : "")")
            for key in node.attributes.keys.sorted() {
                guard let attribute = node.attributes[key] else { continue }
                if let value = attribute.value {
                    let rendered: String
                    if let text = value.text { rendered = text }
                    else if let boolean = value.boolean { rendered = String(boolean) }
                    else if let number = value.number { rendered = String(number) }
                    else if let parts = value.components { rendered = parts.keys.sorted().map { "\($0)=\(parts[$0]!)" }.joined(separator: ", ") }
                    else if let elements = value.elements { rendered = elements.map { $0.text ?? $0.number.map { String($0) } ?? $0.type }.joined(separator: ", ") }
                    else { rendered = "(\(value.type))" }
                    lines.append("\(indent)  \(key) [\(value.type)\(attribute.settable.map { ", settable=\($0)" } ?? "")]: \(rendered)")
                    if value.truncated == true { lines.append("\(indent)    [TRUNCATED; original characters=\(value.originalCharacterCount ?? -1)]") }
                } else if attribute.status != "no_value" && attribute.status != "unsupported" {
                    lines.append("\(indent)  \(key): [\(attribute.status)] \(attribute.note ?? "")")
                }
            }
            for relation in node.relations.keys.sorted() { lines.append("\(indent)  \(relation): [\(node.relations[relation, default: []].joined(separator: ", "))]") }
            for key in node.omittedAttributes.keys.sorted() { lines.append("\(indent)  \(key): [omitted: \(node.omittedAttributes[key]!)]") }
        }
        if !diagnostics.isEmpty {
            lines.append("\nDiagnostics:")
            lines += diagnostics.map { "- \($0.code)\($0.nodeID.map { " [\($0)]" } ?? "")\($0.attribute.map { " \($0)" } ?? ""): \($0.message)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum AXCaptureError: LocalizedError {
    case permissionDenied
    case invalidOptions
    case windowsUnavailable(Int)
    case windowNotFound(String)
    case ambiguousWindow(Int)
    case windowInspectionFailed(String, AXApplicationDiagnosticResult)
    public var applicationDiagnostic: AXApplicationDiagnosticResult? {
        if case .windowInspectionFailed(_, let diagnostic) = self { return diagnostic }
        return nil
    }
    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Accessibility permission is not granted to this capture process. No permission prompt or setting change was attempted."
        case .invalidOptions: return "AX capture budgets must be positive and finite."
        case .windowsUnavailable(let code): return "Cannot read application AXWindows (AX error \(code))."
        case .windowNotFound(let details): return "Cannot match the requested screenshot window to an AX window: \(details)"
        case .ambiguousWindow(let count): return "\(count) AX windows match the request; refusing to choose an arbitrary window."
        case .windowInspectionFailed(let reason, let diagnostic): return "\(reason) \(diagnostic.summary)"
        }
    }
}

/// Passive, window-scoped AX reader. It never sets UI attributes or enables Electron accessibility.
/// A declared parameterized text API can be used without importing private frameworks.
public final class AXCollector {
    public let options: AXCaptureOptions
    private(set) var diagnostics: [AXCaptureDiagnostic] = []
    private var elements: [AXUIElement] = []
    private var buckets: [CFHashCode: [Int]] = [:]
    private var queue: [(index: Int, depth: Int, parentID: String?)] = []
    private var deadline: TimeInterval = 0
    private var textCount = 0
    private var limited = false
    private(set) var readErrors = false
    private var deadlineReported = false
    private var nodeLimitReported = false
    private var pendingReferences: [(nodeID: String, attribute: String, targets: [AXUIElement])] = []
    private var referenceCount = 0
    private let childRelations: Set<String> = ["AXChildren", "AXRows", "AXContents", "AXColumns", "AXTabs"]
    let referenceRelations: Set<String> = ["AXSelectedChildren", "AXSelectedRows", "AXSelectedCells", "AXTitleUIElement", "AXLinkedUIElements"]
    private let nonTraversedRelations: Set<String> = ["AXParent", "AXWindow", "AXTopLevelUIElement", "AXServesAsTitleForUIElements", "AXSharedTextUIElements", "AXVisibleChildren", "AXVisibleRows", "AXVisibleColumns", "AXFocusedUIElement"]
    private let fallbackAttributes = ["AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXHelp", "AXValue", "AXURL", "AXDocument", "AXIdentifier", "AXEnabled", "AXSelected", "AXExpanded", "AXFocused", "AXPosition", "AXSize", "AXSelectedText", "AXSelectedTextRange", "AXNumberOfCharacters"]
    private let secureMetadataAttributes: Set<String> = ["AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXHelp", "AXIdentifier", "AXEnabled", "AXFocused", "AXPosition", "AXSize", "AXRequired", "AXInvalid"]
    private let nonserializableTextMarkerAttributes: Set<String> = ["AXStartTextMarker", "AXEndTextMarker", "AXSelectedTextMarkerRange"]

    public init(options: AXCaptureOptions = AXCaptureOptions()) { self.options = options }
    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Passive diagnostics. It does not enable AXManualAccessibility/AXEnhancedUserInterface,
    /// request permission, traverse windows, or read editor/page contents.
    public func inspectApplication(pid: pid_t) -> AXApplicationDiagnosticResult {
        let reader = AXCollector(options: options)
        reader.deadline = ProcessInfo.processInfo.systemUptime + (options.timeoutSeconds.isFinite && options.timeoutSeconds > 0 ? options.timeoutSeconds : 5)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return reader.applicationInspection(app: app, pid: pid).result
    }

    public func capture(pid: pid_t, windowTitle: String?, windowBounds: CGRect?) throws -> AXCaptureResult {
        guard Self.isAccessibilityTrusted else { throw AXCaptureError.permissionDenied }
        guard options.maxNodes > 0, options.maxDepth > 0, options.timeoutSeconds > 0,
              options.timeoutSeconds.isFinite, options.maxTextCharacters > 0, options.maxTotalTextCharacters > 0 else { throw AXCaptureError.invalidOptions }
        diagnostics = []; elements = []; buckets = [:]; queue = []; pendingReferences = []; referenceCount = 0; textCount = 0
        limited = false; readErrors = false; deadlineReported = false; nodeLimitReported = false
        let startedAt = Date(), start = ProcessInfo.processInfo.systemUptime
        deadline = start + options.timeoutSeconds
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(min(0.25, options.timeoutSeconds)))
        let selection = try selectWindow(app: app, title: windowTitle, bounds: windowBounds)
        let root = selection.0
        let rootID = register(root, depth: 0, parentID: nil)!
        var focusedElement: AXUIElement?
        var unverifiedFocusElement: AXUIElement?
        let focusResult = elementWithStatus(app, "AXFocusedUIElement")
        var focusRead = focusResult.status
        if let focus = focusResult.element {
            if CFEqual(focus, root) {
                focusedElement = root
            } else {
                let focusWindow = elementWithStatus(focus, "AXWindow")
                if let window = focusWindow.element {
                    if CFEqual(window, root) { focusedElement = focus }
                    else {
                        focusRead.status = "outside_target_window"
                        focusRead.note = "The application's focused element belongs to a different window; its content was not collected."
                        note("focus_outside_target", focusRead.note!, attribute: "AXFocusedUIElement")
                    }
                } else {
                    unverifiedFocusElement = focus
                    focusRead.status = "window_membership_unresolved"
                    focusRead.errorCode = focusWindow.status.errorCode
                    focusRead.note = "Focused element was read, but AXWindow returned \(focusWindow.status.status). Only an existing node in the selected window's tree may resolve it."
                    note("focus_window_read_failed", focusRead.note!, attribute: "AXWindow")
                }
            }
        } else {
            note("focus_read_\(focusRead.status)", "AXFocusedUIElement returned \(focusRead.status) (AX error \(focusRead.errorCode ?? 0)).", attribute: "AXFocusedUIElement")
        }
        var nodes: [AXSnapshotNode] = []
        var cursor = 0
        var focusFallbackAttempted = false
        while budgetAvailable() {
            if cursor >= queue.count {
                if !focusFallbackAttempted, let focus = focusedElement, existingIndex(focus) == nil {
                    focusFallbackAttempted = true
                    if register(focus, depth: 0, parentID: nil) != nil {
                        note("detached_focus_node", "Focus belongs to the target window but was absent from its traversed child relations; retained separately without inventing a parent.")
                    }
                }
                if cursor >= queue.count { break }
            }
            let item = queue[cursor]; cursor += 1
            let element = elements[item.index]
            let id = identifier(item.index)
            AXUIElementSetMessagingTimeout(element, Float(min(0.25, max(0.01, deadline - ProcessInfo.processInfo.systemUptime))))
            var namesRef: CFArray?
            let namesError = AXUIElementCopyAttributeNames(element, &namesRef)
            let available = (namesRef as? [String]) ?? []
            if namesError != .success { readErrors = true; note("attribute_names_failed", "AX error \(namesError.rawValue); trying standard attributes.", node: id) }
            var parameterizedRef: CFArray?
            let parameterizedError = AXUIElementCopyParameterizedAttributeNames(element, &parameterizedRef)
            let parameterized = (parameterizedRef as? [String]) ?? []
            if parameterizedError != .success && parameterizedError != .notImplemented && parameterizedError != .attributeUnsupported {
                readErrors = true; note("parameterized_names_failed", "AX error \(parameterizedError.rawValue).", node: id)
            }
            let candidateNames = available.isEmpty ? fallbackAttributes : available
            let role = rawString(element, "AXRole")
            let subrole = rawString(element, "AXSubrole")
            let secure = subrole == "AXSecureTextField" || role == "AXSecureTextField"
            var attributes: [String: AXCapturedAttribute] = [:]
            var omitted: [String: String] = [:]
            var readNames: [String] = []
            for name in candidateNames {
                if childRelations.contains(name) || referenceRelations.contains(name) || nonTraversedRelations.contains(name) {
                    if nonTraversedRelations.contains(name) { omitted[name] = "relationship_not_expanded; tree and focus are represented separately" }
                } else if secure && !secureMetadataAttributes.contains(name) {
                    omitted[name] = "secure_text_field"
                } else { readNames.append(name) }
            }
            readNames.sort()
            if budgetAvailable() && !readNames.isEmpty {
                var valuesRef: CFArray?
                let batchError = AXUIElementCopyMultipleAttributeValues(element, readNames as CFArray, [], &valuesRef)
                if batchError == .success, let values = valuesRef as? [AnyObject], values.count == readNames.count {
                    for (index, name) in readNames.enumerated() {
                        attributes[name] = captured(values[index], node: id, attribute: name)
                    }
                } else {
                    note("attribute_batch_fallback", "Batch AX read returned \(batchError.rawValue); reading requested attributes individually.", node: id)
                    for name in readNames {
                        guard budgetAvailable() else { omitted[name] = "capture_deadline"; continue }
                        var value: CFTypeRef?
                        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                        attributes[name] = error == .success && value != nil ? captured(value!, node: id, attribute: name) : failure(error)
                    }
                }
            }
            // "settable" describes AXValue, not a blanket permission to mutate the node.
            if attributes["AXValue"]?.status == "ok", budgetAvailable() {
                var settable = DarwinBoolean(false)
                let error = AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable)
                if error == .success { attributes["AXValue"]?.settable = settable.boolValue }
                else { attributes["AXValue"]?.note = "Settable status unavailable (AX error \(error.rawValue))." }
            }
            if !secure { readParameterizedText(element, names: parameterized, node: id, attributes: &attributes) }
            for reference in referenceRelations.sorted() where available.isEmpty || available.contains(reference) {
                guard budgetAvailable() else { omitted[reference] = "capture_deadline"; continue }
                attributes[reference] = readReferenceRelation(element, attribute: reference, node: id)
            }
            var relations: [String: [String]] = [:]
            for relation in childRelations.sorted() where available.isEmpty || available.contains(relation) {
                guard budgetAvailable() else { omitted[relation] = "capture_deadline"; continue }
                var count: CFIndex = 0
                let countError = AXUIElementGetAttributeValueCount(element, relation as CFString, &count)
                var rawChildren: [AnyObject] = []
                if countError == .success {
                    let remaining = max(0, options.maxNodes - elements.count)
                    // Even when the node budget is full, allow already-seen links to be recorded
                    // within a bounded relation read. Never allocate an unbounded AX array.
                    let requested = min(count, max(remaining, min(options.maxNodes, 512)))
                    if requested > 0 {
                        var ref: CFArray?
                        let error = AXUIElementCopyAttributeValues(element, relation as CFString, 0, requested, &ref)
                        if error == .success { rawChildren = (ref as? [AnyObject]) ?? [] }
                        else { readErrors = true; note("relation_read_failed", "AX error \(error.rawValue).", node: id, attribute: relation) }
                    }
                    if requested < count { limited = true; note("relation_node_budget", "Read \(requested) of \(count) relationship entries because of the node budget.", node: id, attribute: relation) }
                } else if countError != .attributeUnsupported && countError != .noValue {
                    // AXContents can be a single element rather than an array.
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(element, relation as CFString, &value)
                    if error == .success, let value = value {
                        if CFGetTypeID(value) == AXUIElementGetTypeID() { rawChildren = [value] }
                        else { rawChildren = (value as? [AnyObject]) ?? [] }
                    } else if error != .attributeUnsupported && error != .noValue {
                        readErrors = true; note("relation_read_failed", "AX error \(error.rawValue).", node: id, attribute: relation)
                    }
                }
                var ids: [String] = []
                for raw in rawChildren where CFGetTypeID(raw) == AXUIElementGetTypeID() {
                    let child = unsafeBitCast(raw, to: AXUIElement.self)
                    if let childID = register(child, depth: item.depth + 1, parentID: id) { ids.append(childID) }
                }
                relations[relation] = ids
            }
            nodes.append(AXSnapshotNode(id: id, depth: item.depth, parentID: item.parentID,
                                        availableAttributes: available, parameterizedAttributes: parameterized,
                                        attributes: attributes, relations: relations, omittedAttributes: omitted))
        }
        let capturedIDs = Set(nodes.map(\.id))
        if focusedElement == nil, let unverified = unverifiedFocusElement,
           let index = existingIndex(unverified), capturedIDs.contains(identifier(index)) {
            focusedElement = unverified
            focusRead.status = "ok"
            focusRead.note = "Focus membership was confirmed by the selected window's traversed tree; AXWindow could not establish it."
        }
        var focusedID = focusedElement.flatMap { existingIndex($0) }.map(identifier)
        if let focus = focusedID, !capturedIDs.contains(focus) { focusedID = nil }
        if let focusedID = focusedID { focusRead.value = AXSnapshotValue(type: "element_reference", text: focusedID) }
        else if focusedElement != nil { focusRead.status = "target_focus_not_captured"; focusRead.note = "Focus belongs to the target window but its node was not captured within the budgets." }
        let nodePositions = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        for pending in pendingReferences {
            guard let position = nodePositions[pending.nodeID] else { continue }
            let resolved = resolveCapturedReferences(pending.targets, capturedIDs: capturedIDs)
            nodes[position].relations[pending.attribute] = resolved.ids
            let truncated = nodes[position].attributes[pending.attribute]?.value?.truncated
            nodes[position].attributes[pending.attribute]?.value = AXSnapshotValue(type: "element_references", elements: resolved.values, truncated: truncated)
            if resolved.unresolved > 0 {
                nodes[position].attributes[pending.attribute]?.status = "partially_resolved"
                let previous = nodes[position].attributes[pending.attribute]?.note.map { $0 + " " } ?? ""
                nodes[position].attributes[pending.attribute]?.note = previous + "\(resolved.unresolved) of \(pending.targets.count) references were not found in captured target-window nodes; they were not followed or read."
                note("unresolved_relation_members", nodes[position].attributes[pending.attribute]!.note!, node: pending.nodeID, attribute: pending.attribute)
            }
        }
        if cursor < queue.count { limited = true; note("unvisited_nodes", "\(queue.count - cursor) queued nodes were not read before capture stopped.") }
        let finishedAt = Date()
        var result = AXCaptureResult(pid: pid, windowTitle: rawString(root, "AXTitle"), windowMatch: selection.1,
                               rootNodeID: rootID, focusedNodeID: focusedID, nodes: nodes, diagnostics: diagnostics,
                               startedAt: startedAt, finishedAt: finishedAt,
                               durationSeconds: ProcessInfo.processInfo.systemUptime - start,
                               completeness: limited ? "partial_budget_limited" : (readErrors ? "partial_read_errors" : "completed_requested_reads_application_exposure_unknown"),
                               options: options, totalTextCharacters: textCount)
        result.focusRead = focusRead
        result.windowSelectionDiagnostic = selection.2
        return result
    }

    /// Resolve only after traversal: a container can expose selection handles before its rows
    /// or cells have been registered. Referenced objects never expand the captured window tree.
    func resolveCapturedReferences(_ targets: [AXUIElement], capturedIDs: Set<String>) -> (ids: [String], values: [AXSnapshotValue], unresolved: Int) {
        var ids: [String] = []
        var values: [AXSnapshotValue] = []
        var unresolved = 0
        for target in targets {
            if let index = existingIndex(target), capturedIDs.contains(identifier(index)) {
                let id = identifier(index)
                ids.append(id); values.append(AXSnapshotValue(type: "element_reference", text: id))
            } else {
                unresolved += 1
                values.append(AXSnapshotValue(type: "unresolved_element_reference", text: "not_in_captured_window_tree"))
            }
        }
        return (ids, values, unresolved)
    }

    /// Read relationship handles only. Resolution happens after traversal and never queues
    /// referenced objects, so selection/links cannot broaden capture to another window.
    private func readReferenceRelation(_ element: AXUIElement, attribute: String, node: String) -> AXCapturedAttribute {
        var count: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(element, attribute as CFString, &count)
        var rawMembers: [AnyObject] = []
        var truncated = false
        var readNote: String?
        let remaining = max(0, min(options.maxNodes, 125_000) * 8 - referenceCount)
        let cap = min(4096, remaining)
        if countError == .success {
            guard count >= 0 else {
                readErrors = true
                note("invalid_relation_count", "Provider returned a negative relationship count.", node: node, attribute: attribute)
                return AXCapturedAttribute(status: "invalid_value", value: nil, settable: nil, errorCode: nil, note: "Negative relationship count.")
            }
            let requested = min(count, cap)
            if requested > 0 {
                var values: CFArray?
                let error = AXUIElementCopyAttributeValues(element, attribute as CFString, 0, requested, &values)
                guard error == .success, let members = values as? [AnyObject] else {
                    let status = failure(error)
                    note("reference_read_failed", "Relationship read returned \(status.status) (AX error \(error.rawValue)).", node: node, attribute: attribute)
                    return status
                }
                rawMembers = members
            }
            truncated = requested < count
            readNote = "Read \(requested) of \(count) reference handles; only captured target-window members are resolved."
        } else if countError == .attributeUnsupported || countError == .noValue {
            return failure(countError)
        } else {
            // Scalar relationship attributes such as AXTitleUIElement have no array count.
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            guard error == .success, let value = value else {
                let status = failure(error)
                note("reference_read_failed", "Relationship read returned \(status.status) (AX error \(error.rawValue)).", node: node, attribute: attribute)
                return status
            }
            if CFGetTypeID(value) == AXUIElementGetTypeID() {
                if cap > 0 { rawMembers = [value] } else { truncated = true }
            } else if let values = value as? [AnyObject] {
                rawMembers = Array(values.prefix(cap)); truncated = values.count > cap
            } else {
                readErrors = true
                note("invalid_relation_value", "Relationship value was neither an element nor an element array.", node: node, attribute: attribute)
                return AXCapturedAttribute(status: "unsupported_value_type", value: nil, settable: nil, errorCode: nil, note: "Expected element reference(s).")
            }
        }
        referenceCount += rawMembers.count
        let targets = rawMembers.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { unsafeBitCast($0, to: AXUIElement.self) }
        if targets.count != rawMembers.count {
            readErrors = true
            note("invalid_relation_member", "\(rawMembers.count - targets.count) relationship members were not AX elements and could not be resolved.", node: node, attribute: attribute)
        }
        if truncated {
            limited = true
            note("reference_budget", "Relationship handles were limited to 4096 per attribute and \(min(options.maxNodes, 125_000) * 8) for the capture.", node: node, attribute: attribute)
        }
        pendingReferences.append((node, attribute, targets))
        return AXCapturedAttribute(status: truncated ? "truncated" : "ok", value: AXSnapshotValue(type: "element_references", elements: [], truncated: truncated), settable: nil, errorCode: nil, note: readNote)
    }

    private func elementWithStatus(_ element: AXUIElement, _ attribute: String) -> (element: AXUIElement?, status: AXCapturedAttribute) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value = value else { return (nil, failure(error)) }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            readErrors = true
            return (nil, AXCapturedAttribute(status: "unsupported_value_type", value: nil, settable: nil, errorCode: nil, note: "Expected an AX element reference."))
        }
        return (unsafeBitCast(value, to: AXUIElement.self), AXCapturedAttribute(status: "ok", value: nil, settable: nil, errorCode: nil, note: nil))
    }

    private func applicationInspection(app: AXUIElement, pid: pid_t) -> (result: AXApplicationDiagnosticResult, windows: [(AXUIElement, AXWindowDiagnostic)]) {
        guard budgetAvailable() else {
            let skipped = AXCapturedAttribute(status: "capture_deadline", value: nil, settable: nil, errorCode: nil, note: "Read was not started after the original capture/inspection deadline.")
            let result = AXApplicationDiagnosticResult(pid: pid, observedAt: Date(), accessibilityTrusted: Self.isAccessibilityTrusted,
                attributeNamesRead: skipped, availableAttributes: [], windowsRead: skipped, windowEntryCount: nil,
                validWindowCount: 0, candidates: [], accessibilityFeatures: [:])
            return (result, [])
        }
        var namesRef: CFArray?
        let namesError = AXUIElementCopyAttributeNames(app, &namesRef)
        let names = (namesRef as? [String]) ?? []
        let namesRead: AXCapturedAttribute
        if namesError == .success, namesRef != nil {
            namesRead = AXCapturedAttribute(status: "ok", value: AXSnapshotValue(type: "attribute_name_count", number: Double(names.count)), settable: nil, errorCode: 0, note: nil)
        } else { namesRead = failure(namesError) }
        var features: [String: AXApplicationFeatureProbe] = [:]
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            guard namesError == .success, namesRef != nil else {
                let skipped = AXCapturedAttribute(status: "not_probed_declaration_unknown", value: nil, settable: nil, errorCode: Int(namesError.rawValue), note: "AXCopyAttributeNames did not establish whether this attribute is declared.")
                features[name] = AXApplicationFeatureProbe(declared: nil, value: skipped, settable: skipped)
                continue
            }
            guard names.contains(name) else {
                let skipped = AXCapturedAttribute(status: "not_declared", value: nil, settable: nil, errorCode: nil, note: "Attribute was absent from the provider's declared attributes; no value/settable probe was attempted.")
                features[name] = AXApplicationFeatureProbe(declared: false, value: skipped, settable: skipped)
                continue
            }
            let value = diagnosticAttribute(app, attribute: name)
            guard budgetAvailable() else {
                features[name] = AXApplicationFeatureProbe(declared: true, value: value,
                    settable: AXCapturedAttribute(status: "capture_deadline", value: nil, settable: nil, errorCode: nil, note: "Settable probe not started after deadline."))
                continue
            }
            var isSettable = DarwinBoolean(false)
            let settableError = AXUIElementIsAttributeSettable(app, name as CFString, &isSettable)
            let settable = settableError == .success
                ? AXCapturedAttribute(status: "ok", value: AXSnapshotValue(type: "boolean", boolean: isSettable.boolValue), settable: nil, errorCode: 0, note: "Read-only capability probe; no AX value was set.")
                : failure(settableError)
            features[name] = AXApplicationFeatureProbe(declared: true, value: value, settable: settable)
        }
        var value: CFTypeRef?
        let mayReadWindows = budgetAvailable()
        let windowsError = mayReadWindows ? AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value) : AXError.cannotComplete
        var windowsRead: AXCapturedAttribute
        var entryCount: Int?
        var validCount = 0
        var windows: [(AXUIElement, AXWindowDiagnostic)] = []
        if !mayReadWindows { windowsRead = AXCapturedAttribute(status: "capture_deadline", value: nil, settable: nil, errorCode: nil, note: "AXWindows read was not started after deadline.") }
        else if windowsError != .success { windowsRead = failure(windowsError) }
        else if let objects = value as? [AnyObject] {
            entryCount = objects.count
            let candidates = objects.enumerated().filter { CFGetTypeID($0.element) == AXUIElementGetTypeID() }
            validCount = candidates.count
            windowsRead = AXCapturedAttribute(status: "ok", value: AXSnapshotValue(type: "window_reference_count", number: Double(objects.count)), settable: nil, errorCode: 0,
                note: validCount == objects.count ? nil : "\(objects.count - validCount) AXWindows entries were not AX element references.")
            if candidates.count > 128 {
                windowsRead.note = (windowsRead.note.map { $0 + " " } ?? "") + "Only the first 128 AX window candidates were inspected; matching refuses an incomplete candidate inventory."
            }
            for candidate in candidates.prefix(128) {
                guard budgetAvailable() else {
                    windowsRead.note = (windowsRead.note.map { $0 + " " } ?? "") + "Candidate metadata inspection stopped at the original deadline."
                    break
                }
                let window = unsafeBitCast(candidate.element, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(window, 0.25)
                let title = diagnosticAttribute(window, attribute: "AXTitle")
                let position = diagnosticAttribute(window, attribute: "AXPosition")
                let size = diagnosticAttribute(window, attribute: "AXSize")
                let bounds: CGRect?
                if let x = position.value?.components?["x"], let y = position.value?.components?["y"],
                   let width = size.value?.components?["width"], let height = size.value?.components?["height"] {
                    bounds = CGRect(x: x, y: y, width: width, height: height)
                } else { bounds = nil }
                windows.append((window, AXWindowDiagnostic(index: candidate.offset, title: title, position: position, size: size, bounds: bounds)))
            }
        } else {
            windowsRead = AXCapturedAttribute(status: value == nil ? "empty_result" : "invalid_value_type", value: nil, settable: nil, errorCode: 0, note: "AXWindows succeeded without an element array; this is distinct from an empty window array.")
        }
        var result = AXApplicationDiagnosticResult(pid: pid, observedAt: Date(), accessibilityTrusted: Self.isAccessibilityTrusted,
            attributeNamesRead: namesRead, availableAttributes: names, windowsRead: windowsRead,
            windowEntryCount: entryCount, validWindowCount: validCount, candidates: windows.map { $0.1 }, accessibilityFeatures: features)
        // This follows the inventory so optional diagnostic reads cannot consume the budget
        // before the requested window candidates are inspected. Every read checks the same
        // original deadline and records capture_deadline if it could not be started.
        result.applicationState = AXApplicationStateDiagnostic(observedAt: Date(),
            hidden: diagnosticAttribute(app, attribute: "AXHidden"),
            frontmost: diagnosticAttribute(app, attribute: "AXFrontmost"),
            focusedWindow: diagnosticWindowReference(app, attribute: "AXFocusedWindow", candidates: windows),
            mainWindow: diagnosticWindowReference(app, attribute: "AXMainWindow", candidates: windows))
        return (result, windows)
    }

    private func diagnosticWindowReference(_ app: AXUIElement, attribute: String,
                                           candidates: [(AXUIElement, AXWindowDiagnostic)]) -> AXReferencedWindowDiagnostic {
        guard budgetAvailable() else {
            return AXReferencedWindowDiagnostic(read: AXCapturedAttribute(status: "capture_deadline", value: nil,
                settable: nil, errorCode: nil, note: "Window reference read was not started after the original deadline."))
        }
        let reference = elementWithStatus(app, attribute)
        var result = AXReferencedWindowDiagnostic(read: reference.status)
        guard let window = reference.element else { return result }
        result.read.note = "AX window reference was read for metadata only; it is not a fallback capture target."
        result.matchingCandidateIndices = candidates.compactMap { CFEqual($0.0, window) ? $0.1.index : nil }
        AXUIElementSetMessagingTimeout(window, 0.25)
        result.title = diagnosticAttribute(window, attribute: "AXTitle")
        result.position = diagnosticAttribute(window, attribute: "AXPosition")
        result.size = diagnosticAttribute(window, attribute: "AXSize")
        if let x = result.position?.value?.components?["x"], let y = result.position?.value?.components?["y"],
           let width = result.size?.value?.components?["width"], let height = result.size?.value?.components?["height"] {
            result.bounds = CGRect(x: x, y: y, width: width, height: height)
        }
        return result
    }

    private func diagnosticAttribute(_ element: AXUIElement, attribute: String) -> AXCapturedAttribute {
        guard budgetAvailable() else { return AXCapturedAttribute(status: "capture_deadline", value: nil, settable: nil, errorCode: nil, note: "Attribute read was not started after deadline.") }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if error == .success, let value = value { return captured(value, node: "application_diagnostic", attribute: attribute) }
        return failure(error)
    }

    private func selectWindow(app: AXUIElement, title: String?, bounds: CGRect?) throws -> (AXUIElement, String, AXApplicationDiagnosticResult) {
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        var inspection = applicationInspection(app: app, pid: pid)
        if Self.shouldRetryWindowInspection(inspection.result), deadline - ProcessInfo.processInfo.systemUptime > 0.05 {
            let initialSummary = inspection.result.summary
            note("window_inspection_retry", "Retrying window inventory once within the original capture deadline after a transient/empty result. \(initialSummary)")
            Thread.sleep(forTimeInterval: 0.05)
            if budgetAvailable() {
                inspection = applicationInspection(app: app, pid: pid)
                inspection.result.inspectionAttempts = 2
                inspection.result.retryHistory = [initialSummary, inspection.result.summary]
                note("window_inspection_retry_result", inspection.result.summary)
            }
        }
        let diagnostic = inspection.result
        func failed(_ reason: AXWindowSelectionFailureReason, _ message: String) -> AXCaptureError {
            var evidence = diagnostic
            evidence.failureReason = reason
            return .windowInspectionFailed(message, evidence)
        }
        if let reason = Self.windowInventoryFailureReason(diagnostic) {
            switch reason {
            case .emptyWindowInventory:
                throw failed(reason, "AXWindows succeeded but returned an empty window inventory.")
            case .incompleteWindowInventory:
                throw failed(reason, "AX window candidate inventory was incomplete or contained invalid references; refusing incomplete matching.")
            default:
                throw failed(reason, "Cannot read a usable AX window inventory.")
            }
        }
        let windows = inspection.windows
        if title == nil && bounds == nil {
            if let focused = rawElement(app, "AXFocusedWindow"), windows.contains(where: { CFEqual($0.0, focused) }) { return (focused, "focused_window", diagnostic) }
            if windows.count == 1 { return (windows[0].0, "single_window", diagnostic) }
            throw failed(.ambiguousWindowMatch, "No unique focused/single AX window could be selected.")
        }
        let assessment = Self.assessWindowMatches(windows.map { $0.1 }, title: title, bounds: bounds)
        if let index = assessment.uniqueMatchIndex {
            if bounds != nil {
                let candidate = windows[index].1
                if let title, candidate.title.status == "ok", candidate.title.value?.type == "string",
                   candidate.title.value?.truncated != true, let actual = candidate.title.value?.text {
                    if actual != title {
                        note("window_title_differs", "CG and AX titles differ. The window was selected by unique bounds; titles are retained in their original metadata fields.", attribute: "AXTitle")
                    }
                } else {
                    note("window_title_unavailable", "CG or AX title was unavailable or incomplete. The window was selected by unique bounds; title availability did not decide selection.", attribute: "AXTitle")
                }
                return (windows[index].0, "unique_bounds_within_3_points", diagnostic)
            }
            return (windows[index].0, "exact_title", diagnostic)
        }
        if !assessment.cannotExclude.isEmpty {
            throw failed(.uncertainWindowMatch, "\(assessment.matches.count) AX windows matched, but \(assessment.cannotExclude.count) other candidates could not be excluded because matching metadata was unavailable; refusing an uncertain choice.")
        }
        if assessment.matches.count > 1 { throw failed(.ambiguousWindowMatch, "\(assessment.matches.count) AX windows matched; refusing an arbitrary choice.") }
        throw failed(.noMatchingWindow, bounds != nil
            ? "No AX window matched requested bounds \(String(describing: bounds))."
            : "No AX window matched requested title (\(title?.count ?? 0) characters).")
    }

    /// An empty successful array is different from a failed/nil/malformed AXWindows read.
    static func windowInventoryFailureReason(_ diagnostic: AXApplicationDiagnosticResult) -> AXWindowSelectionFailureReason? {
        guard diagnostic.windowsRead.status == "ok", let count = diagnostic.windowEntryCount else { return .windowInventoryUnavailable }
        if count == 0 { return .emptyWindowInventory }
        if count != diagnostic.validWindowCount || diagnostic.validWindowCount != diagnostic.candidates.count { return .incompleteWindowInventory }
        return nil
    }

    struct WindowMatchAssessment {
        /// Array offsets, not provider window identifiers.
        var matches: [Int] = []
        var cannotExclude: [Int] = []
        var uniqueMatchIndex: Int? { matches.count == 1 && cannotExclude.isEmpty ? matches[0] : nil }
    }

    /// Geometry identifies the selected window within this application's AX inventory.
    /// Titles are provider-specific display text and cannot exclude a geometric candidate.
    /// An unavailable geometry component is unknown; another valid differing component
    /// can still rule the candidate out. Without bounds, retain exact title-only matching.
    static func assessWindowMatches(_ candidates: [AXWindowDiagnostic], title: String?, bounds: CGRect?) -> WindowMatchAssessment {
        var result = WindowMatchAssessment()
        if let bounds {
            guard [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height].allSatisfy(\.isFinite),
                  bounds.size.width > 0, bounds.size.height > 0 else {
                result.cannotExclude = Array(candidates.indices)
                return result
            }
        } else if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            result.cannotExclude = Array(candidates.indices)
            return result
        }
        for (index, candidate) in candidates.enumerated() {
            var unknown = false
            var differs = false
            if let expected = bounds {
                let components: [(AXCapturedAttribute, String, String, Double)] = [
                    (candidate.position, "point", "x", expected.origin.x),
                    (candidate.position, "point", "y", expected.origin.y),
                    (candidate.size, "size", "width", expected.width),
                    (candidate.size, "size", "height", expected.height)
                ]
                for (attribute, type, key, expectedValue) in components {
                    if attribute.status == "ok", attribute.value?.type == type,
                       attribute.value?.truncated != true,
                       let actual = attribute.value?.components?[key], actual.isFinite,
                       (key != "width" && key != "height") || actual > 0 {
                        if abs(actual - expectedValue) > 3 { differs = true }
                    } else { unknown = true }
                }
            } else if let expected = title {
                if candidate.title.status == "ok", candidate.title.value?.type == "string",
                   candidate.title.value?.truncated != true, let actual = candidate.title.value?.text {
                    differs = actual != expected
                } else { unknown = true }
            }
            if differs { continue }
            if unknown { result.cannotExclude.append(index) }
            else { result.matches.append(index) }
        }
        return result
    }

    static func shouldRetryWindowInspection(_ diagnostic: AXApplicationDiagnosticResult) -> Bool {
        if diagnostic.windowsRead.status == "cannot_complete" || diagnostic.windowsRead.status == "no_value" { return true }
        if diagnostic.windowsRead.status == "ok", diagnostic.windowEntryCount == 0 { return true }
        return diagnostic.candidates.contains { candidate in
            [candidate.title, candidate.position, candidate.size].contains { $0.status == "cannot_complete" }
        }
    }

    private func readParameterizedText(_ element: AXUIElement, names: [String], node: String,
                                       attributes: inout [String: AXCapturedAttribute]) {
        guard budgetAvailable(), textCount < options.maxTotalTextCharacters else { return }
        // AX providers advertise these names. Opaque text markers are only passed back to
        // the same provider; no private text-marker symbols or injected code are used.
        if names.contains("AXTextMarkerRangeForUIElement") && names.contains("AXAttributedStringForTextMarkerRange") {
            var marker: CFTypeRef?
            let rangeError = AXUIElementCopyParameterizedAttributeValue(element, "AXTextMarkerRangeForUIElement" as CFString, element, &marker)
            if rangeError == .success, let marker = marker, budgetAvailable() {
                var text: CFTypeRef?
                let error = AXUIElementCopyParameterizedAttributeValue(element, "AXAttributedStringForTextMarkerRange" as CFString, marker, &text)
                attributes["AXAttributedStringForTextMarkerRange"] = error == .success && text != nil ? captured(text!, node: node, attribute: "AXAttributedStringForTextMarkerRange") : failure(error)
            } else {
                attributes["AXTextMarkerRangeForUIElement"] = failure(rangeError)
            }
        }
        guard names.contains("AXAttributedStringForRange"), budgetAvailable(), textCount < options.maxTotalTextCharacters,
              let count = attributes["AXNumberOfCharacters"]?.value?.number, count > 0, count.isFinite else { return }
        let maxCount = min(count, Double(options.maxTextCharacters), Double(options.maxTotalTextCharacters - textCount), Double(Int.max / 2))
        var range = CFRange(location: 0, length: Int(maxCount))
        guard let parameter = AXValueCreate(.cfRange, &range) else { return }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, "AXAttributedStringForRange" as CFString, parameter, &value)
        let key = "AXAttributedStringForRange"
        attributes[key] = error == .success && value != nil ? captured(value!, node: node, attribute: key) : failure(error)
        attributes[key]?.note = "Requested UTF-16 range 0..<\(range.length) of AXNumberOfCharacters=\(count)."
        if maxCount < count { limited = true; note("parameterized_text_range_limited", "Requested \(range.length) of \(count) UTF-16 units because of text budget.", node: node, attribute: key) }
    }

    func captured(_ raw: CFTypeRef, node: String, attribute: String) -> AXCapturedAttribute {
        if CFGetTypeID(raw) == AXValueGetTypeID() {
            let value = unsafeBitCast(raw, to: AXValue.self)
            if AXValueGetType(value) == .axError {
                var error = AXError.success
                if AXValueGetValue(value, .axError, &error) { return failure(error) }
            }
        }
        let value = serializeValue(raw, node: node, attribute: attribute)
        let unsupported = value.type == "unsupported" || value.type == "unsupported_ax_value"
        if unsupported { readErrors = true; note("unsupported_value_type", value.text ?? value.type, node: node, attribute: attribute) }
        let status = unsupported ? "unsupported_value_type" : (value.type == "invalid" ? "invalid_value" : (value.type == "opaque" ? "nonserializable" : "ok"))
        let explanation = value.type == "opaque" ? "Provider-owned text marker handle. Presence is recorded; its process-local bytes/address are deliberately not serialized. This is not a content read failure." : nil
        return AXCapturedAttribute(status: status, value: value, settable: nil, errorCode: nil, note: explanation)
    }

    /// Internal serializer is independently testable without a running application or AX permission.
    func serializeValue(_ raw: CFTypeRef, node: String, attribute: String, nesting: Int = 0) -> AXSnapshotValue {
        guard nesting < 8 else { limited = true; note("attribute_nesting_limit", "Nested attribute exceeded 8 levels.", node: node, attribute: attribute); return AXSnapshotValue(type: "omitted_nested_value") }
        if let rich = raw as? NSAttributedString {
            var output = boundedText(rich.string, type: "attributed_text", node: node, attribute: attribute)
            let keptLength = (output.text ?? "").utf16.count
            var runs: [AXTextRun] = []
            var runsWereTruncated = false
            if keptLength > 0 {
                rich.enumerateAttributes(in: NSRange(location: 0, length: min(keptLength, rich.length)), options: []) { attributes, range, stop in
                    guard runs.count < 10_000 else { runsWereTruncated = true; stop.pointee = true; return }
                    var strings: [String: String] = [:]
                    if attributes.count > 128 { self.limited = true; self.note("rich_text_attribute_count_limit", "Retained at most 128 metadata fields for a rich-text run.", node: node, attribute: attribute) }
                    for key in attributes.keys.sorted(by: { $0.rawValue < $1.rawValue }).prefix(128) {
                        guard let value = attributes[key] else { continue }
                        let metadata: String
                        if let font = value as? NSFont { metadata = "\(font.fontName), \(font.pointSize)pt" }
                        else if let url = value as? URL { metadata = url.absoluteString }
                        else if let text = value as? String { metadata = text }
                        else if let number = value as? NSNumber { metadata = number.stringValue }
                        else if let color = value as? NSColor, let rgb = color.usingColorSpace(.sRGB) { metadata = "rgba(\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent),\(rgb.alphaComponent))" }
                        else { metadata = "[unsupported run attribute: \(String(describing: type(of: value)))]" }
                        if metadata.count > 4096 { self.limited = true; self.note("rich_text_metadata_length_limit", "Run metadata \(key.rawValue) was limited to 4096 characters from \(metadata.count).", node: node, attribute: attribute) }
                        strings[key.rawValue] = self.boundedText(String(metadata.prefix(4096)), type: "string", node: node, attribute: "\(attribute).runs.\(key.rawValue)").text ?? ""
                    }
                    runs.append(AXTextRun(location: range.location, length: range.length, attributes: strings))
                }
                if runsWereTruncated { limited = true; note("rich_text_run_limit", "Retained at most 10000 attributed-text runs.", node: node, attribute: attribute) }
            }
            output.runs = runs
            return output
        }
        let typeID = CFGetTypeID(raw)
        if typeID == CFBooleanGetTypeID() { return AXSnapshotValue(type: "boolean", boolean: (raw as? NSNumber)?.boolValue) }
        if let url = raw as? URL { return boundedText(url.absoluteString, type: "url", node: node, attribute: attribute) }
        if let text = raw as? String { return boundedText(text, type: "string", node: node, attribute: attribute) }
        if let number = raw as? NSNumber {
            let n = number.doubleValue
            guard n.isFinite else { return AXSnapshotValue(type: "nonfinite_number", text: number.stringValue) }
            let floating = CFNumberIsFloatType(unsafeBitCast(number, to: CFNumber.self))
            // Exact integer text prevents loss of integers larger than Double's precision.
            return AXSnapshotValue(type: floating ? "float" : "integer", text: floating ? nil : number.stringValue, number: n)
        }
        if typeID == AXValueGetTypeID() {
            let value = unsafeBitCast(raw, to: AXValue.self)
            switch AXValueGetType(value) {
            case .cgPoint:
                var point = CGPoint.zero
                guard AXValueGetValue(value, .cgPoint, &point) else { return invalidValue("Cannot decode AX point.", node: node, attribute: attribute) }
                return geometry(type: "point", components: ["x": point.x, "y": point.y], node: node, attribute: attribute)
            case .cgSize:
                var size = CGSize.zero
                guard AXValueGetValue(value, .cgSize, &size) else { return invalidValue("Cannot decode AX size.", node: node, attribute: attribute) }
                return geometry(type: "size", components: ["width": size.width, "height": size.height], node: node, attribute: attribute)
            case .cgRect:
                var rect = CGRect.zero
                guard AXValueGetValue(value, .cgRect, &rect) else { return invalidValue("Cannot decode AX rect.", node: node, attribute: attribute) }
                return geometry(type: "rect", components: ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height], node: node, attribute: attribute)
            case .cfRange:
                var range = CFRange()
                guard AXValueGetValue(value, .cfRange, &range) else { return invalidValue("Cannot decode AX range.", node: node, attribute: attribute) }
                return AXSnapshotValue(type: "range", components: ["location": Double(range.location), "length": Double(range.length)])
            default: return AXSnapshotValue(type: "unsupported_ax_value", text: "AXValue type \(AXValueGetType(value).rawValue)")
            }
        }
        if typeID == AXUIElementGetTypeID() {
            let element = unsafeBitCast(raw, to: AXUIElement.self)
            return AXSnapshotValue(type: "element_reference", text: existingIndex(element).map(identifier) ?? "outside_collected_tree")
        }
        if let array = raw as? [AnyObject] {
            let cap = min(array.count, 4096)
            if cap < array.count { limited = true; note("attribute_array_limit", "Retained \(cap) of \(array.count) attribute entries.", node: node, attribute: attribute) }
            return AXSnapshotValue(type: "array", elements: array.prefix(cap).map { serializeValue($0, node: node, attribute: attribute, nesting: nesting + 1) }, truncated: cap < array.count)
        }
        if nonserializableTextMarkerAttributes.contains(attribute) {
            return AXSnapshotValue(type: "opaque", text: "provider_owned_text_marker")
        }
        return AXSnapshotValue(type: "unsupported", text: "CFTypeID=\(typeID); Swift type=\(String(describing: type(of: raw)))")
    }

    private func geometry(type: String, components: [String: Double], node: String, attribute: String) -> AXSnapshotValue {
        guard components.values.allSatisfy(\.isFinite) else { return invalidValue("AX \(type) contains non-finite coordinates: \(components).", node: node, attribute: attribute) }
        return AXSnapshotValue(type: type, components: components)
    }
    private func invalidValue(_ reason: String, node: String, attribute: String) -> AXSnapshotValue {
        readErrors = true; note("invalid_attribute_value", reason, node: node, attribute: attribute)
        return AXSnapshotValue(type: "invalid", text: reason)
    }

    private func boundedText(_ text: String, type: String, node: String, attribute: String) -> AXSnapshotValue {
        let original = text.count
        let allowed = min(original, options.maxTextCharacters, max(0, options.maxTotalTextCharacters - textCount))
        textCount += allowed
        let truncated = allowed < original
        if truncated { limited = true; note("text_budget", "Retained \(allowed) of \(original) characters; per-attribute or total text budget reached.", node: node, attribute: attribute) }
        return AXSnapshotValue(type: type, text: truncated ? String(text.prefix(allowed)) : text,
                               originalCharacterCount: original, truncated: truncated)
    }

    private func failure(_ error: AXError) -> AXCapturedAttribute {
        let status: String
        switch error {
        case .noValue: status = "no_value"
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented: status = "unsupported"
        case .cannotComplete: status = "cannot_complete"
        case .invalidUIElement: status = "invalid_element"
        case .apiDisabled: status = "api_disabled"
        case .success: status = "empty_result"
        default: status = "read_error"
        }
        if status != "no_value" && status != "unsupported" && status != "empty_result" { readErrors = true }
        return AXCapturedAttribute(status: status, value: nil, settable: nil, errorCode: Int(error.rawValue), note: nil)
    }

    func register(_ element: AXUIElement, depth: Int, parentID: String?) -> String? {
        if let index = existingIndex(element) { return identifier(index) }
        guard depth <= options.maxDepth else { limited = true; note("depth_limit", "A child exceeded depth \(options.maxDepth).", node: parentID); return nil }
        guard elements.count < options.maxNodes else {
            limited = true
            if !nodeLimitReported { nodeLimitReported = true; note("node_limit", "Reached the \(options.maxNodes)-node capture budget; additional elements were omitted.", node: parentID) }
            return nil
        }
        let index = elements.count
        elements.append(element); buckets[CFHash(element), default: []].append(index)
        queue.append((index, depth, parentID))
        return identifier(index)
    }
    private func existingIndex(_ element: AXUIElement) -> Int? {
        (buckets[CFHash(element)] ?? []).first { CFEqual(elements[$0], element) }
    }
    private func identifier(_ index: Int) -> String { "n\(index + 1)" }
    private func budgetAvailable() -> Bool {
        if ProcessInfo.processInfo.systemUptime < deadline { return true }
        limited = true
        if !deadlineReported { note("capture_deadline", "AX capture exceeded its \(options.timeoutSeconds)-second work budget; an in-flight AX call can finish after this deadline."); deadlineReported = true }
        return false
    }
    private func note(_ code: String, _ message: String, node: String? = nil, attribute: String? = nil) {
        // Prevent diagnostics from becoming an unbounded secondary payload.
        if diagnostics.count < 10_000 { diagnostics.append(AXCaptureDiagnostic(code: code, message: message, nodeID: node, attribute: attribute)) }
        else if diagnostics.count == 10_000 { diagnostics.append(AXCaptureDiagnostic(code: "diagnostics_limit", message: "Further diagnostics omitted after 10000 entries.", nodeID: nil, attribute: nil)); limited = true }
    }
    private func rawElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func rawString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private func rawBounds(_ element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &s) == .success,
              let p = p, let s = s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
