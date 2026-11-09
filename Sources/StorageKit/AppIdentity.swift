import Darwin
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
    /// Bundle and helper IDs claimed by other installed apps. These must
    /// survive every fallback match, including vendor and deeper searches.
    public var otherOwnerIDs: [String] = []
    /// Known competing signed group claims, including read-only discovery.
    public var otherGroupIDs: [String] = []

    public init(helperIDs: [String] = [], groups: [String] = [], otherOwnerIDs: [String] = [], otherGroupIDs: [String] = []) {
        self.helperIDs = helperIDs
        self.groups = groups
        self.otherOwnerIDs = otherOwnerIDs
        self.otherGroupIDs = otherGroupIDs
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

    /// A missing optional folder is empty; unreadable or malformed metadata is unknown.
    public static func carried(atPath path: String) -> Set<String>? { contents(atPath: path)?.ids }

    private struct Contents {
        let ids: Set<String>
        let code: [String]
    }

    private static func contents(atPath path: String) -> Contents? {
        var found = Set<String>()
        var code = Set<String>()
        var remaining = 10_000
        var visited = Set<String>()
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        func canonical(_ item: String) -> String? {
            let resolved = URL(fileURLWithPath: item).resolvingSymlinksInPath().path
            guard resolved == root || resolved.hasPrefix(root + "/"),
                  Trasher.noLinksBetween(root, and: resolved) else { return nil }
            return resolved
        }
        func names(_ directory: String) -> [String]? {
            guard let names = DirectoryListing.names(directory) else { return nil }
            remaining -= names.count
            return remaining >= 0 ? names : nil
        }
        func inspect(_ item: String, depth: Int, launchService: Bool = false) -> Bool {
            guard depth <= 8, let item = canonical(item) else { return false }
            guard visited.insert(item).inserted else { return true }
            var st = stat()
            guard lstat(item, &st) == 0 else { return false }
            if st.st_mode & S_IFMT == S_IFREG {
                if st.st_mode & 0o111 != 0 { code.insert(item) }
                let name = (item as NSString).lastPathComponent
                if launchService, AppLeftovers.isWellFormed(name) { found.insert(name) }
                return true
            }
            guard st.st_mode & S_IFMT == S_IFDIR else { return false }
            var identified = false
            for relative in ["Contents/Info.plist", "Info.plist", "Resources/Info.plist"] {
                let candidate = item + "/" + relative
                var infoStat = stat()
                if lstat(candidate, &infoStat) != 0 {
                    guard errno == ENOENT || errno == ENOTDIR else { return false }
                    continue
                }
                guard let file = canonical(candidate), case .value(let info) = readPlist(file, within: root) else { return false }
                // Storyboards and language plug-ins also use Info.plist,
                // without declaring a code identity. Still inspect their children.
                guard let value = info["CFBundleIdentifier"] else { continue }
                guard let id = value as? String, AppLeftovers.isWellFormed(id) else { return false }
                found.insert(id)
                identified = true
                code.insert(item)
                break
            }
            let ext = (item as NSString).pathExtension.lowercased()
            // A claimed bundle with broken/missing metadata is unknown. A
            // plain plug-in container is traversed instead of treated as an error.
            if ["app", "xpc", "appex", "framework", "bundle"].contains(ext), !identified { return false }
            if identified, FileManager.default.fileExists(atPath: item + "/Contents") {
                return visit(item, depth: depth)
            }
            guard let entries = names(item) else { return false }
            for name in entries {
                guard inspect(item + "/" + name, depth: depth + 1) else { return false }
            }
            return true
        }
        func visit(_ bundle: String, depth: Int) -> Bool {
            guard depth <= 8 else { return false }
            code.insert(bundle)
            for folder in bundleFolders {
                let dir = bundle + "/" + folder
                guard let entries = identityNames(in: folder, bundle: bundle) else { return false }
                remaining -= entries.count
                guard remaining >= 0 else { return false }
                for name in entries {
                    guard inspect(dir + "/" + name, depth: depth + 1,
                                  launchService: folder == "Contents/Library/LaunchServices") else { return false }
                }
            }
            for folder in jobFolders {
                let dir = bundle + "/" + folder
                guard let entries = identityNames(in: folder, bundle: bundle) else { return false }
                remaining -= entries.count
                guard remaining >= 0 else { return false }
                for name in entries where name.hasSuffix(".plist") {
                    guard case .value(let info) = readPlist(dir + "/" + name, within: bundle),
                          let label = info["Label"] as? String, AppLeftovers.isWellFormed(label) else { return false }
                    found.insert(label)
                }
            }
            return true
        }
        guard Trasher.noLinksBetween(path, and: path), visit(path, depth: 0) else { return nil }
        return Contents(ids: found, code: code.sorted())
    }

    /// Include groups claimed by nested apps, services and executable helpers.
    public static func groupClaims(_ path: String, reader: (String) -> [String]? = AppIdentity.entitlementGroups) -> [String]? {
        guard let tree = contents(atPath: path) else { return nil }
        var groups = Set<String>()
        for code in tree.code {
            guard let claims = reader(code) else { return nil }
            groups.formUnion(claims)
        }
        return groups.sorted()
    }

    /// Readers are injected for synthetic unsigned bundles and read-failure tests.
    public struct Readers: Sendable {
        public var carried: @Sendable (String) -> Set<String>?
        public var groups: @Sendable (String) -> [String]?

        public init(
            carried: @escaping @Sendable (String) -> Set<String>? = AppIdentity.carried,
            groups: @escaping @Sendable (String) -> [String]? = { AppIdentity.groupClaims($0) }
        ) {
            self.carried = carried
            self.groups = groups
        }
        public static let live = Readers()
    }

    /// What the app carries, or nil when ownership cannot be established.
    public static func of(_ app: AppBundle, readers: Readers = .live) -> AppIdentity? {
        guard let id = app.bundleID, let space = namespace(of: id) else { return nil }
        guard let found = readers.carried(app.path), let groups = readers.groups(app.path) else { return nil }
        let helpers = found.filter { $0 != id && $0.hasPrefix(space) && !$0.hasPrefix("com.apple.") && AppLeftovers.isWellFormed($0) }
        return AppIdentity(helperIDs: helpers.sorted(), groups: groups.filter(isRemovableGroup).sorted())
    }

    /// Shared identities stay. An unknown competing owner is never an empty set.
    public static func owned(_ identity: AppIdentity, of app: AppBundle, installed: [AppBundle], readers: Readers = .live) -> AppIdentity? {
        let others = installed.filter { $0.path != app.path }
        var helpers = identity.helperIDs
        var groups = identity.groups
        guard others.allSatisfy({ $0.bundleID != nil }) else { return nil }
        let otherIDs = Set(others.compactMap(\.bundleID))
        var carried = Set<String>()
        for other in others {
            guard let ids = readers.carried(other.path) else { return nil }
            carried.formUnion(ids)
        }
        if !helpers.isEmpty {
            let claimed = Set(carried.map { $0.lowercased() })
            helpers = helpers.filter { h in
                let h = h.lowercased()
                return !claimed.contains(h) && !otherIDs.contains { o in h == o.lowercased() || h.hasPrefix(o.lowercased() + ".") }
            }
        }
        var claimed = Set<String>()
        if !groups.isEmpty {
            // Bundle prefixes can differ while apps still share an app group.
            for other in others {
                guard let ids = readers.groups(other.path) else { return nil }
                claimed.formUnion(ids)
            }
            let folded = Set(claimed.map { $0.lowercased() })
            groups = groups.filter { !folded.contains($0.lowercased()) }
        }
        return AppIdentity(helperIDs: helpers, groups: groups, otherOwnerIDs: carried.union(otherIDs).sorted(), otherGroupIDs: claimed.sorted())
    }

    public static func owned(for app: AppBundle, installed: [AppBundle], readers: Readers = .live) -> AppIdentity? {
        guard let identity = of(app, readers: readers) else { return nil }
        return owned(identity, of: app, installed: installed, readers: readers)
    }

    /// Partial evidence for read-only discovery. It grants no ownership or
    /// removal permission; known competing claims still exclude matches.
    public static func possible(for app: AppBundle, installed: [AppBundle], readers: Readers = .live) -> AppIdentity {
        let others = installed.filter { $0.path != app.path }
        let carried = Set(others.flatMap { readers.carried($0.path) ?? [] })
        let otherIDs = carried.union(others.compactMap(\.bundleID))
        let claimedGroups = Set(others.flatMap { readers.groups($0.path) ?? [] }.map { $0.lowercased() })
        let space = app.bundleID.flatMap(namespace)
        let helpers = (readers.carried(app.path) ?? []).filter { id in
            guard let space else { return false }
            return id != app.bundleID && id.hasPrefix(space) && !id.hasPrefix("com.apple.") && AppLeftovers.isWellFormed(id)
                && !otherIDs.contains { id.caseInsensitiveCompare($0) == .orderedSame }
        }
        let groups = (readers.groups(app.path) ?? []).filter {
            isRemovableGroup($0) && !claimedGroups.contains($0.lowercased())
        }
        return AppIdentity(helperIDs: helpers.sorted(), groups: groups.sorted(), otherOwnerIDs: otherIDs.sorted(), otherGroupIDs: claimedGroups.sorted())
    }

    private static func identityNames(in folder: String, bundle: String) -> [String]? {
        var path = bundle
        for (index, part) in ([""] + folder.split(separator: "/").map(String.init)).enumerated() {
            if !part.isEmpty { path += "/" + part }
            var st = stat()
            guard lstat(path, &st) == 0 else { return index > 0 && errno == ENOENT ? [] : nil }
            guard st.st_mode & S_IFMT == S_IFDIR else { return nil }
        }
        return DirectoryListing.names(path)
    }

    private enum Plist {
        case missing, invalid
        case value([String: Any])
    }

    /// Shared bounded reader for the primary bundle identity and display metadata.
    public static func bundleInfo(atPath path: String) -> [String: Any]? {
        guard case .value(let info) = readPlist(path + "/Contents/Info.plist", within: path) else { return nil }
        return info
    }

    private static func readPlist(_ path: String, within root: String) -> Plist {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .invalid }
        defer { close(fd) }
        let parent = (path as NSString).deletingLastPathComponent
        guard Trasher.noLinksBetween(root, and: parent) else { return .invalid }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size > 0, before.st_size <= 1_048_576
        else { return .invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 1_048_577), data.count == before.st_size,
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .invalid }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            Trasher.noLinksBetween(root, and: parent)
        else { return .invalid }
        return .value(info)
    }

    private static func isRemovableGroup(_ id: String) -> Bool {
        guard isGroupID(id) else { return false }
        let name = id.hasPrefix("group.") ? String(id.dropFirst(6)) : String(id.dropFirst(11))
        return !name.lowercased().hasPrefix("com.apple.")
    }

    /// "group.com.vendor.Shared" or "TEAMID1234.com.vendor.Shared".
    static func isGroupID(_ g: String) -> Bool {
        if g.hasPrefix("group.") { return AppLeftovers.isWellFormed(String(g.dropFirst("group.".count))) }
        let parts = g.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return AppLeftovers.isWellFormed(String(parts[1]))
    }

    /// An unsigned program has no signed groups. Every other read error is unknown.
    public static func entitlementGroups(_ path: String) -> [String]? {
        var code: SecStaticCode?
        let creation = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        if creation == errSecCSUnsigned { return [] }
        guard creation == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let result = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        if result == errSecCSUnsigned { return [] }
        guard result == errSecSuccess, let dict = info as? [String: Any] else { return nil }
        return signedGroups(dict)
    }

    static func signedGroups(_ info: [String: Any]) -> [String]? {
        guard let value = info[kSecCodeInfoEntitlementsDict as String] else { return [] }
        guard let entitlements = value as? [String: Any] else { return nil }
        guard let value = entitlements["com.apple.security.application-groups"] else { return [] }
        guard let groups = value as? [String], groups.count <= 4_096,
            groups.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 && !$0.contains("\0") })
        else { return nil }
        // Preserve other identifier formats for ownership comparison. Only
        // supported, non-Apple IDs can later become removal candidates.
        return groups
    }
}
