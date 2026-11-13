import AppKit
import StorageKit

/// Filtered rows, lookup and summary share one immutable input revision.
/// Dialog and selection changes can reuse it without walking the app inventory.
struct AppPresentation: Sendable {
    let apps: [AppBundle]
    let byPath: [String: AppBundle]
    let rows: [FileRow]
    let hiddenMacOS: Int
    let totalBytes: Int64
    let measuring: Bool

    init() {
        apps = []; byPath = [:]; rows = []
        hiddenMacOS = 0; totalBytes = 0; measuring = false
    }

    init(_ inventory: [AppBundle], query: String, sort: UninstallView.Sort, showMacOS: Bool,
         asList: Bool, running: Set<String>, ownPath: String?, pinned: Set<String> = []) {
        let sorted = UninstallView.project(inventory, query: query, sort: sort, showMacOS: showMacOS)
        apps = sorted.filter { pinned.contains($0.path) } + sorted.filter { !pinned.contains($0.path) }
        byPath = Dictionary(inventory.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        hiddenMacOS = showMacOS ? 0 : inventory.reduce(0) { $0 + ($1.isProtected ? 1 : 0) }
        totalBytes = apps.reduce(0) { $0 + $1.bytes }
        measuring = apps.contains(where: \.sizePending)
        rows = asList ? apps.map { app in
            var row = FileRow(
                id: app.path, name: app.name, size: app.isProtected || app.sizePending ? nil : app.bytes,
                kind: app.version.map { String(localized: "version \($0)") },
                location: (app.path as NSString).deletingLastPathComponent, symbol: "macwindow")
            if app.isProtected {
                row.badge = String(localized: "Part of macOS")
                row.badgeTint = .secondaryLabelColor
            } else if ownPath == app.path {
                row.badge = String(localized: "This app")
                row.badgeHelp = String(localized: "Review this copy and its data before it goes to the Trash.")
            } else if running.contains(app.path) {
                row.badge = String(localized: "Open")
                row.badgeTint = .systemOrange
                row.badgeHelp = String(localized: "Quit it before uninstalling")
            } else if app.fromAppStore {
                row.badge = String(localized: "App Store")
                row.badgeTint = .systemBlue
            }
            row.pinned = pinned.contains(app.path)
            if row.pinned {
                row.subtitle = String(localized: "Pinned — quick access only")
            }
            return row
        } : []
    }
}
