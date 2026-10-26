import Darwin
import Foundation
import Security

/// Local diagnostic evidence for the process that checks or requests capture access.
/// Signature inspection is best effort and never determines whether permission is granted.
public struct CaptureCallerIdentity: Codable, Equatable {
    public let bundleIdentifier: String
    public let bundlePath: String
    public let processID: Int32
    public let codeSigningIdentifier: String
    public let codeSigningCDHash: String
    public let codeSigningRequirement: String

    public static func current() -> Self {
        var identifier = "unknown"
        var cdHash = "unknown"
        var requirementText = "unknown"
        var code: SecCode?
        var staticCode: SecStaticCode?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            var information: CFDictionary?
            if SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
               let information = information as? [String: Any] {
                if let value = information[kSecCodeInfoIdentifier as String] as? String, !value.isEmpty {
                    identifier = value
                }
                if let data = information[kSecCodeInfoUnique as String] as? Data, !data.isEmpty {
                    cdHash = data.map { String(format: "%02x", $0) }.joined()
                }
            }
            var requirement: SecRequirement?
            if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
               let requirement {
                var text: CFString?
                if SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
                   let value = text as String?, !value.isEmpty {
                    requirementText = value
                }
            }
        }
        return Self(bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
                    bundlePath: Bundle.main.bundleURL.path,
                    processID: getpid(), codeSigningIdentifier: identifier,
                    codeSigningCDHash: cdHash, codeSigningRequirement: requirementText)
    }

    /// Keep doctor compatible with consumers that decode its entire JSON as string values.
    public var doctorFields: [String: String] {
        ["bundleIdentifier": bundleIdentifier, "bundlePath": bundlePath,
         "processID": String(processID), "codeSigningIdentifier": codeSigningIdentifier,
         "codeSigningCDHash": codeSigningCDHash, "codeSigningRequirement": codeSigningRequirement]
    }
}
