#!/usr/bin/swift
import AppKit
import Foundation

// Reads only application identity/activation metadata. It does not activate an
// application, inspect its windows/content, or request macOS permissions.
let bundleIdentifiers = Array(CommandLine.arguments.dropFirst())
guard !bundleIdentifiers.isEmpty, bundleIdentifiers.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else {
    FileHandle.standardError.write(Data("Usage: swift frontmost-state.swift <bundle-id> [<bundle-id> ...]\n".utf8))
    exit(64)
}

func identity(_ app: NSRunningApplication) -> [String: Any] {
    ["bundleIdentifier": app.bundleIdentifier as Any? ?? NSNull(),
     "pid": app.processIdentifier,
     "name": app.localizedName as Any? ?? NSNull()]
}

var targets: [[String: Any]] = []
var visited = Set<String>()
for bundleIdentifier in bundleIdentifiers where visited.insert(bundleIdentifier).inserted {
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    if applications.isEmpty {
        targets.append(["bundleIdentifier": bundleIdentifier, "pid": NSNull(), "name": NSNull(),
                        "isActive": NSNull(), "isHidden": NSNull(), "isTerminated": NSNull(),
                        "status": "not_running"])
    }
    for app in applications {
        var target = identity(app)
        target["isActive"] = app.isActive
        target["isHidden"] = app.isHidden
        target["isTerminated"] = app.isTerminated
        target["status"] = "observed"
        targets.append(target)
    }
}
let frontmost: Any = NSWorkspace.shared.frontmostApplication.map(identity) ?? NSNull()
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let result: [String: Any] = ["observedAt": formatter.string(from: Date()),
                            "frontmost": frontmost, "targets": targets]
do {
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
} catch {
    FileHandle.standardError.write(Data("frontmost-state: \(error.localizedDescription)\n".utf8))
    exit(1)
}
