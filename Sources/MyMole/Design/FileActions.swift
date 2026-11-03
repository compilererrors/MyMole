import AppKit
import SwiftUI

/// What the app can do with files on disk outside its own model: show,
/// open, copy. Shared by every context menu so they read the same.
enum FileActions {
    static func reveal(_ paths: [String]) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copy(_ paths: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// The same items as `FileMenuItems`, for AppKit-backed tables.
    @MainActor static func menu(_ paths: [String], canOpen: Bool = true) -> [TableMenuEntry] {
        var out: [TableMenuEntry] = [.action("Reveal in Finder") { reveal(paths) }]
        if canOpen, paths.count == 1, let p = paths.first { out.append(.action("Open with Default App") { open(p) }) }
        out.append(.action(paths.count == 1 ? "Copy Path" : "Copy \(paths.count) Paths") { copy(paths) })
        return out
    }
}

/// The standard file items at the end of a context menu: Reveal in Finder,
/// Open (one item), Copy Path(s).
struct FileMenuItems: View {
    let paths: [String]
    var canOpen = true

    var body: some View {
        Button("Reveal in Finder") { FileActions.reveal(paths) }
        if canOpen, paths.count == 1, let p = paths.first {
            Button("Open with Default App") { FileActions.open(p) }
        }
        Button(paths.count == 1 ? "Copy Path" : "Copy \(paths.count) Paths") { FileActions.copy(paths) }
    }
}
