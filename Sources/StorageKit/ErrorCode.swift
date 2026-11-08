import Foundation

/// A short code for an error, made to be copied into a support request.
/// It's built only from where the error happened and the error's domains and
/// numbers, never from its message or details, so it can't carry a name or
/// a path: "MM-KEEP-C512.P13".
public struct ErrorCode: Hashable, Sendable, CustomStringConvertible {
    public enum Area: String, Sendable, CaseIterable {
        case keepList = "KEEP"
        case projectRules = "RULES"
        case folderAccess = "ACCESS"
        case systemClean = "SYS"
        case maintenance = "MAINT"
        case uninstall = "UNINST"
    }

    public let area: Area
    /// The error's domain and number, then its underlying errors', at most three.
    public let reason: String

    public init(_ area: Area, _ error: any Error) {
        self.area = area
        var parts: [String] = []
        var next: NSError? = error as NSError
        while let e = next, parts.count < 3 {
            parts.append(Self.domain(e.domain) + String(e.code))
            next = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        reason = parts.joined(separator: ".")
    }

    public var description: String { "MM-\(area.rawValue)-\(reason)" }

    /// Apple's common domains as one letter, and MyMole's own error types
    /// by name without the module: "PrivilegedClientFailure", and
    /// "FileLockFailure" for a type inside another. Any other domain is named
    /// by someone else and could hold anything, so only a checksum of it is kept.
    static func domain(_ name: String) -> String {
        switch name {
        case NSPOSIXErrorDomain: return "P"
        case NSCocoaErrorDomain: return "C"
        case NSOSStatusErrorDomain: return "S"
        case NSURLErrorDomain: return "U"
        case NSMachErrorDomain: return "M"
        default: break
        }
        let parts = name.split(separator: ".")
        if parts.count >= 2, ownModules.contains(String(parts[0])),
            parts.dropFirst().allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
        {
            return String(parts.dropFirst().suffix(2).joined().prefix(40))
        }
        // FNV-1a: the same on every run and Mac, unlike `hashValue`.
        let sum = name.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return "X" + String(sum, radix: 16, uppercase: true)
    }

    static let ownModules: Set<String> = ["MyMole", "StorageKit", "SystemKit", "PrivilegedKit", "MyMoleHelper"]
}
