#if !APPSTORE
import Foundation
import Security

/// Only the existing, versioned JSON contract crosses the privileged boundary.
@objc public protocol HelperServiceProtocol {
    func perform(_ argument: String, reply: @escaping (String) -> Void)
    func status(reply: @escaping (String) -> Void)
}

public struct HelperServiceIdentity: Sendable, Equatable {
    public let appID: String
    public let teamID: String
    public var serviceID: String { appID + ".helper" }
    public var plistName: String { serviceID + ".plist" }

    public init?(appID: String, teamID: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !appID.isEmpty, appID.utf8.count <= 255, appID.unicodeScalars.allSatisfy(allowed.contains),
              teamID.count == 10, teamID.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { return nil }
        self.appID = appID; self.teamID = teamID
    }

    /// Require Developer ID, the same signing team, the exact code identifier,
    /// and no debugger entitlement. XPC checks the running peer on every message.
    public func requirement(helper: Bool) -> String {
        "anchor apple generic and identifier \"\(helper ? serviceID : appID)\""
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and !entitlement[\"com.apple.security.get-task-allow\"] exists"
    }

    /// Ad-hoc, test and App Store signatures cannot register this root service.
    public static func current(helper: Bool) -> Self? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !helper || identifier.hasSuffix(".helper"),
              let identity = Self(appID: helper ? String(identifier.dropLast(".helper".count)) : identifier, teamID: team)
        else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(identity.requirement(helper: helper) as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return nil }
        return identity
    }

    public static func acceptsUser(_ uid: uid_t, consoleUID: uid_t?) -> Bool {
        uid >= 501 && consoleUID == uid
    }

    public static func acceptsRequest(_ argument: String, uid: uid_t) -> Bool {
        guard argument.utf8.count <= 1_048_576, let data = Data(base64Encoded: argument),
              let envelope = try? JSONDecoder().decode(PrivilegedEnvelope.self, from: data),
              envelope.version == PrivilegedTool.version else { return false }
        if case .applicationTrash(let request, _) = envelope.request { return request.uid == uid }
        return true
    }
}
#endif
