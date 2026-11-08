import Darwin
import Foundation

/// A real app still in this user's Trash supplies identities missing from a
/// name-only orphan search. The bundle is evidence, never a removal target.
public struct RemovedApp: Sendable, Identifiable {
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
