import AppKit
import Foundation
import StorageKit

/// The folders the App Store edition may work in. The App Sandbox keeps an
/// app to its own container; the user opens more by choosing a folder once,
/// and MyMole keeps that as a security-scoped bookmark so it lasts across
/// launches. The direct edition isn't sandboxed and has them all.
@MainActor
@Observable
final class FolderAccess {
    enum Place: String, CaseIterable, Identifiable {
        /// Caches, logs, projects, downloads and app leftovers.
        case home
        /// Apps to uninstall.
        case applications
        /// The whole disk, for the disk map beyond the home folder.
        case startupDisk

        var id: String { rawValue }

        var path: String {
            switch self {
            case .home: Home.path
            case .applications: "/Applications"
            case .startupDisk: "/"
            }
        }

        var title: String {
            switch self {
            case .home: String(localized: "Your home folder")
            case .applications: String(localized: "Applications")
            case .startupDisk: String(localized: "The startup disk")
            }
        }

        /// The title inside a sentence: "your home folder", "Applications".
        var inSentence: String {
            self == .applications ? title : title.prefix(1).lowercased() + title.dropFirst()
        }

        var why: String {
            switch self {
            case .home: String(localized: "Deep Clean, Projects, Installers, the disk map and app leftovers all work in it.")
            case .applications: String(localized: "Needed to move apps you uninstall to the Trash.")
            case .startupDisk: String(localized: "Lets the disk map look beyond your home folder.")
            }
        }
    }

    /// What security-scoped bookmarks and the folder panel do; injected so
    /// tests check the rules without real bookmarks or a panel.
    struct Bookmarks {
        var resolve: @MainActor (Data) -> (url: URL, stale: Bool)?
        var startAccessing: @MainActor (URL) -> Bool
        var stopAccessing: @MainActor (URL) -> Void
        var make: @MainActor (URL) throws -> Data
        var choose: @MainActor (Place) -> URL?

        static var live: Bookmarks {
            Bookmarks(
                resolve: { data in
                    var stale = false
                    guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
                    else { return nil }
                    return (url, stale)
                },
                startAccessing: { $0.startAccessingSecurityScopedResource() },
                stopAccessing: { $0.stopAccessingSecurityScopedResource() },
                make: { try $0.bookmarkData(options: .withSecurityScope) },
                choose: { place in
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: place.path)
                    panel.prompt = String(localized: "Give Access")
                    panel.message = String(localized: "Choose \(place.inSentence) (\(place.path)) to let MyMole work there. \(place.why)")
                    return panel.runModal() == .OK ? panel.url : nil
                })
        }
    }

    private(set) var granted: Set<Place>
    private(set) var lastProblem: String?
    /// Bumped by every grant and every taking back, so work started under
    /// one set of folders can tell the set has changed since.
    private(set) var generation = 0
    private let defaults: UserDefaults
    private let bookmarks: Bookmarks
    private var opened: [Place: URL] = [:]

    init(defaults: UserDefaults = .standard, bookmarks: Bookmarks? = nil) {
        self.defaults = defaults
        self.bookmarks = bookmarks ?? .live
        granted = Edition.current.isSandboxed ? [] : Set(Place.allCases)
        #if SMOKE
        // The screenshot run's own build shows the App Store edition with
        // its folders already chosen; shipping builds have no such switch.
        if ProcessInfo.processInfo.environment["MYMOLE_SMOKE_GRANTED"] == "1" {
            granted = Set(Place.allCases)
            return
        }
        #endif
        guard Edition.current.isSandboxed else { return }
        for place in Place.allCases { resolve(place) }
    }

    func has(_ place: Place) -> Bool { granted.contains(place) }

    /// The home folder is what nearly everything needs.
    var needsHome: Bool { !has(.home) }

    private static func key(_ place: Place) -> String { "access.bookmark." + place.rawValue }

    /// Opens a saved bookmark, renewing it when macOS says it's stale. One
    /// that no longer leads to the place is dropped.
    private func resolve(_ place: Place) {
        guard let data = defaults.data(forKey: Self.key(place)) else { return }
        guard let (url, stale) = bookmarks.resolve(data), url.path == place.path, bookmarks.startAccessing(url) else {
            defaults.removeObject(forKey: Self.key(place))
            return
        }
        opened[place] = url
        granted.insert(place)
        if stale, let fresh = try? bookmarks.make(url) {
            defaults.set(fresh, forKey: Self.key(place))
        }
    }

    /// Asks the user to choose the folder, already open at the right place.
    /// Any other folder chosen is refused, so access always matches the place.
    func request(_ place: Place) {
        guard let url = bookmarks.choose(place) else { return }
        guard url.standardizedFileURL.path == place.path else {
            lastProblem = String(localized: "That was \(url.path), not \(place.path). Choose \(place.inSentence) itself.")
            return
        }
        do {
            let data = try bookmarks.make(url)
            defaults.set(data, forKey: Self.key(place))
            lastProblem = nil
            resolve(place)
            generation += 1
        } catch {
            lastProblem = String(localized: "Access couldn't be saved: \(Problem(.folderAccess, error).description)")
        }
    }

    /// Closes the folder. Call through `AppModel.takeBack`, which first
    /// stops and waits for the scans that may be reading it.
    func revoke(_ place: Place) {
        generation += 1
        if let url = opened.removeValue(forKey: place) { bookmarks.stopAccessing(url) }
        defaults.removeObject(forKey: Self.key(place))
        granted.remove(place)
    }
}
