import Darwin
import Foundation

/// A real app still in this user's Trash supplies identities missing from a
/// name-only orphan search. The bundle is evidence, never a removal target.
public struct RemovedApp: Sendable, Identifiable {
    /// Proof of the original bundle before a user moves it in Finder.
    /// Matching a name or a bundle ID alone never resumes a review.
    public struct Source: Sendable {
        private let app: AppBundle
        private let identity: Trasher.Identity
        private let parentIdentity: Trasher.Identity
        private let parentLocation: String

        public var originalIdentity: Trasher.Identity { identity }
        public var originalParentIdentity: Trasher.Identity { parentIdentity }

        public static func capture(_ app: AppBundle) -> Source? {
            let parent = (app.path as NSString).deletingLastPathComponent
            guard !app.isProtected, Trasher.isPlainPath(app.path), let identity = Trasher.identity(of: app.path),
                  let parentIdentity = Trasher.identity(of: parent), parentIdentity.type == S_IFDIR,
                  let parentLocation = Trasher.realPath(parent),
                  identity.type == S_IFDIR, let id = app.bundleID, AppLeftovers.isWellFormed(id),
                  AppIdentity.bundleInfo(atPath: app.path)?["CFBundleIdentifier"] as? String == id else { return nil }
            return Source(app: app, identity: identity, parentIdentity: parentIdentity, parentLocation: parentLocation)
        }

        public func movedToTrash(home: String) -> RemovedApp? {
            var original = stat()
            guard lstat(app.path, &original) != 0, errno == ENOENT,
                  Trasher.noLinksBetween(home, and: home + "/.Trash"),
                  let names = DirectoryListing.names(home + "/.Trash") else { return nil }
            for name in names.prefix(5_000) where name.lowercased().hasSuffix(".app") {
                let path = home + "/.Trash/" + name
                guard Trasher.identity(of: path) == identity,
                      let removed = RemovedApp.read(path: path, home: home), removed.app.bundleID == app.bundleID else { continue }
                return removed
            }
            return nil
        }

        public var isAtOriginalPath: Bool {
            originalParentIsCurrent && sameBundle(at: app.path)
        }

        /// Only the original bundle may move back, and an occupied original
        /// location always stays. A partial Finder restore can be retried from
        /// a verified location directly in the original Applications folder.
        public func canRestore(_ record: TrashRecord, from path: String, home: String) -> Bool {
            guard restoreLocationIsCurrent(path, record: record, home: home) else { return false }
            var destination = stat()
            guard lstat(app.path, &destination) != 0, errno == ENOENT else { return false }
            let parent = (app.path as NSString).deletingLastPathComponent
            if (path as NSString).deletingLastPathComponent != parent {
                let intermediate = parent + "/" + (path as NSString).lastPathComponent
                var entry = stat()
                guard lstat(intermediate, &entry) != 0, errno == ENOENT else { return false }
            }
            return true
        }

        public func restoreLocationIsCurrent(_ path: String, record: TrashRecord, home: String) -> Bool {
            guard record.original.isFileURL, record.trashed.isFileURL,
                  record.original.query == nil, record.original.fragment == nil,
                  record.trashed.query == nil, record.trashed.fragment == nil,
                  record.original.path == app.path, Trasher.isPlainPath(record.trashed.path),
                  record.trashed.deletingLastPathComponent().path == home + "/.Trash",
                  Trasher.isPlainPath(path), path.lowercased().hasSuffix(".app"),
                  !Trasher.isProtectedResolved(app.path, home: home), originalParentIsCurrent else { return false }
            let parent = (path as NSString).deletingLastPathComponent
            let originalParent = (app.path as NSString).deletingLastPathComponent
            guard parent == home + "/.Trash" || parent == originalParent,
                  Trasher.noLinksBetween(parent == originalParent ? originalParent : home, and: path) else { return false }
            return sameBundle(at: path)
        }

        private var originalParentIsCurrent: Bool {
            let parent = (app.path as NSString).deletingLastPathComponent
            return Trasher.identity(of: parent) == parentIdentity && Trasher.realPath(parent) == parentLocation
        }

        private func sameBundle(at path: String) -> Bool {
            Trasher.identity(of: path) == identity
                && AppIdentity.bundleInfo(atPath: path)?["CFBundleIdentifier"] as? String == app.bundleID
        }
    }
    public let app: AppBundle
    private let device: Int32
    private let inode: UInt64
    public var id: String { app.path }

    public static func read(path: String, home: String) -> RemovedApp? {
        guard Trasher.isPlainPath(path), (path as NSString).deletingLastPathComponent == home + "/.Trash",
              path.lowercased().hasSuffix(".app"), Trasher.noLinksBetween(home, and: path) else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              let app = AppFinder.metadata(path), let id = app.bundleID, AppLeftovers.isWellFormed(id),
              !id.lowercased().hasPrefix("com.apple."), !app.isProtected else { return nil }
        let proof = RemovedApp(app: app, device: st.st_dev, inode: st.st_ino)
        return proof.isCurrent(home: home) ? proof : nil
    }

    /// Restoring, replacing or emptying the trashed app invalidates the review.
    public func isCurrent(home: String) -> Bool {
        guard (app.path as NSString).deletingLastPathComponent == home + "/.Trash",
              Trasher.noLinksBetween(home, and: app.path) else { return false }
        var st = stat()
        guard lstat(app.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              st.st_dev == device, st.st_ino == inode else { return false }
        return AppIdentity.bundleInfo(atPath: app.path)?["CFBundleIdentifier"] as? String == app.bundleID
    }
}
