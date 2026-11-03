import Foundation
import Security

/// Everything an app answers to besides its own bundle ID, read from the
/// bundle itself: the helpers, login items, services and extensions it
/// carries, the launchd jobs it registers, and the app groups its signature
/// claims. Leftovers named after any of them are the app's too.
public struct AppIdentity: Sendable, Equatable {
    /// Bundle IDs and launchd labels of what the app carries, in the app's
    /// own namespace ("com.vendor."), never the app's own ID.
    public var helperIDs: [String] = []
    /// App group IDs from the app's entitlements.
    public var groups: [String] = []

    public init(helperIDs: [String] = [], groups: [String] = []) {
        self.helperIDs = helperIDs
        self.groups = groups
    }

    /// Where an app keeps code with identities of its own.
    static let bundleFolders = [
        "Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/XPCServices", "Contents/PlugIns",
        "Contents/Helpers", "Contents/Library/Helpers",
    ]
    static let jobFolders = ["Contents/Library/LaunchDaemons", "Contents/Library/LaunchAgents"]

    /// The vendor part of a bundle ID ("com.vendor."). An identity outside
    /// it, such as an updater framework's own services that many apps carry,
    /// is shared and never taken as this app's.
    public static func namespace(of id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".") + "."
    }

    /// Every identity the bundle at `path` carries, whatever its namespace:
    /// helpers, login items, services, extensions and launchd labels.
    public static func carried(atPath path: String) -> Set<String> {
        var found = Set<String>()
        for folder in bundleFolders {
            let dir = path + "/" + folder
            for name in AppFinder.contents(dir) {
                let p = dir + "/" + name
                if let inner = NSDictionary(contentsOfFile: p + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String {
                    found.insert(inner)
                } else if let inner = NSDictionary(contentsOfFile: p + "/Info.plist")?["CFBundleIdentifier"] as? String {
                    found.insert(inner)
                } else if folder == "Contents/Library/LaunchServices" {
                    // A blessed helper is a bare program named by its label.
                    found.insert(name)
                }
            }
        }
        for folder in jobFolders {
            let dir = path + "/" + folder
            for name in AppFinder.contents(dir) where name.hasSuffix(".plist") {
                if let label = NSDictionary(contentsOfFile: dir + "/" + name)?["Label"] as? String { found.insert(label) }
            }
        }
        return found.filter(AppLeftovers.isWellFormed)
    }

    /// What `app` carries. Apple's identities and the app's own are left out.
    public static func of(_ app: AppBundle) -> AppIdentity {
        guard let id = app.bundleID, let space = namespace(of: id) else { return AppIdentity() }
        let found = carried(atPath: app.path)
        let helpers = found.filter { $0 != id && $0.hasPrefix(space) && !$0.hasPrefix("com.apple.") && AppLeftovers.isWellFormed($0) }
        let groups = entitlementGroups(app.path).filter { !$0.hasPrefix("com.apple.") && isGroupID($0) }
        return AppIdentity(helperIDs: helpers.sorted(), groups: groups.sorted())
    }

    /// `identity` without what another installed app also answers to: a
    /// helper, login item or job another app carries too (a shared updater,
    /// say) or that's named under another app's ID, and app groups another
    /// app of the same vendor claims. Those are theirs as much as this app's;
    /// a shared vendor prefix proves nothing about who owns them.
    public static func owned(_ identity: AppIdentity, of app: AppBundle, installed: [AppBundle]) -> AppIdentity {
        let others = installed.filter { $0.path != app.path }
        var helpers = identity.helperIDs
        if !helpers.isEmpty {
            let otherIDs = Set(others.compactMap(\.bundleID))
            let carried = Set(others.flatMap { carried(atPath: $0.path) })
            helpers = helpers.filter { h in
                !carried.contains(h) && !otherIDs.contains { o in h == o || h.hasPrefix(o + ".") }
            }
        }
        var groups = identity.groups
        if !groups.isEmpty, let space = app.bundleID.flatMap(namespace) {
            let claimed = Set(others.filter { $0.bundleID?.hasPrefix(space) ?? false }.flatMap { entitlementGroups($0.path) })
            groups = groups.filter { !claimed.contains($0) }
        }
        return AppIdentity(helperIDs: helpers, groups: groups)
    }

    /// "group.com.vendor.Shared" or "TEAMID1234.com.vendor.Shared".
    static func isGroupID(_ g: String) -> Bool {
        if g.hasPrefix("group.") { return AppLeftovers.isWellFormed(String(g.dropFirst("group.".count))) }
        let parts = g.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return AppLeftovers.isWellFormed(String(parts[1]))
    }

    /// The app groups the app's signature claims, or none when it can't be read.
    static func entitlementGroups(_ path: String) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any], let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return ents["com.apple.security.application-groups"] as? [String] ?? []
    }
}
