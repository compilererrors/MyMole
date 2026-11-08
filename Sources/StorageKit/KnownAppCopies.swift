import Darwin
import Foundation
import Synchronization

/// Discovered paths survive pane changes for this session. Every ownership
/// decision rereads them; discovery never supplies cached deletion approval.
public final class KnownAppCopies: Sendable {
    private let paths = Mutex(Set<String>())
    public init() {}

    public func remember(_ apps: [AppBundle]) { paths.withLock { $0.formUnion(apps.map(\.path)) } }

    /// A present app with unreadable metadata is an unknown owner, not an
    /// absent copy. Keep its path so later removal checks fail closed too.
    public func rememberUnreadable(_ candidates: [String]) {
        paths.withLock { $0.formUnion(candidates.filter { Trasher.isPlainPath($0) && $0.lowercased().hasSuffix(".app") }) }
    }

    public func adding(to inventory: [AppBundle]) -> [AppBundle]? {
        var result = inventory
        var seen = Set(inventory.map(\.path))
        for path in paths.withLock({ $0.sorted() }) where !seen.contains(path) {
            guard Trasher.isPlainPath(path) else { return nil }
            var st = stat()
            if lstat(path, &st) != 0 {
                if errno == ENOENT || errno == ENOTDIR { continue }
                return nil
            }
            guard st.st_mode & S_IFMT == S_IFDIR, URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
                  let app = AppFinder.metadata(path), let id = app.bundleID, AppLeftovers.isWellFormed(id) else { return nil }
            result.append(app)
            seen.insert(path)
        }
        return result
    }
}
