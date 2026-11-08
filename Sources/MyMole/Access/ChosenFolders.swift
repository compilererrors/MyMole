import Foundation

/// Folders and disks the user chose in a folder panel for a pane to search
/// (Duplicates, Installers), kept open across launches. In the App Sandbox
/// a folder outside the home folder can only be read when chosen there, so
/// each is kept as a security-scoped bookmark, renewed when macOS says
/// it's stale, and closed when the user stops using it. Outside the
/// sandbox nothing needs keeping.
@MainActor
final class ChosenFolders {
    static let shared = ChosenFolders()

    private let key = "access.chosenFolders"
    private let defaults: UserDefaults
    private let sandboxed: Bool
    private let bookmarks: FolderAccess.Bookmarks
    private var opened: [String: URL] = [:]

    init(defaults: UserDefaults = .standard, sandboxed: Bool = Edition.current.isSandboxed, bookmarks: FolderAccess.Bookmarks? = nil) {
        self.defaults = defaults
        self.sandboxed = sandboxed
        self.bookmarks = bookmarks ?? .live
    }

    private var saved: [String: Data] {
        get { (defaults.dictionary(forKey: key) as? [String: Data]) ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// The folders kept open now.
    var paths: [String] { opened.keys.sorted() }

    /// Opens every kept folder again; one that's gone or can't be opened is
    /// dropped, so a pane never takes it for readable.
    func restore() {
        guard sandboxed else { return }
        var kept = saved
        for (path, data) in saved {
            guard let (url, stale) = bookmarks.resolve(data), url.standardizedFileURL.path == path, bookmarks.startAccessing(url) else {
                kept[path] = nil
                continue
            }
            opened[path] = url
            if stale, let fresh = try? bookmarks.make(url) { kept[path] = fresh }
        }
        saved = kept
    }

    /// Keeps `url`, chosen in a folder panel, open from now on. False when
    /// it can't be kept.
    @discardableResult
    func keep(_ url: URL) -> Bool {
        guard sandboxed else { return true }
        let path = url.standardizedFileURL.path
        // The panel's choice is readable now; the bookmark, opened again,
        // is what makes it readable after the next launch.
        guard let data = try? bookmarks.make(url), let (scoped, _) = bookmarks.resolve(data), bookmarks.startAccessing(scoped) else {
            return false
        }
        opened[path] = scoped
        var s = saved
        s[path] = data
        saved = s
        return true
    }

    /// Stops keeping `path` open.
    func release(_ path: String) {
        if let url = opened.removeValue(forKey: path) { bookmarks.stopAccessing(url) }
        var s = saved
        s[path] = nil
        saved = s
    }
}
