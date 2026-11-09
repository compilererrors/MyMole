import Foundation

/// Session-only approval scope for explicitly reviewed, unverified user data.
/// It grants neither ownership evidence nor permission to delete system files.
public struct ManualLeftoverReview: Sendable {
    private struct Item: Sendable {
        let file: Trasher.Identity
        let parent: Trasher.Identity
        let base: String
    }
    private let appPath: String
    private let appID: String
    private let home: String
    private let appIdentity: Trasher.Identity
    private let items: [String: Item]

    public var paths: Set<String> { Set(items.keys) }
    public func includes(_ path: String) -> Bool { items[path] != nil }

    /// Capture at discovery time, never after a queued removal has started.
    public static func capture(for app: AppBundle, home: String, leftovers: [Leftover],
                               installed: [AppBundle], identity: AppIdentity, runtimeRoots: [RuntimeLeftovers.Root] = [],
                               stop: @Sendable () -> Bool = { false }) -> Self? {
        guard !stop(), !app.isProtected, let id = app.bundleID, let stamp = Trasher.identity(of: app.path) else { return nil }
        var items: [String: Item] = [:]
        for leftover in leftovers where !leftover.canRemove {
            guard !stop() else { return nil }
            let path = leftover.path
            guard isReviewable(path, of: app, home: home, installed: installed, identity: identity, runtimeRoots: runtimeRoots),
                  let file = Trasher.identity(of: path), let parent = Trasher.identity(of: (path as NSString).deletingLastPathComponent) else { continue }
            let base = path.hasPrefix(home + "/") ? home : (path as NSString).deletingLastPathComponent
            items[path] = Item(file: file, parent: parent, base: base)
        }
        guard !stop(), !items.isEmpty else { return nil }
        return Self(appPath: app.path, appID: id, home: home, appIdentity: stamp, items: items)
    }

    public func matches(app: AppBundle, home: String, relocatedTo path: String? = nil) -> Bool {
        let location = path ?? app.path
        if path != nil {
            guard (location as NSString).deletingLastPathComponent == home + "/.Trash",
                  Trasher.noLinksBetween(home, and: location) else { return false }
        }
        return app.path == appPath && app.bundleID == appID && home == self.home
            && Trasher.identity(of: location) == appIdentity
            && AppIdentity.bundleInfo(atPath: location)?["CFBundleIdentifier"] as? String == appID
    }

    /// The original file and its containing folder must still be present.
    public func containsUnchanged(_ path: String) -> Bool {
        guard let item = items[path] else { return false }
        return Trasher.noLinksBetween(item.base, and: path) && Trasher.identity(of: path) == item.file
            && Trasher.identity(of: (path as NSString).deletingLastPathComponent) == item.parent
    }

    /// Unknown attribution is reviewable; a known competing owner is not.
    public static func isReviewable(_ path: String, of app: AppBundle, home: String, installed: [AppBundle], identity: AppIdentity,
                                    runtimeRoots: [RuntimeLeftovers.Root] = []) -> Bool {
        guard !app.isProtected, let id = app.bundleID, AppLeftovers.isWellFormed(id), !id.lowercased().hasPrefix("com.apple."),
              Trasher.isPlainPath(path), !Trasher.isProtected(path, home: home),
              !installed.contains(where: { $0.path != app.path && $0.bundleID?.caseInsensitiveCompare(id) == .orderedSame }),
              !identity.otherOwnerIDs.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }),
              !AppLeftovers.claimedByOtherApp(path, of: app, home: home, identity: identity) else { return false }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if [home + "/Library/Group Containers", home + "/Library/Application Scripts"].contains(folder), AppIdentity.isGroupID(name) {
            guard !identity.otherGroupIDs.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
            // A group inferred by name stays uncertain even after this check.
            if let key = DeepLeftovers.key(of: app), DeepLeftovers.matches(name, app: app, key: key, installed: installed) {
                return Trasher.noLinksBetween(home, and: path) && AppFinder.isRealFolder(path)
            }
        }
        // Never offer the maker's entire Library folder as a manual override.
        guard folder != home + "/Library" else { return false }
        return AppLeftovers.isStillLeftover(path, of: app, home: home, installed: installed, identity: identity, runtimeRoots: runtimeRoots)
            || AppLeftovers.isStillLeftover(path, of: app, home: home, installed: installed, identity: identity, deep: true, runtimeRoots: runtimeRoots)
    }
}
